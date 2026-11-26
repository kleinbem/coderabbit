#!/usr/bin/env bash
# Offline unit tests for bin/pr-wait's GraphQL normalizer and state classifier.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PR_WAIT="$ROOT/bin/pr-wait"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
  local label=$1 got=$2 want=$3
  if [[ $got != "$want" ]]; then
    printf 'FAIL [%s]: got %q, want %q\n' "$label" "$got" "$want" >&2
    exit 1
  fi
  printf 'ok   %s -> %s\n' "$label" "$got"
}

make_case() {
  local name=$1 pull=$2 cmts=$3 crs=$4
  mkdir -p "$TMP/$name"
  printf '%s\n' "$pull" >"$TMP/$name/pull.json"
  printf '%s\n' "$cmts" >"$TMP/$name/comments.json"
  printf '%s\n' "$crs" >"$TMP/$name/check_runs.jsonl"
}

# 1. Missing option value fails cleanly with exit 2 (no unbound-var crash)
rc=0
"$PR_WAIT" --timeout >/dev/null 2>&1 || rc=$?
assert_eq "missing-opt-arg" "$rc" "2"

# 2. GraphQL normalizer: checkSuite.app.slug, null signature -> head_signed=false, unresolvedThreads priority
cat >"$TMP/gql-blocked.json" <<'EOF'
{
  "data": {
    "repository": {
      "pullRequest": {
        "state": "OPEN",
        "isDraft": false,
        "mergeStateStatus": "BLOCKED",
        "mergeCommit": null,
        "autoMergeRequest": {"enabledAt": "2026-11-22T17:00:00Z"},
        "author": {"__typename": "User", "login": "kleinbem"},
        "headRefOid": "1111222233334444",
        "labels": {"nodes": [{"name": "cr-review"}]},
        "reviewThreads": {
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "nodes": []
        },
        "firstComments": {"nodes": []},
        "lastComments": {
          "pageInfo": {"hasPreviousPage": false, "startCursor": null},
          "nodes": []
        },
        "commits": {
          "nodes": [
            {
              "commit": {
                "committedDate": "2026-11-22T17:00:00Z",
                "signature": null,
                "statusCheckRollup": {
                  "contexts": {
                    "pageInfo": {"hasNextPage": false, "endCursor": null},
                    "nodes": [
                      {
                        "__typename": "CheckRun",
                        "name": "CodeRabbit",
                        "status": "COMPLETED",
                        "conclusion": "SUCCESS",
                        "title": "Finished",
                        "startedAt": "2026-11-22T17:00:10Z",
                        "completedAt": "2026-11-22T17:02:00Z",
                        "checkSuite": {"app": {"slug": "coderabbitai"}}
                      }
                    ]
                  }
                }
              }
            }
          ]
        }
      }
    }
  }
}
EOF
now_2004=$(date -u -d "2026-11-22T20:04:00Z" +%s)
res=$("$PR_WAIT" --classify-graphql "$TMP/gql-blocked.json" --now "$now_2004")
assert_eq "gql-review-finished" "$(jq -r '.action + ":" + .event' <<<"$res")" "done:reviewed"
res=$("$PR_WAIT" --classify-graphql "$TMP/gql-blocked.json" --until-merged --now "$now_2004")
assert_eq "gql-unsigned-blocked" "$(jq -r '.action + ":" + (.detail | contains("head_signed=false") | tostring)' <<<"$res")" "confirm_blocked:true"

# 3. Unresolved thread wakes --until-merged even while CodeRabbit is still in_progress
jq '.data.repository.pullRequest.reviewThreads.nodes = [{"isResolved": false}]
  | .data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].status = "IN_PROGRESS"' \
  "$TMP/gql-blocked.json" >"$TMP/gql-thread-while-running.json"
res=$("$PR_WAIT" --classify-graphql "$TMP/gql-thread-while-running.json" --until-merged --now "$now_2004")
assert_eq "gql-thread-priority" "$(jq -r '.action + ":" + .event' <<<"$res")" "done:unresolved_threads"

# 4. CLEAN + autoMerge=true keeps waiting in --until-merged instead of reporting confirm_blocked
jq '.data.repository.pullRequest.mergeStateStatus = "CLEAN"' "$TMP/gql-blocked.json" >"$TMP/gql-clean-armed.json"
res=$("$PR_WAIT" --classify-graphql "$TMP/gql-clean-armed.json" --until-merged --now "$now_2004")
assert_eq "gql-clean-armed-waits" "$(jq -r '.action + ":" + .event' <<<"$res")" "wait:ci_in_progress"

# 5. Rate-limited PR right after opening -> sleep_then_trigger (~56m)
make_case rl-fresh \
  '{"state":"open","merged":false,"user":{"login":"kleinbem","type":"User"},"labels":[{"name":"cr-review"}],"head":{"sha":"aaaa1111"},"updated_at":"2026-11-22T16:51:12Z"}' \
  '[{"user":{"login":"coderabbitai[bot]"},"created_at":"2026-11-22T16:51:45Z","updated_at":"2026-11-22T16:51:45Z","body":"## Review limit reached\n\nNext included review available in 56 minutes."}]' \
  '{"name":"CodeRabbit","app":{"slug":"coderabbitai"},"head_sha":"aaaa1111","status":"completed","conclusion":"neutral","output":{"title":"Review rate limited"},"started_at":"2026-11-22T16:51:42Z","completed_at":"2026-11-22T16:51:42Z"}'

now_1652=$(date -u -d "2026-11-22T16:52:00Z" +%s)
res=$("$PR_WAIT" --classify-fixture "$TMP/rl-fresh" --now "$now_1652")
assert_eq "rl-fresh action" "$(jq -r '.action + ":" + .event' <<<"$res")" "sleep_then_trigger:rate_limited"

# 6. Same rate-limited PR 3 hours later -> trigger_review immediately
res=$("$PR_WAIT" --classify-fixture "$TMP/rl-fresh" --now "$now_2004")
assert_eq "rl-expired action" "$(jq -r '.action + ":" + .event' <<<"$res")" "trigger_review:rate_limit_ready"

# 7. Stale explicit estimate from an old denial is ignored when a new NEUTRAL denial occurs
make_case rl-stale-estimate \
  '{"state":"open","merged":false,"user":{"login":"kleinbem","type":"User"},"labels":[{"name":"cr-review"}],"head":{"sha":"aaaa2222"},"updated_at":"2026-11-22T20:03:00Z"}' \
  '[{"user":{"login":"coderabbitai[bot]"},"created_at":"2026-11-22T16:51:45Z","updated_at":"2026-11-22T16:51:45Z","body":"## Review limit reached\n\nNext included review available in 56 minutes."}]' \
  '{"name":"CodeRabbit","app":{"slug":"coderabbitai"},"head_sha":"aaaa2222","status":"completed","conclusion":"neutral","output":{"title":"Review rate limited"},"started_at":"2026-11-22T20:03:30Z","completed_at":"2026-11-22T20:03:35Z"}'

res=$("$PR_WAIT" --classify-fixture "$TMP/rl-stale-estimate" --now "$now_2004")
assert_eq "rl-stale-estimate" "$(jq -r '.action + ":" + .event' <<<"$res")" "sleep_then_trigger:rate_limited"

# 8. Earlier head's "Review finished" reply does not mask a failed check on a new head
make_case old-reply-new-fail \
  '{"state":"open","merged":false,"user":{"login":"kleinbem","type":"User"},"labels":[{"name":"cr-review"}],"head":{"sha":"bbbb9999"},"updated_at":"2026-11-22T20:00:00Z"}' \
  '[{"user":{"login":"kleinbem"},"created_at":"2026-11-22T19:00:00Z","updated_at":"2026-11-22T19:00:00Z","body":"@coderabbitai review"},{"user":{"login":"coderabbitai[bot]"},"created_at":"2026-11-22T19:02:00Z","updated_at":"2026-11-22T19:02:00Z","body":"<!-- CodeRabbit review command invocation: v2:abc -->\nReview finished."}]' \
  '{"name":"CodeRabbit","app":{"slug":"coderabbitai"},"head_sha":"bbbb9999","status":"completed","conclusion":"failure","output":{"title":"Failed"},"started_at":"2026-11-22T20:00:10Z","completed_at":"2026-11-22T20:01:00Z"}'

res=$("$PR_WAIT" --classify-fixture "$TMP/old-reply-new-fail" --now "$now_2004")
assert_eq "old-reply-new-fail" "$(jq -r '.action + ":" + .event + ":" + (.exit|tostring)' <<<"$res")" "done:cr_failed:1"

# 9. Clean 0-finding review + --require-review rejects skipped PRs
make_case unlabelled-skip \
  '{"state":"open","merged":false,"user":{"login":"kleinbem","type":"User"},"labels":[],"head":{"sha":"bbbb3333"},"updated_at":"2026-11-22T17:00:00Z"}' \
  '[]' \
  '{"name":"CodeRabbit","app":{"slug":"coderabbitai"},"head_sha":"bbbb3333","status":"completed","conclusion":"skipped","output":{"title":"Review skipped: excluded by label configuration"},"started_at":"2026-11-22T17:00:10Z","completed_at":"2026-11-22T17:00:12Z"}'

res=$("$PR_WAIT" --classify-fixture "$TMP/unlabelled-skip" --now "$now_2004")
assert_eq "unlabelled-default-ok" "$(jq -r '.action + ":" + (.exit|tostring)' <<<"$res")" "done:0"
res=$("$PR_WAIT" --classify-fixture "$TMP/unlabelled-skip" --require-review --now "$now_2004")
assert_eq "unlabelled-require-review-fails" "$(jq -r '.action + ":" + (.exit|tostring)' <<<"$res")" "done:1"

# 10. Large (> 200 KiB) comment payload does not trip Linux MAX_ARG_STRLEN in normalize_graphql_snapshot
printf '%s' "$(printf '%220000s' '' | tr ' ' 'x')" | jq -Rs '[{databaseId:1,author:{login:"coderabbitai"},createdAt:"2026-11-22T17:01:00Z",updatedAt:"2026-11-22T17:01:00Z",body:.}]' >"$TMP/big_cmts.json"
raw_gql=$(jq -n '{data:{repository:{pullRequest:{state:"OPEN",isDraft:false,mergeStateStatus:"CLEAN",mergeCommit:null,autoMergeRequest:null,author:{__typename:"User",login:"kleinbem"},headRefOid:"deadbeef",commits:{nodes:[{commit:{committedDate:"2026-11-22T17:00:00Z",signature:{isValid:true}}}]},labels:{nodes:[{name:"cr-review"}]}}}}}')
big_snap=$(bash -c '
  source <(sed "/^main \"\$@\"$/d" "$1")
  LABEL=cr-review
  big_cmts=$(<"$3")
  normalize_graphql_snapshot "$2" 0 "[]" "$big_cmts" true
' _ "$PR_WAIT" "$raw_gql" "$TMP/big_cmts.json")
assert_eq "large-comment-snapshot" "$(jq -r '.comments[0].body | length' <<<"$big_snap")" "220000"

# 11. Optional: verify against captured live fixtures when cache base is configured
CACHE_BASE=${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}
if [[ -n $CACHE_BASE && -d $CACHE_BASE/coderabbit-steward-experiments/cases ]]; then
  CASES=$CACHE_BASE/coderabbit-steward-experiments/cases
  for pair in \
    "no-actionable-comments:done:reviewed" \
    "reviewed-human-author-labelled:done:reviewed" \
    "reviewed-synthetic-label-only:done:reviewed" \
    "full-review-comment-trigger:done:reviewed" \
    "bot-author-not-eligible:done:cr_ineligible" \
    "rate-limited-merged-unreviewed:sleep_then_trigger:rate_limited" \
    "footer-one-per-hour:sleep_then_trigger:rate_limited"
  do
    IFS=: read -r cname want_act want_evt <<<"$pair"
    [[ -d $CASES/$cname ]] || continue
    cp -r "$CASES/$cname" "$TMP/live-$cname"
    jq '.state = "open" | .merged = false | .labels = [{"name":"cr-review"}]' "$CASES/$cname/pull.json" >"$TMP/live-$cname/pull.json"
    last_ts=$(jq -r '.completed_at' "$CASES/$cname/check_runs.jsonl" | tail -1)
    eval_now=$(($(date -u -d "$last_ts" +%s) + 30))
    res=$("$PR_WAIT" --classify-fixture "$TMP/live-$cname" --now "$eval_now")
    assert_eq "live/$cname" "$(jq -r '.action + ":" + .event' <<<"$res")" "$want_act:$want_evt"
  done
fi

echo "All pr-wait tests passed."

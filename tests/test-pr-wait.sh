#!/usr/bin/env bash
# Offline unit tests for bin/pr-wait's state classifier.
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

# 1. Rate-limited PR right after opening -> sleep_then_trigger (~56m)
make_case rl-fresh \
  '{"state":"open","merged":false,"user":{"login":"kleinbem","type":"User"},"labels":[{"name":"cr-review"}],"head":{"sha":"aaaa1111"},"updated_at":"2026-11-22T16:51:12Z"}' \
  '[{"user":{"login":"coderabbitai[bot]"},"created_at":"2026-11-22T16:51:45Z","updated_at":"2026-11-22T16:51:45Z","body":"## Review limit reached\n\nNext included review available in 56 minutes."}]' \
  '{"name":"CodeRabbit","app":{"slug":"coderabbitai"},"head_sha":"aaaa1111","status":"completed","conclusion":"neutral","output":{"title":"Review rate limited"},"started_at":"2026-11-22T16:51:42Z","completed_at":"2026-11-22T16:51:42Z"}'

now_1652=$(date -u -d "2026-11-22T16:52:00Z" +%s)
res=$("$PR_WAIT" --classify-fixture "$TMP/rl-fresh" --now "$now_1652")
assert_eq "rl-fresh action" "$(jq -r '.action + ":" + .event' <<<"$res")" "sleep_then_trigger:rate_limited"

# 2. Same rate-limited PR 3 hours later -> trigger_review immediately
now_2004=$(date -u -d "2026-11-22T20:04:00Z" +%s)
res=$("$PR_WAIT" --classify-fixture "$TMP/rl-fresh" --now "$now_2004")
assert_eq "rl-expired action" "$(jq -r '.action + ":" + .event' <<<"$res")" "trigger_review:rate_limit_ready"

# 3. Clean 0-finding review (no PullRequestReview object, only Finished check) -> done:reviewed
make_case zero-findings \
  '{"state":"open","merged":false,"user":{"login":"kleinbem","type":"User"},"labels":[{"name":"cr-review"}],"head":{"sha":"bbbb2222"},"updated_at":"2026-11-22T17:00:00Z"}' \
  '[{"user":{"login":"coderabbitai[bot]"},"created_at":"2026-11-22T17:03:00Z","updated_at":"2026-11-22T17:03:00Z","body":"No actionable comments were generated in the recent review."}]' \
  '{"name":"CodeRabbit","app":{"slug":"coderabbitai"},"head_sha":"bbbb2222","status":"completed","conclusion":"success","output":{"title":"Finished"},"started_at":"2026-11-22T17:00:10Z","completed_at":"2026-11-22T17:03:00Z"}'

res=$("$PR_WAIT" --classify-fixture "$TMP/zero-findings" --now "$now_2004")
assert_eq "zero-findings" "$(jq -r '.action + ":" + .event' <<<"$res")" "done:reviewed"

# 4. Bot-authored PR -> done:cr_ineligible (exit 1)
make_case bot-author \
  '{"state":"open","merged":false,"user":{"login":"coderabbit-steward[bot]","type":"Bot"},"labels":[{"name":"cr-review"}],"head":{"sha":"cccc3333"},"updated_at":"2026-11-22T17:00:00Z"}' \
  '[]' \
  '{"name":"CodeRabbit","app":{"slug":"coderabbitai"},"head_sha":"cccc3333","status":"completed","conclusion":"skipped","output":{"title":"Review skipped: bot user not eligible for review"},"started_at":"2026-11-22T17:00:05Z","completed_at":"2026-11-22T17:00:05Z"}'

res=$("$PR_WAIT" --classify-fixture "$TMP/bot-author" --now "$now_2004")
assert_eq "bot-author" "$(jq -r '.action + ":" + .event + ":" + (.exit|tostring)' <<<"$res")" "done:cr_ineligible:1"

# 5. All checks green in --until-merged mode while still OPEN & BLOCKED -> confirm_blocked
make_case post-arm-blocked \
  '{"state":"open","merged":false,"mergeable_state":"blocked","auto_merge":{"enabled_by":{}},"user":{"login":"kleinbem","type":"User"},"labels":[{"name":"cr-review"}],"head":{"sha":"dddd4444"},"updated_at":"2026-11-22T17:00:00Z"}' \
  '[]' \
  '{"name":"check","app":{"slug":"github-actions"},"head_sha":"dddd4444","status":"completed","conclusion":"success","output":{"title":"check"},"started_at":"2026-11-22T17:00:10Z","completed_at":"2026-11-22T17:05:00Z"}'

res=$("$PR_WAIT" --classify-fixture "$TMP/post-arm-blocked" --until-merged --now "$now_2004")
assert_eq "post-arm-blocked" "$(jq -r '.action + ":" + .event' <<<"$res")" "confirm_blocked:blocked"

# 6. Optional: verify against captured live fixtures in ~/.cache/coderabbit-steward-experiments/cases
CASES="${XDG_CACHE_HOME:-$HOME/.cache}/coderabbit-steward-experiments/cases"
if [[ -d $CASES ]]; then
  # Open-state overrides for captured fixtures (which were recorded after merge/close).
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
    # Evaluate 30s after the last check_run completed_at in that fixture.
    last_ts=$(jq -r '.completed_at' "$CASES/$cname/check_runs.jsonl" | tail -1)
    eval_now=$(($(date -u -d "$last_ts" +%s) + 30))
    res=$("$PR_WAIT" --classify-fixture "$TMP/live-$cname" --now "$eval_now")
    assert_eq "live/$cname" "$(jq -r '.action + ":" + .event' <<<"$res")" "$want_act:$want_evt"
  done
fi

echo "All pr-wait tests passed."

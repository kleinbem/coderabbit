#!/usr/bin/env bash
# Usage: .github/scripts/sync-to-org.sh TARGET_REPO PATH...
#
# Copies PATH... from this checkout to TARGET_REPO when they differ there:
# commits them to the sync branch, reset to the target's main, through GraphQL
# createCommitOnBranch, so GitHub signs the commit and it satisfies the
# required_signatures ruleset without key material in CI. Then opens a PR with
# squash auto-merge. Adapted from kleinbem-dev/nix-detour open-signed-pr.sh.
# Needs GH_TOKEN: an App token for TARGET_REPO's owner.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 TARGET_REPO PATH..." >&2
  exit 2
fi
repo="$1"
shift
branch="sync-from-kleinbem"
title="Sync the config from kleinbem/coderabbit"
body="Copied by sync-org.yaml from kleinbem/coderabbit@$(git rev-parse HEAD). Edit the config there, not here."

# Compare against one main commit, the one the sync branch is reset to, so a
# change on main mid-run can't slip into the sync commit.
main_sha=$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)
err=$(mktemp)
trap 'rm -f "$err"' EXIT

additions='[]'
for path in "$@"; do
  local_b64=$(base64 -w0 "$path")
  # Raw bytes; only a 404 means "missing there", any other error stops the run.
  if ! remote_b64=$(gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$repo/contents/$path?ref=$main_sha" 2>"$err" | base64 -w0); then
    if grep -q 'HTTP 404' "$err"; then
      remote_b64=""
    else
      cat "$err" >&2
      exit 1
    fi
  fi
  if [[ "$local_b64" != "$remote_b64" ]]; then
    additions=$(jq --arg p "$path" --arg c "$local_b64" '. + [{path: $p, contents: $c}]' <<<"$additions")
  fi
done
if [[ "$(jq length <<<"$additions")" == 0 ]]; then
  # A sync PR still open here carries an older change that the source has
  # since reverted; merging it would put the target out of sync.
  if [[ "$(gh pr list -R "$repo" --head "$branch" --state open --json number --jq length)" != 0 ]]; then
    gh pr close -R "$repo" "$branch" --comment "The source matches $repo again; this change is stale."
  fi
  echo "$repo is already in sync."
  exit 0
fi

if gh api "repos/$repo/git/ref/heads/$branch" >/dev/null 2>&1; then
  gh api -X PATCH "repos/$repo/git/refs/heads/$branch" -f sha="$main_sha" -F force=true >/dev/null
else
  gh api "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$main_sha" >/dev/null
fi

jq -n \
  --arg repo "$repo" --arg branch "$branch" --arg sha "$main_sha" --arg headline "$title" \
  --argjson additions "$additions" \
  --arg query 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }' \
  '{query: $query, variables: {input: {
      branch: {repositoryNameWithOwner: $repo, branchName: $branch},
      message: {headline: $headline},
      expectedHeadOid: $sha,
      fileChanges: {additions: $additions}
  }}}' | gh api graphql --input - >/dev/null

# Resetting the branch makes it identical to main for an instant, and GitHub
# sometimes closes an open PR for it right then; reopen it instead.
state=$(gh pr list -R "$repo" --head "$branch" --state all --limit 1 --json state --jq '.[0].state // empty')
if [[ "$state" == CLOSED ]]; then
  gh pr reopen -R "$repo" "$branch"
elif [[ "$state" != OPEN ]]; then
  gh pr create -R "$repo" --title "$title" --body "$body" --head "$branch" --base main
fi
gh pr merge -R "$repo" "$branch" --auto --squash

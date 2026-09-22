#!/usr/bin/env bash
# Sync new commits from upstream (caigee-cmd/cli2api) into this fork while
# keeping the local session-affinity patch on the current branch.
#
# Flow: fetch upstream -> if upstream/main has commits missing from HEAD,
# merge them into the current branch -> verify the merged tree still builds
# and the session-affinity tests pass -> push the branch, and fast-forward
# the fork's main to upstream. On merge conflict or a failed gate the repo
# is rolled back to the pre-merge state and nothing is pushed.
#
# After a successful sync, rebuild the container with ./docker-run.sh.
#
# Env overrides:
#   CLI2API_UPSTREAM_REMOTE  (default: upstream)
#   CLI2API_UPSTREAM_BRANCH  (default: main)
#   CLI2API_ORIGIN_REMOTE    (default: origin)
#   CLI2API_PUSH             0 to keep the merge local without pushing
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

UPSTREAM_REMOTE="${CLI2API_UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${CLI2API_UPSTREAM_BRANCH:-main}"
ORIGIN_REMOTE="${CLI2API_ORIGIN_REMOTE:-origin}"
PUSH="${CLI2API_PUSH:-1}"
UPSTREAM="refs/remotes/${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"

if ! git remote get-url "${UPSTREAM_REMOTE}" >/dev/null 2>&1; then
  echo "!! remote '${UPSTREAM_REMOTE}' not found (expected caigee-cmd/cli2api)" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "!! working tree has uncommitted changes, commit or stash first:" >&2
  git status --short >&2
  exit 1
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "${BRANCH}" = "HEAD" ]; then
  echo "!! detached HEAD, checkout a branch first" >&2
  exit 1
fi

echo "==> Fetching ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
git fetch "${UPSTREAM_REMOTE}" --prune
if ! git rev-parse -q --verify "${UPSTREAM}" >/dev/null; then
  echo "!! branch '${UPSTREAM_BRANCH}' not found on '${UPSTREAM_REMOTE}'" >&2
  exit 1
fi

NEW_COUNT="$(git rev-list --count "HEAD..${UPSTREAM}")"
if [ "${NEW_COUNT}" -eq 0 ]; then
  echo "==> upstream has no new commits, already up to date"
  exit 0
fi

echo "==> ${NEW_COUNT} new upstream commits:"
git log --oneline "HEAD..${UPSTREAM}" | head -20
if [ "${NEW_COUNT}" -gt 20 ]; then
  echo "    ... (${NEW_COUNT} total)"
fi

echo "==> Merging into ${BRANCH}"
if ! git merge --no-edit "${UPSTREAM}"; then
  echo "!! merge conflict, files involved:" >&2
  git diff --name-only --diff-filter=U >&2
  git merge --abort
  echo "!! rolled back to pre-merge state." >&2
  echo "   resolve manually with: git merge ${UPSTREAM}" >&2
  exit 1
fi

echo "==> Verifying the merged tree still builds"
if ! go build ./...; then
  git reset --hard ORIG_HEAD >/dev/null
  echo "!! merged tree failed to build, rolled back to pre-merge state." >&2
  echo "   resolve manually with: git merge ${UPSTREAM}" >&2
  exit 1
fi

echo "==> Verifying session-affinity tests still pass"
if ! go test ./internal/api/ -run 'TestRequestSessionKey' -count=1; then
  git reset --hard ORIG_HEAD >/dev/null
  echo "!! session-affinity tests failed on the merged tree, rolled back." >&2
  echo "   resolve manually with: git merge ${UPSTREAM}" >&2
  exit 1
fi
echo "==> merge ok: $(git log --oneline -1)"

if [ "${PUSH}" = "1" ]; then
  echo "==> Pushing to ${ORIGIN_REMOTE}/${BRANCH}"
  git push "${ORIGIN_REMOTE}" "HEAD:${BRANCH}"
  if [ "${BRANCH}" != "${UPSTREAM_BRANCH}" ]; then
    if git push "${ORIGIN_REMOTE}" "${UPSTREAM}:${UPSTREAM_BRANCH}" 2>/dev/null; then
      echo "==> fork's ${UPSTREAM_BRANCH} fast-forwarded to upstream"
    else
      echo "(hint) fork's ${UPSTREAM_BRANCH} could not be fast-forwarded, skipped"
    fi
  fi
else
  echo "==> push skipped (CLI2API_PUSH=0)"
fi

echo "==> done. rebuild the container with: ./docker-run.sh"

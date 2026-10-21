#!/usr/bin/env bash
# Sync new commits from upstream (caigee-cmd/cli2api) into this fork while
# keeping the local patches on the current branch.
#
# Target: by default the latest version tag reachable from upstream's main
# (releases only), NOT upstream's main tip -- main carries WIP that upstream
# has not stamped as a release. Override with CLI2API_TARGET to pin any ref
# (tag, branch, or commit), e.g. CLI2API_TARGET=main follows the main tip,
# CLI2API_TARGET=v0.6.24 merges that exact tag.
#
# Flow: fetch upstream -> resolve the target -> if it has commits missing
# from HEAD, merge them into the current branch -> verify the merged tree
# still builds and the fork's patched packages pass their tests -> push the
# branch, and fast-forward the fork's main to the merged target. On merge
# conflict or a failed gate the repo is rolled back to the pre-merge state
# and nothing is pushed.
#
# After a successful sync, rebuild the container with ./docker-run.sh.
#
# Env overrides:
#   CLI2API_UPSTREAM_REMOTE  (default: upstream)
#   CLI2API_UPSTREAM_BRANCH  (default: main, used for tag resolution and
#                             the fork-main fast-forward target)
#   CLI2API_TARGET           (default: latest v* tag on the upstream branch;
#                             set to a tag/branch/commit to pin the merge ref)
#   CLI2API_ORIGIN_REMOTE    (default: origin)
#   CLI2API_PUSH             0 to keep the merge local without pushing
set -euo pipefail
# Surface any unexpected set -e death with the failing line and exit code,
# instead of exiting silently (e.g. exit 141 from a SIGPIPE'd pipeline).
trap 'echo "!! pull.sh aborted at line ${LINENO} (exit $?)" >&2' ERR

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
git fetch "${UPSTREAM_REMOTE}" --prune --tags
if ! git rev-parse -q --verify "${UPSTREAM}" >/dev/null; then
  echo "!! branch '${UPSTREAM_BRANCH}' not found on '${UPSTREAM_REMOTE}'" >&2
  exit 1
fi

# Resolve the merge target: the pinned CLI2API_TARGET ref, or by default the
# latest v* tag reachable from the upstream branch (releases only, never the
# WIP tip of main).
if [ -n "${CLI2API_TARGET:-}" ]; then
  TARGET="$(git rev-parse --verify "${CLI2API_TARGET}^{commit}")" ||
    { echo "!! CLI2API_TARGET '${CLI2API_TARGET}' does not resolve to a commit" >&2; exit 1; }
  TARGET_DESC="${CLI2API_TARGET}"
else
  # --tags: release tags on this repo are lightweight; without it describe
  # only considers annotated tags and falls back to ancient history.
  TARGET="$(git describe --abbrev=0 --tags --match='v*' "${UPSTREAM}" 2>/dev/null)" || true
  if [ -z "${TARGET}" ]; then
    echo "!! no v* tag found on '${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}', pin one with CLI2API_TARGET" >&2
    exit 1
  fi
  TARGET_DESC="${TARGET} (latest tag on ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH})"
fi

NEW_COUNT="$(git rev-list --count "HEAD..${TARGET}")"
if [ "${NEW_COUNT}" -eq 0 ]; then
  echo "==> HEAD already contains target ${TARGET_DESC}, nothing to do"
  exit 0
fi

echo "==> ${NEW_COUNT} new commits from ${TARGET_DESC}:"
# -n 20 instead of `| head -20`: under `set -o pipefail`, head closing the
# pipe early makes git log die of SIGPIPE (141) and set -e kills the script.
git log --oneline -n 20 "HEAD..${TARGET}"
if [ "${NEW_COUNT}" -gt 20 ]; then
  echo "    ... (${NEW_COUNT} total)"
fi

echo "==> Merging into ${BRANCH}"
if ! git merge --no-edit "${TARGET}"; then
  echo "!! merge conflict, files involved:" >&2
  git diff --name-only --diff-filter=U >&2
  git merge --abort
  echo "!! rolled back to pre-merge state." >&2
  echo "   resolve manually with: git merge ${TARGET}" >&2
  exit 1
fi

echo "==> Verifying the merged tree still builds"
if ! go build ./...; then
  git reset --hard ORIG_HEAD >/dev/null
  echo "!! merged tree failed to build, rolled back to pre-merge state." >&2
  echo "   resolve manually with: git merge ${TARGET}" >&2
  exit 1
fi

echo "==> Verifying session-affinity tests still pass"
if ! go test ./internal/api/ -run 'TestRequestSessionKey' -count=1; then
  git reset --hard ORIG_HEAD >/dev/null
  echo "!! session-affinity tests failed on the merged tree, rolled back." >&2
  echo "   resolve manually with: git merge ${TARGET}" >&2
  exit 1
fi

echo "==> Verifying workbuddy provider tests still pass"
if ! go test ./internal/providers/workbuddy/ -count=1; then
  git reset --hard ORIG_HEAD >/dev/null
  echo "!! workbuddy tests failed on the merged tree, rolled back." >&2
  echo "   resolve manually with: git merge ${TARGET}" >&2
  exit 1
fi

echo "==> Verifying trae provider tests still pass"
if ! go test ./internal/providers/trae/ -count=1; then
  git reset --hard ORIG_HEAD >/dev/null
  echo "!! trae tests failed on the merged tree, rolled back." >&2
  echo "   resolve manually with: git merge ${TARGET}" >&2
  exit 1
fi
echo "==> merge ok: $(git log --oneline -1)"

if [ "${PUSH}" = "1" ]; then
  echo "==> Pushing to ${ORIGIN_REMOTE}/${BRANCH}"
  git push "${ORIGIN_REMOTE}" "HEAD:${BRANCH}"
  if [ "${BRANCH}" != "${UPSTREAM_BRANCH}" ]; then
    # Keep the fork's main at the merged release (the tag), not at the
    # upstream main tip, so fork-main == latest synced release.
    if git push "${ORIGIN_REMOTE}" "${TARGET}:${UPSTREAM_BRANCH}" 2>/dev/null; then
      echo "==> fork's ${UPSTREAM_BRANCH} fast-forwarded to ${TARGET_DESC}"
    else
      echo "(hint) fork's ${UPSTREAM_BRANCH} could not be fast-forwarded, skipped"
    fi
  fi
else
  echo "==> push skipped (CLI2API_PUSH=0)"
fi

echo "==> done. rebuild the container with: ./docker-run.sh"

#!/usr/bin/env bash
#
# Regenerate the local `zakura-orchard` branch.
#
# Zakura (https://github.com/zakura-core/common) is a monorepo with no shared
# git history with zcash/orchard. It carries a fork of the orchard crate that
# was imported from zcash/orchard v0.15.5. This script extracts zakura's
# orchard-crate history, rewrites it so the crate sits at the repo root, and
# grafts it onto the upstream v0.15.5 commit so the two histories join up.
#
# Usage: scripts/zakura-orchard.sh [zakura-rev] [branch]
#   zakura-rev  revision of the zakura monorepo to extract (default: zakura/main)
#   branch      branch to (force-)create in this repo (default: zakura-orchard)
#
set -euo pipefail

# --- Hardcoded anchors -------------------------------------------------------

# FORK_BASE: zcash/orchard commit "Release orchard v0.15.5". Zakura's orchard
# crate was forked from this tree, so the rewritten zakura history is grafted on
# top of it. It is GPG-signed upstream history and is never rewritten.
FORK_BASE=29d1d55db62153dcaeef8ef631c8991c53ed1248

# IMPORT_COMMIT: zakura's "feat: create repo for forks of the crypto stack",
# the root commit of the zakura monorepo, which vendored the v0.15.5 orchard
# tree. After filtering this is the oldest surviving commit; its parent is
# rewritten to FORK_BASE to bake the graft into real commit objects.
IMPORT_COMMIT=16d18d2a43d0aecdfcf9e9d02469c16ebf20e50b

# MOVE_COMMIT: zakura's "Move all workspace crates into crates/", a pure rename
# (orchard/ -> crates/orchard/). Both path prefixes are rewritten to the repo
# root, so this commit is content-neutral; its file changes are cleared so that
# filter-repo prunes it as empty. (Left alone, the delete-side and add-side of
# the rename collide on the same post-rename pathnames.)
MOVE_COMMIT=4279c920b7a9c35ff87537270103b173492802fa

# Path prefixes the orchard crate has lived at inside the zakura monorepo.
OLD_CRATE_PATH=orchard
NEW_CRATE_PATH=crates/orchard

# --- Arguments ---------------------------------------------------------------

ZAKURA_REV="${1:-zakura/main}"
BRANCH="${2:-zakura-orchard}"

# Work from the repo root regardless of the caller's cwd.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
cd "$REPO"

command -v git-filter-repo >/dev/null 2>&1 || {
  echo "error: git-filter-repo is not installed" >&2
  exit 1
}

ZAKURA_SHA="$(git rev-parse --verify "${ZAKURA_REV}^{commit}")"
git cat-file -e "${FORK_BASE}^{commit}" 2>/dev/null || {
  echo "error: fork base ${FORK_BASE} not found in $REPO" >&2
  exit 1
}

# Which prefix holds the crate at ZAKURA_REV (used only for the tree check).
if git cat-file -e "${ZAKURA_SHA}:${NEW_CRATE_PATH}" 2>/dev/null; then
  CRATE_PATH="$NEW_CRATE_PATH"
elif git cat-file -e "${ZAKURA_SHA}:${OLD_CRATE_PATH}" 2>/dev/null; then
  CRATE_PATH="$OLD_CRATE_PATH"
else
  echo "error: no orchard crate found in ${ZAKURA_REV}" >&2
  exit 1
fi

# --- Filter in a throwaway clone --------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zakura-orchard.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

MIRROR="$WORK/mirror"
git clone --no-hardlinks --mirror --quiet "file://$REPO" "$MIRROR"

git -C "$MIRROR" update-ref refs/heads/zakura-src "$ZAKURA_SHA"

git -C "$MIRROR" filter-repo \
  --force \
  --refs refs/heads/zakura-src \
  --replace-refs delete-no-add \
  --path "$OLD_CRATE_PATH" \
  --path "$NEW_CRATE_PATH" \
  --path-rename "${OLD_CRATE_PATH}/:" \
  --path-rename "${NEW_CRATE_PATH}/:" \
  --commit-callback "
if commit.original_id == b'${MOVE_COMMIT}':
    commit.file_changes = []
elif commit.original_id == b'${IMPORT_COMMIT}':
    # Root commit: its file changes are absolute, not a delta, so once it gains
    # a parent we must clear the inherited tree (e.g. the upstream Cargo.lock,
    # which zakura's vendored copy does not carry).
    commit.file_changes.insert(0, FileChange(b'DELETEALL'))
    commit.parents = [b'${FORK_BASE}']
"

# --- Publish -----------------------------------------------------------------

git fetch --no-tags --quiet --force "$MIRROR" "refs/heads/zakura-src:refs/heads/${BRANCH}"

# --- Verify ------------------------------------------------------------------

TIP="$(git rev-parse --verify "refs/heads/${BRANCH}")"

MERGE_BASE="$(git merge-base "$TIP" "$FORK_BASE")"
if [ "$MERGE_BASE" != "$FORK_BASE" ]; then
  echo "error: merge-base ${BRANCH} ${FORK_BASE} = ${MERGE_BASE}, expected ${FORK_BASE}" >&2
  exit 1
fi

if ! git diff --quiet "${ZAKURA_SHA}:${CRATE_PATH}" "$TIP"; then
  echo "error: tree of ${BRANCH} differs from ${ZAKURA_REV}:${CRATE_PATH}" >&2
  git --no-pager diff --stat "${ZAKURA_SHA}:${CRATE_PATH}" "$TIP" >&2
  exit 1
fi

COUNT="$(git rev-list --count "${FORK_BASE}..${TIP}")"

echo "${BRANCH} = $(git rev-parse --short "$TIP"), ${COUNT} commits over $(git rev-parse --short "$FORK_BASE"), tree matches ${ZAKURA_REV}"

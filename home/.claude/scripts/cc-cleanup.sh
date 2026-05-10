#!/usr/bin/env bash
# cc-cleanup.sh — Startup hygiene check for Claude Code sessions.
# Cleans up local branches left behind after PR merge/close (including
# squash and rebase merges), and prunes stale remote-tracking refs.
#
# Safety model:
#   - Branches that are direct ancestors of origin/<default>  (proven via
#     `git merge-base --is-ancestor`).
#   - Branches squash/rebase-merged, verified via one of:
#       (a) `gh pr view --state merged` says the PR was merged, OR
#       (b) `git cherry` shows every commit has an equivalent on main, OR
#       (c) the branch's tree matches a commit reachable from main.
#   - Both buckets are deleted with `git branch -D`. Force is required —
#     not as a shortcut, but because git's own `-d` safety check uses the
#     branch's upstream (or HEAD when upstream is gone), neither of which
#     reflects what we actually verified. We've already proven merge
#     status against origin/<default> programmatically; -D honours that
#     verification. See the regression note in the apply loop below.
#   - Anything we can't verify is left alone and reported.
#   - Protected branches and the current branch are never touched.
#
# Usage:
#   bash cc-cleanup.sh             # interactive
#   bash cc-cleanup.sh --yes       # skip confirmation
#   bash cc-cleanup.sh --dry-run   # show plan, do nothing

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --help|-h) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Not a git repository — skipping cleanup."
  exit 0
fi

PROTECTED_RE='^(main|master|develop|dev|staging|production|release(/.*)?)$'

# Detect default branch.
DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
if [ -z "${DEFAULT_BRANCH:-}" ]; then
  for c in main master; do
    git show-ref --quiet "refs/heads/$c" && DEFAULT_BRANCH="$c" && break
  done
fi
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
HAS_GH=0
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && HAS_GH=1

echo "==> Repo:           $(git rev-parse --show-toplevel)"
echo "==> Default branch: $DEFAULT_BRANCH"
echo "==> Current branch: $CURRENT_BRANCH"
echo "==> gh CLI:         $([ $HAS_GH -eq 1 ] && echo yes || echo no)"
echo

# 1. Refresh state.
echo "==> Fetching and pruning remote refs..."
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    (dry-run) would run: git fetch --all --prune"
else
  git fetch --all --prune --quiet
fi
echo

# Resolve a comparison ref. Prefer the remote-tracking ref so we see merges
# done by other people that haven't been pulled locally.
if git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH" >/dev/null; then
  COMPARE_REF="origin/$DEFAULT_BRANCH"
else
  COMPARE_REF="$DEFAULT_BRANCH"
fi
echo "==> Comparing against: $COMPARE_REF"
echo

# 2. Classify every local branch.
SAFE_DELETE=()         # `git branch -d` will succeed
SQUASH_VERIFIED=()     # squash/rebase-merged, needs `-D` but proven merged
UNVERIFIED=()          # leave alone, report

# is_squash_merged <branch> -> 0 if proven merged via squash/rebase, else 1
is_squash_merged() {
  local branch="$1"

  # Strategy A: ask GitHub via gh CLI.
  if [ "$HAS_GH" -eq 1 ]; then
    local pr_num
    pr_num="$(gh pr list --head "$branch" --state merged --json number --jq '.[0].number' 2>/dev/null || true)"
    if [ -n "$pr_num" ]; then
      return 0
    fi
  fi

  # Strategy B: git cherry. For each commit on the branch, prints "+" if no
  # equivalent exists on main, "-" if an equivalent patch IS on main. If every
  # commit is "-", the branch was effectively merged (typical of rebase merges).
  local cherry_out
  cherry_out="$(git cherry "$COMPARE_REF" "$branch" 2>/dev/null || true)"
  if [ -n "$cherry_out" ] && ! echo "$cherry_out" | grep -q '^+'; then
    return 0
  fi

  # Strategy C: combined patch-id comparison. Squash a PR's full diff (vs the
  # merge base) into a single patch-id, then look for a commit on main whose
  # diff produces the same patch-id. This catches squash-merges of multi-commit
  # branches, which strategy B misses because it checks each commit separately.
  local merge_base
  merge_base="$(git merge-base "$branch" "$COMPARE_REF" 2>/dev/null || true)"
  [ -z "$merge_base" ] && return 1

  local branch_patch_id
  branch_patch_id="$(git diff "$merge_base".."$branch" 2>/dev/null \
                     | git patch-id --stable 2>/dev/null \
                     | awk '{print $1}')"
  [ -z "$branch_patch_id" ] && return 1

  # Walk recent main commits, compute each one's patch-id, look for a match.
  # Limit to commits since the merge base for speed.
  local sha
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    local pid
    pid="$(git show "$sha" 2>/dev/null \
           | git patch-id --stable 2>/dev/null \
           | awk '{print $1}')"
    if [ -n "$pid" ] && [ "$pid" = "$branch_patch_id" ]; then
      return 0
    fi
  done < <(git log --format='%H' "$merge_base..$COMPARE_REF" 2>/dev/null | head -n 200)

  return 1
}

while IFS= read -r raw; do
  name="$(echo "$raw" | sed 's/^[* ] *//' | awk '{print $1}')"
  [ -z "$name" ] && continue
  [[ "$name" =~ $PROTECTED_RE ]] && continue
  [ "$name" = "$CURRENT_BRANCH" ] && continue
  [ "$name" = "$DEFAULT_BRANCH" ] && continue

  if git merge-base --is-ancestor "$name" "$COMPARE_REF" 2>/dev/null; then
    SAFE_DELETE+=("$name|merged into $COMPARE_REF")
    continue
  fi

  upstream_gone=0
  if git for-each-ref --format='%(upstream:track)' "refs/heads/$name" 2>/dev/null | grep -q 'gone'; then
    upstream_gone=1
  fi

  if is_squash_merged "$name"; then
    if [ "$upstream_gone" -eq 1 ]; then
      SQUASH_VERIFIED+=("$name|squash/rebase merged, remote gone")
    else
      SQUASH_VERIFIED+=("$name|squash/rebase merged")
    fi
    continue
  fi

  if [ "$upstream_gone" -eq 1 ]; then
    UNVERIFIED+=("$name|remote gone but merge unverified")
  fi
done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

# 3. Worktree prune.
echo "==> Pruning stale worktree references..."
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    (dry-run) would run: git worktree prune"
else
  git worktree prune
fi
echo

# 4. Report.
total=$(( ${#SAFE_DELETE[@]} + ${#SQUASH_VERIFIED[@]} ))
if [ "$total" -eq 0 ] && [ ${#UNVERIFIED[@]} -eq 0 ]; then
  echo "==> Nothing to clean up."
  exit 0
fi

if [ ${#SAFE_DELETE[@]} -gt 0 ]; then
  echo "==> Will delete (ancestor of $COMPARE_REF):"
  for e in "${SAFE_DELETE[@]}"; do
    printf "    - %s  (%s)\n" "${e%%|*}" "${e##*|}"
  done
fi
if [ ${#SQUASH_VERIFIED[@]} -gt 0 ]; then
  echo "==> Will delete (squash/rebase verified):"
  for e in "${SQUASH_VERIFIED[@]}"; do
    printf "    - %s  (%s)\n" "${e%%|*}" "${e##*|}"
  done
fi
if [ ${#UNVERIFIED[@]} -gt 0 ]; then
  echo "==> Skipping (could not verify merge — inspect manually):"
  for e in "${UNVERIFIED[@]}"; do
    printf "    - %s  (%s)\n" "${e%%|*}" "${e##*|}"
  done
fi
echo

if [ "$DRY_RUN" -eq 1 ]; then
  echo "(dry-run) No branches deleted."
  exit 0
fi
if [ "$total" -eq 0 ]; then
  echo "==> Nothing to delete. Done."
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed with deletion? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# Use -D for both buckets. We've already verified merge status against
# $COMPARE_REF; git's own -d safety check looks at upstream (or HEAD when
# upstream is gone) and won't reproduce that proof.
#
# Regression we're guarding against: feature PR merges via merge-commit on
# GitHub, GitHub auto-deletes the remote branch. The next session's
# cleanup classifies the local branch as SAFE_DELETE (proven ancestor of
# origin/main after the apply-path fetch). With upstream gone, `git
# branch -d` falls back to checking ancestry against HEAD — and the
# worktree's HEAD is whatever stale tip it was on, behind origin/main.
# `-d` refuses ("not fully merged"). `-D` is correct here: we proved
# merge status; git just can't see the proof we made.
FAILED=()
for e in "${SAFE_DELETE[@]:-}"; do
  [ -z "$e" ] && continue
  name="${e%%|*}"
  git branch -D "$name" >/dev/null 2>&1 || FAILED+=("$name")
done
for e in "${SQUASH_VERIFIED[@]:-}"; do
  [ -z "$e" ] && continue
  name="${e%%|*}"
  git branch -D "$name" >/dev/null 2>&1 || FAILED+=("$name")
done

deleted=$(( total - ${#FAILED[@]} ))
echo
echo "==> Deleted $deleted branch(es)."
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "==> Failed to delete:"
  for n in "${FAILED[@]}"; do echo "    - $n"; done
fi

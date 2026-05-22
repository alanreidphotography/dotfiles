#!/usr/bin/env bash
# session-start.sh — Claude Code SessionStart hook
#
# Runs the session-startup ritual that used to live as procedural prose in
# CLAUDE.md. Output is emitted as JSON additionalContext (per Claude Code's
# hook protocol), so the assistant sees a structured summary of what
# happened without the user having to approve N separate bash calls.
#
# Steps, in order:
#   1. cc-cleanup.sh --yes        (branch cleanup — re-uses canonical script)
#   2. Sync with origin/main      (rebase on a feature/worktree branch,
#                                  fast-forward on main itself, skip on
#                                  detached HEAD or non-main bases)
#   3. Symlink check              (.pre-commit-config.yaml always, eslint
#                                  + prettier configs if JS/TS repo)
#   4. Worktree gitignore audit   (warn always; offer autofix via dedicated
#                                  PR when safe — main checkout clean and
#                                  on default branch, gh authed)
#
# Before those steps, an installed-clone guard warns when the session is
# running inside ~/.dotfiles (the symlinked-into-$HOME clone), which must
# only ever track the default branch — branching/committing there is the
# mistake the guard exists to catch.
#
# Exit codes:
#   0  — always (we never want to block session startup over startup work;
#        problems are surfaced through additionalContext instead).
#
# Output:
#   Single line of JSON on stdout: {"hookSpecificOutput":{"hookEventName":
#   "SessionStart","additionalContext":"<summary>"}}
#
# Stderr is ignored by Claude Code unless we exit non-zero, which we don't.

set -uo pipefail

# ---------------------------------------------------------------------------
# Log accumulator. Everything user-facing goes through log/warn/note; emit()
# wraps it as JSON additionalContext at exit time.
# ---------------------------------------------------------------------------
LOG=""
log()  { LOG+="$1"$'\n'; }
note() { LOG+="• $1"$'\n'; }
warn() { LOG+="⚠ $1"$'\n'; }

emit() {
  # Use python3 for safe JSON string escaping. macOS ships python3 in
  # CommandLineTools; if it's somehow missing, fall back to a best-effort
  # raw print so we don't break the hook contract.
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$LOG" | python3 -c '
import json, sys
body = sys.stdin.read()
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": body,
    }
}))
'
  else
    # Minimal manual escape — newlines and quotes only. Good enough as a
    # fallback; the log shouldn't contain control chars in practice.
    local escaped
    escaped="${LOG//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    escaped="${escaped//$'\n'/\\n}"
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$escaped"
  fi
  exit 0
}

# Always emit valid JSON, even on unexpected failure.
trap 'emit' EXIT

# ---------------------------------------------------------------------------
# Bail early if we're not in a git repo. Nothing else to do; emit a brief
# note so Claude knows the hook ran but had nothing to act on.
# ---------------------------------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  note "Not in a git repo — startup hook skipped cleanup/rebase/symlink steps."
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || echo "")"
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"

# Worktrees have $GIT_DIR pointing into the main repo's .git/worktrees/<name>,
# while $GIT_COMMON_DIR points at the shared .git itself. Different paths ⇒
# we're in a worktree. Resolve to absolutes so the comparison is reliable.
IN_WORKTREE=0
abs() { (cd "$1" 2>/dev/null && pwd) || echo "$1"; }
if [[ -n "$GIT_DIR" && -n "$GIT_COMMON_DIR" ]]; then
  if [[ "$(abs "$GIT_DIR")" != "$(abs "$GIT_COMMON_DIR")" ]]; then
    IN_WORKTREE=1
  fi
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")"

# Detect the default branch (main / master / whatever). Mirrors the logic
# cc-cleanup.sh uses, so the hook and the cleanup script agree.
DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
if [[ -z "${DEFAULT_BRANCH:-}" ]]; then
  for c in main master; do
    if git show-ref --quiet "refs/heads/$c"; then DEFAULT_BRANCH="$c"; break; fi
  done
fi
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

log "Session-start hook: $REPO_ROOT"
log "Branch: $CURRENT_BRANCH$([[ $IN_WORKTREE -eq 1 ]] && echo " (worktree)" || true) · default: $DEFAULT_BRANCH"
log ""

# ---------------------------------------------------------------------------
# Installed-clone guard.
#
# ~/.dotfiles is the *installed* clone: bin/install.sh symlinks its files
# into $HOME, and live tooling (this hook, cc-cleanup.sh, the shared tool
# configs) is consumed from it. It must only ever track the default branch
# and update via pull; feature work belongs in a separate dev checkout. A
# session that branches or commits here leaves the clone parked off-default
# with the live tooling running un-merged code — exactly how this guard came
# to exist. Warn loudly; the sync step below still runs.
# ---------------------------------------------------------------------------
if [[ "$(abs "$REPO_ROOT")" == "$(abs "$HOME/.dotfiles")" ]]; then
  warn "This is the INSTALLED clone (~/.dotfiles); its files are symlinked into \$HOME and run live. It must only ever track $DEFAULT_BRANCH — do NOT create branches or commit here. Make changes in a separate dev checkout and let this clone update via pull."
  log ""
fi

# ---------------------------------------------------------------------------
# 1. Branch cleanup.
# ---------------------------------------------------------------------------
CLEANUP_SCRIPT="$HOME/.claude/scripts/cc-cleanup.sh"
# Use -f (not -x): the canonical cc-cleanup.sh isn't marked executable in
# the dotfiles repo and is always invoked via `bash <script>`.
if [[ -f "$CLEANUP_SCRIPT" ]]; then
  log "[1/4] Branch cleanup"
  # Capture stdout+stderr; cc-cleanup.sh handles --yes and uses exit 0 for
  # the no-op and success paths.
  cleanup_out="$(bash "$CLEANUP_SCRIPT" --yes 2>&1)" || cleanup_rc=$?
  cleanup_rc="${cleanup_rc:-0}"

  if echo "$cleanup_out" | grep -q "Nothing to clean up"; then
    note "Nothing to clean up."
  fi
  # Summarise deletions (one bullet per branch).
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    note "$line"
  done < <(echo "$cleanup_out" | sed -nE 's/^==> Deleted ([0-9]+) branch.*/Deleted \1 branch(es)/p')
  # Surface "Failed to delete" lines verbatim — these are signal per CLAUDE.md.
  if echo "$cleanup_out" | grep -q "Failed to delete"; then
    warn "Cleanup had branch deletion failures:"
    while IFS= read -r l; do
      log "$l"
    done < <(echo "$cleanup_out" | awk '/Failed to delete:/{f=1; next} f && /^    -/ {print "    "$0}')
  fi
  # Surface "Skipping (could not verify..." section so unmerged-but-stale
  # branches don't quietly accumulate.
  if echo "$cleanup_out" | grep -q "could not verify"; then
    note "Unverified branches left in place (run \`cc-cleanup.sh --dry-run\` to see them)."
  fi
  # A transient fetch failure inside cc-cleanup is non-fatal there (it warns,
  # continues with stale refs, and still exits 0). Surface it here so the
  # failure isn't swallowed and the stale-refs caveat for the rebase in step 2
  # is visible.
  if echo "$cleanup_out" | grep -q "WARNING: 'git fetch"; then
    warn "Branch-cleanup fetch failed — origin/$DEFAULT_BRANCH may be stale; the rebase below could no-op or use an old tip."
    # Process substitution (not a pipe) so the loop runs in this shell and the
    # appended detail lines survive — a piped `while` would log into a subshell.
    while IFS= read -r l; do
      log "    $l"
    done < <(echo "$cleanup_out" | sed -n "/WARNING: 'git fetch/,/^[[:space:]]*\$/p" | sed -n 's/^    //p' | head -5)
  fi
  if [[ "$cleanup_rc" -ne 0 ]]; then
    warn "cc-cleanup.sh exited with code $cleanup_rc; tail:"
    while IFS= read -r l; do
      log "    $l"
    done < <(echo "$cleanup_out" | tail -5)
  fi
else
  warn "Cleanup script not found at $CLEANUP_SCRIPT — skipping branch cleanup."
fi
log ""

# ---------------------------------------------------------------------------
# 2. Sync with origin/main.
#
# cc-cleanup.sh already ran `git fetch --all --prune` in step 1, so
# origin/<default> is normally fresh and we don't refetch here. That fetch
# is best-effort, though: on a transient failure cc-cleanup warns and
# continues (still exiting 0), and step 1 above surfaces that warning. When
# it fires, the refs below may be stale, so this rebase can no-op or rebase
# onto an older tip — both self-correct on the next successful session start.
# ---------------------------------------------------------------------------
log "[2/4] Sync with origin/$DEFAULT_BRANCH"

sync_result=""
if [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
  sync_result="skipped (detached HEAD)"
elif [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
  # On default branch — fast-forward only. Don't try to merge or rebase
  # main itself; that's a deliberate user action.
  ff_out="$(git pull --ff-only origin "$DEFAULT_BRANCH" 2>&1)" || ff_rc=$?
  ff_rc="${ff_rc:-0}"
  if [[ "$ff_rc" -eq 0 ]]; then
    if echo "$ff_out" | grep -qE "Already up to date|Already up-to-date"; then
      sync_result="up to date"
    else
      sync_result="fast-forwarded"
    fi
  else
    sync_result="ff-only refused (local commits on $DEFAULT_BRANCH — handle manually)"
    warn "$DEFAULT_BRANCH has local commits not on origin/$DEFAULT_BRANCH. Inspect with: git log --oneline origin/$DEFAULT_BRANCH..$DEFAULT_BRANCH"
  fi
else
  # Feature/worktree branch — rebase onto fresh origin/<default>.
  if ! git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH" >/dev/null; then
    sync_result="skipped (no origin/$DEFAULT_BRANCH ref)"
  else
    # Cheap pre-check: if we're already an ancestor of origin/<default>,
    # rebase is a no-op.
    if git merge-base --is-ancestor HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null \
       && [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$DEFAULT_BRANCH")" ]]; then
      sync_result="already on origin/$DEFAULT_BRANCH tip"
    else
      rebase_out="$(git rebase "origin/$DEFAULT_BRANCH" 2>&1)" || rebase_rc=$?
      rebase_rc="${rebase_rc:-0}"
      if [[ "$rebase_rc" -eq 0 ]]; then
        if echo "$rebase_out" | grep -qiE "current branch .* is up to date"; then
          sync_result="already up to date with origin/$DEFAULT_BRANCH"
        else
          sync_result="rebased onto origin/$DEFAULT_BRANCH"
        fi
      else
        # Conflict — abort immediately. Per CLAUDE.md / user preference,
        # session-start is the wrong moment to resolve conflicts.
        git rebase --abort >/dev/null 2>&1 || true
        sync_result="aborted (conflict with origin/$DEFAULT_BRANCH — rebase manually)"
        warn "Rebase aborted due to conflict. Conflicting paths (best-effort):"
        while IFS= read -r l; do
          log "    $l"
        done < <(echo "$rebase_out" | grep -E "^(CONFLICT|both modified:|deleted by us:|deleted by them:)" | head -10)
      fi
    fi
  fi
fi
note "$sync_result"
log ""

# ---------------------------------------------------------------------------
# 3. Symlink check (.pre-commit-config.yaml; eslint/prettier for JS/TS).
# ---------------------------------------------------------------------------
log "[3/4] Shared-config symlinks"

ensure_symlink() {
  local dst_rel="$1"   # path relative to $REPO_ROOT
  local src_abs="$2"   # canonical source in $HOME
  local dst_abs="$REPO_ROOT/$dst_rel"

  if [[ -L "$dst_abs" ]]; then
    local link_target
    link_target="$(readlink "$dst_abs")"
    if [[ "$link_target" == "$src_abs" || "$link_target" == "$HOME/$(basename "$src_abs")" ]]; then
      return 0  # already correct
    fi
    warn "$dst_rel is a symlink to $link_target (expected $src_abs) — leaving alone."
    return 1
  fi
  if [[ -e "$dst_abs" ]]; then
    # Real file already exists — repo has its own committed config. Don't
    # overwrite; that's repo-specific tuning per CLAUDE.md.
    return 1
  fi
  if [[ ! -e "$src_abs" ]]; then
    warn "Canonical config missing at $src_abs — cannot symlink $dst_rel."
    return 1
  fi
  # Resolve $src_abs through any symlink chain to its real path. If the
  # canonical source lives inside $REPO_ROOT, this repo IS the canonical
  # provider (the dotfiles repo case) — symlinking would create a cycle.
  local real_src
  real_src="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$src_abs" 2>/dev/null || echo "$src_abs")"
  local real_repo
  real_repo="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")"
  if [[ "$real_src" == "$real_repo/"* ]]; then
    return 1  # this repo provides the canonical — don't symlink to ourselves
  fi
  ln -s "$src_abs" "$dst_abs"
  note "Linked $dst_rel → $src_abs"
  # Add to .gitignore if not already there.
  local gi="$REPO_ROOT/.gitignore"
  if [[ -f "$gi" ]] && ! grep -qxF "$dst_rel" "$gi"; then
    printf '%s\n' "$dst_rel" >> "$gi"
    note "Added $dst_rel to .gitignore"
  fi
  return 0
}

# Always: pre-commit config.
ensure_symlink ".pre-commit-config.yaml" "$HOME/.pre-commit-config.yaml" || true

# JS/TS repos: also eslint + prettier. Detect by presence of common markers.
JS_TS_REPO=0
if [[ -f "$REPO_ROOT/package.json" ]]; then
  JS_TS_REPO=1
elif find "$REPO_ROOT" -maxdepth 3 -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.jsx' \) -not -path '*/node_modules/*' -not -path '*/.claude/*' -print -quit 2>/dev/null | grep -q .; then
  JS_TS_REPO=1
fi
if [[ "$JS_TS_REPO" -eq 1 ]]; then
  ensure_symlink "eslint.config.mjs" "$HOME/eslint.config.mjs" || true
  ensure_symlink ".prettierrc.json"  "$HOME/.prettierrc.json"  || true
fi

# Pre-commit install decision (per CLAUDE.md rules).
HOOKS_PATH="$(git config --get core.hooksPath 2>/dev/null || true)"
if [[ -z "$HOOKS_PATH" ]]; then
  if [[ ! -f "$REPO_ROOT/.git/hooks/pre-commit" ]] && command -v pre-commit >/dev/null 2>&1; then
    if (cd "$REPO_ROOT" && pre-commit install >/dev/null 2>&1); then
      note "pre-commit install: hook registered."
    fi
  fi
fi
log ""

# ---------------------------------------------------------------------------
# 4. Worktree gitignore audit (+ autofix PR when safe).
# ---------------------------------------------------------------------------
log "[4/4] Worktree gitignore audit"

# The bad shape: a parent repo gitignores `.claude/` (or `.claude`), which
# blocks osv-scanner from seeing lockfiles inside Claude Code worktrees at
# `.claude/worktrees/<name>/`. The correct shape is `.claude/*` plus
# `!.claude/worktrees/`.
#
# We check the .gitignore of the *shared* repo (works the same whether the
# current cwd is the main checkout or a worktree of it).
SHARED_REPO_TOP=""
if [[ -n "$GIT_COMMON_DIR" ]]; then
  SHARED_REPO_TOP="$(dirname "$(abs "$GIT_COMMON_DIR")")"
fi
SHARED_GITIGNORE="$SHARED_REPO_TOP/.gitignore"

needs_fix=0
if [[ -f "$SHARED_GITIGNORE" ]]; then
  # Bare `.claude/` or `.claude` rule present?
  if grep -Eq '^\.claude/?$' "$SHARED_GITIGNORE"; then
    # Is the negation rule also present?
    if ! grep -qxF '!.claude/worktrees/' "$SHARED_GITIGNORE"; then
      needs_fix=1
    fi
  fi
fi

if [[ "$needs_fix" -eq 0 ]]; then
  note ".gitignore looks fine (no bare .claude/ rule, or already has !.claude/worktrees/)."
  exit 0
fi

warn "Parent .gitignore has a bare .claude/ rule — this hides worktrees from osv-scanner."

# Decide whether to autofix:
#   - gh CLI must be authed (we open a PR)
#   - We need to be able to push (assume true if gh is authed)
#   - Don't fix if there's already an open PR titled with our marker
AUTOFIX_MARKER="chore/fix-claude-gitignore-worktrees"

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  note "gh CLI not authed — skipping autofix PR. Fix manually:"
  log "    sed -i '' 's|^\\.claude/\$|.claude/*|' \"$SHARED_GITIGNORE\""
  log "    echo '!.claude/worktrees/' >> \"$SHARED_GITIGNORE\""
  exit 0
fi

# Existing PR? Don't open a duplicate.
existing_pr=""
existing_pr="$(gh -R "$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" pr list --head "$AUTOFIX_MARKER" --state open --json url --jq '.[0].url' 2>/dev/null || true)"
if [[ -n "$existing_pr" ]]; then
  note "Autofix PR already open: $existing_pr"
  exit 0
fi

# Create a temp worktree off origin/<default>, apply the fix, push, open PR.
TMP_WT="$(mktemp -d -t claude-gitignore-fix-XXXXXX)"
# mktemp -d already created the directory; `git worktree add` refuses an
# existing path. Remove it first.
rmdir "$TMP_WT" 2>/dev/null || true

if ! git -C "$SHARED_REPO_TOP" worktree add -b "$AUTOFIX_MARKER" "$TMP_WT" "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
  warn "Could not create temp worktree for autofix (branch name may already exist locally)."
  note "Run \`git branch -D $AUTOFIX_MARKER\` if a stale local branch is blocking this, then start a new session."
  exit 0
fi

# Apply fix.
TMP_GI="$TMP_WT/.gitignore"
# Replace bare `.claude/` / `.claude` with `.claude/*` and append the
# negation rule. Portable sed (BSD/macOS): use -i '' for in-place.
sed -i '' -E 's|^\.claude/?$|.claude/*|' "$TMP_GI"
if ! grep -qxF '!.claude/worktrees/' "$TMP_GI"; then
  printf '!.claude/worktrees/\n' >> "$TMP_GI"
fi

git -C "$TMP_WT" add .gitignore >/dev/null 2>&1
COMMIT_MSG=$'chore: fix .claude/ gitignore so worktrees are scanned\n\nClaude Code creates worktrees at `.claude/worktrees/<name>/`. A blanket\n`.claude/` rule in .gitignore makes osv-scanner skip lockfiles inside\nthose worktrees ("No package sources found"), causing pre-commit to\nfail on every commit in the worktree.\n\nFix: gitignore the contents (`.claude/*`) and re-include the worktrees\npath (`!.claude/worktrees/`). Git refuses to track files inside\nworktrees anyway (boundary marker), so the negation only affects\nfilesystem walkers like osv-scanner.\n\nAuto-generated by the SessionStart hook in ~/.dotfiles/home/.claude/hooks/session-start.sh.'
if ! git -C "$TMP_WT" -c commit.gpgsign=false commit -m "$COMMIT_MSG" >/dev/null 2>&1; then
  warn "Could not commit gitignore fix (pre-commit hooks may have rejected it)."
  git -C "$SHARED_REPO_TOP" worktree remove --force "$TMP_WT" >/dev/null 2>&1 || true
  exit 0
fi

if ! git -C "$TMP_WT" push -u origin "$AUTOFIX_MARKER" >/dev/null 2>&1; then
  warn "Could not push autofix branch — leaving local branch in place for inspection."
  git -C "$SHARED_REPO_TOP" worktree remove --force "$TMP_WT" >/dev/null 2>&1 || true
  exit 0
fi

PR_BODY=$'## Summary\n- Fix `.gitignore` so Claude Code worktrees (`.claude/worktrees/<name>/`) are visible to osv-scanner.\n- Without this, the pre-commit `osv-scanner` hook prints "No package sources found" and blocks every commit inside a worktree.\n\n## Why this lands as a separate PR\nThe SessionStart hook in `~/.dotfiles/home/.claude/hooks/session-start.sh` detected the misconfigured rule and opened this PR automatically so the fix lands cleanly under review, separate from in-flight feature work.\n\n## Test plan\n- [ ] Inside a `.claude/worktrees/<name>/` checkout, run `pre-commit run --all-files` and confirm `osv-scanner` finds the lockfile(s).\n- [ ] `git status` from the main checkout still shows `.claude/worktrees/<name>/` as untracked (git refuses to track the worktree boundary regardless).'

pr_url=""
pr_url="$(gh -R "$(gh -C "$TMP_WT" repo view --json nameWithOwner --jq .nameWithOwner)" \
  pr create --base "$DEFAULT_BRANCH" --head "$AUTOFIX_MARKER" \
  --title "chore: fix .claude/ gitignore so worktrees are scanned" \
  --body "$PR_BODY" 2>&1 || true)"

# Clean up the temp worktree regardless.
git -C "$SHARED_REPO_TOP" worktree remove --force "$TMP_WT" >/dev/null 2>&1 || true

if [[ "$pr_url" =~ https://github.com/[^[:space:]]+/pull/[0-9]+ ]]; then
  warn "Opened autofix PR — please review: ${BASH_REMATCH[0]}"
else
  warn "Push succeeded but PR creation output was unexpected:"
  while IFS= read -r l; do
    log "    $l"
  done < <(echo "$pr_url" | tail -5)
fi

exit 0

#!/usr/bin/env bash
# PreToolUse hook — refuse `git push` to protected branches (main/master).
#
# Reads the Bash tool-call JSON on stdin. A push is blocked when it would
# update main or master, detected two ways:
#   (b) an explicit refspec whose destination is main/master
#       (e.g. "git push origin main", "git push origin HEAD:master")
#   (a) HEAD is on a protected branch, so a bare/implicit push
#       (e.g. plain "git push", "git push --force") would update it
# A blocked push emits permissionDecision "deny" plus a user-visible
# systemMessage so the refusal is never silent. Everything else — non-push
# commands, pushes to feature branches — passes through untouched.
#
# Fails OPEN: if the command can't be read (e.g. jq missing) it allows the
# call, leaving the CLAUDE.md behavioral guard + auto-mode classifier as
# backstops. A broken hook must not brick all pushing.
set -uo pipefail
set -f  # no globbing while word-splitting the command

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# Only inspect git push commands; let everything else through.
case "$cmd" in
  *"git push"*) ;;
  *) exit 0 ;;
esac

emit_deny() {
  jq -nc --arg r "$1" '{
    systemMessage: ("Push blocked by deny-protected-push hook: " + $r),
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# (b) Scan only the first push segment (up to the first ; | & separator) so a
#     compound like "git push origin feat && git checkout main" isn't misread.
seg=${cmd#*git push}
seg=${seg%%[;|&]*}
for tok in $seg; do
  case "$tok" in -*) continue ;; esac      # skip flags
  dst=${tok##*:}                            # refspec src:dst -> dst (or whole token)
  dst=${dst#+}                              # drop force-push '+' prefix
  dst=${dst#[\"\']}; dst=${dst%[\"\']}      # strip surrounding quotes
  if [ "$dst" = "main" ] || [ "$dst" = "master" ]; then
    emit_deny "command pushes to '$dst'. Open a PR instead of pushing to $dst directly."
  fi
done

# (a) Bare/implicit push while HEAD is on a protected branch.
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  emit_deny "you are on '$branch' (protected); this push would update $branch. Switch to a feature branch and open a PR."
fi

exit 0

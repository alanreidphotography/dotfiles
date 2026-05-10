#!/usr/bin/env bash
# Idempotently symlink the canonical home/* files into $HOME.
# Re-run any time after a `git pull` here — no-op if nothing changed.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=(
  .pre-commit-config.yaml
  .prettierrc.json
  eslint.config.mjs
  .claude/scripts/cc-cleanup.sh
)
for f in "${FILES[@]}"; do
  src="$DIR/home/$f"
  dst="$HOME/$f"
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    echo "ok    $dst"
    continue
  fi
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    backup="$dst.backup.$(date +%Y%m%d-%H%M%S)"
    echo "save  $dst -> $backup"
    mv "$dst" "$backup"
  fi
  mkdir -p "$(dirname "$dst")"
  ln -sfn "$src" "$dst"
  echo "link  $dst -> $src"
done

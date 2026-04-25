# dotfiles

Canonical home for three tool configs that need to live identically on dev
machines and on GitHub-hosted CI runners:

| File                      | Used by                  |
| ------------------------- | ------------------------ |
| `.pre-commit-config.yaml` | `pre-commit`             |
| `.prettierrc.json`        | Prettier                 |
| `eslint.config.mjs`       | ESLint (zero-dependency) |

The originals lived in `$HOME` and were symlinked into each repo. That
worked locally but broke on GitHub-hosted runners (their `$HOME` isn't
ours, so any `/Users/alan/...` symlink dangled and the consuming tool
silently fell back to defaults). This repo is the single source of truth;
dev machines symlink from `$HOME`, CI runners install via the composite
action below.

## Install on a dev machine

```sh
git clone git@github.com:alanreidphotography/dotfiles.git ~/.dotfiles
~/.dotfiles/bin/install.sh
```

The installer is idempotent. The first run backs up any pre-existing
`~/<config>` as `~/<config>.backup.<timestamp>` and replaces it with a
symlink into the clone. Subsequent runs are no-ops if nothing changed.
Re-run after every `git pull` here — though for symlinked files the pull
alone propagates new content.

## Consume from GitHub Actions

Add this step before any tool that reads one of the canonical configs
(prettier, eslint, pre-commit's mirrored hooks):

```yaml
- uses: alanreidphotography/dotfiles/.github/actions/setup@v1.0.0
```

The action checks out this repo into a scratch directory and copies
`home/*` into `$HOME` on the runner. Plain copies, not symlinks —
runners are ephemeral, so simplicity beats drift-prevention. Pin to a
tag or SHA in production workflows; `main` is allowed but discouraged.

## Update workflow

1. Edit the relevant file under `home/`.
2. Commit and push. Symlinked dev machines pick up the change on the
   next `git pull` inside `~/.dotfiles`.
3. Bump the tag (`vX.Y.Z`) so consuming repos can opt in by bumping
   their pinned ref.

## Conventions

- Pre-commit on this repo too — `.pre-commit-config.yaml` is symlinked
  to `home/.pre-commit-config.yaml` (eat your own dog food).
- The canonical `eslint.config.mjs` is intentionally zero-dependency:
  no `import` statements. Repos that need plugins compose a per-repo
  config; do not add imports here.
- No secrets ever. This repo is public so the composite action can
  clone it without a token.

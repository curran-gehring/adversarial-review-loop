#!/usr/bin/env bash
# Install the adversarial-review-loop pre-push guard into a git repo, and print
# the remaining Claude Code wiring steps. Idempotent — safe to re-run.
#
# usage:
#   ./setup.sh            # install into the repo you're currently in
#   ./setup.sh <repo>     # install into <repo>
set -euo pipefail

toolkit="$(cd "$(dirname "$0")" && pwd)"
guard="$toolkit/hooks/pre-push-main-guard.sh"
[ -f "$guard" ] || { echo "error: $guard not found — run setup.sh from the toolkit checkout." >&2; exit 1; }

target="${1:-$PWD}"
cd "$target" || { echo "error: cannot cd to $target" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "error: $target is not inside a git repository." >&2; exit 1; }

# Resolve the EFFECTIVE hooks directory. `git rev-parse --git-path hooks` always
# returns the default $GIT_DIR/hooks and IGNORES core.hooksPath, so a repo with a
# custom hooks path would get the guard installed where Git never runs it. Check
# core.hooksPath first.
custom="$(git config --get core.hooksPath || true)"
if [ -n "$custom" ]; then
  # A relative core.hooksPath is resolved by Git against the worktree root, NOT
  # the current directory — so resolve it the same way (this script may be run
  # from a subdirectory or with a subdirectory as the target).
  case "$custom" in
    /* | [A-Za-z]:[/\\]*) hooks_dir="$custom" ;;                       # absolute
    *)                    hooks_dir="$(git rev-parse --show-toplevel)/$custom" ;;  # relative → worktree root
  esac
  echo "• core.hooksPath is set — installing into: $hooks_dir"
  echo "  (if a hook manager owns that dir, add hooks/pre-push-main-guard.sh to"
  echo "   its pre-push chain instead of relying on this single-file install.)"
else
  hooks_dir="$(git rev-parse --git-path hooks)"
fi
mkdir -p "$hooks_dir"
dest="$hooks_dir/pre-push"

# Already our guard? Nothing to do.
if [ -e "$dest" ] && cmp -s "$guard" "$dest"; then
  echo "✓ pre-push guard already installed → $dest"
  exit 0
fi

# A different existing hook (or a symlink to one): preserve it under a UNIQUE
# backup name so re-running never clobbers an earlier backup.
if [ -e "$dest" ] || [ -L "$dest" ]; then
  ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo backup)"
  backup="$dest.backup.$ts"
  n=0
  while [ -e "$backup" ] || [ -L "$backup" ]; do n=$((n + 1)); backup="$dest.backup.$ts.$n"; done
  cp -P "$dest" "$backup"   # -P: back up the symlink itself, not its target
  echo "• existing pre-push hook preserved → $backup"
fi

# Remove first so we replace the repo-local hook and never write THROUGH an
# existing symlink into its (possibly shared) target.
rm -f "$dest"
cp "$guard" "$dest"
chmod +x "$dest"
echo "✓ installed pre-push guard → $dest"

cat <<EOF

Remaining Claude Code wiring (once):
  1. MCP reviewer:
       cd "$toolkit/mcp" && npm install
       claude mcp add codex-review -- node "$toolkit/mcp/server.mjs"
  2. Review gate (PreToolUse hook):
       This toolkit ships .claude/settings.json registering hooks/require-review.py.
       For another repo, copy that block into its .claude/settings.json
       (full snippet + the remote-reviewer shape are in docs/install.md).

Then: review every change before pushing to main — see docs/protocol.md.
EOF

#!/usr/bin/env bash
# Install the adversarial-review-loop pre-push hooks into a git repo, and print
# the remaining Claude Code wiring steps. Idempotent — safe to re-run.
#
# By default this installs BOTH gates as a pre-push dispatcher:
#   • pre-push-main-guard.sh   — refuse non-descendant pushes to the branch
#   • pre-push-review-gate.sh  — refuse pushes without an APPROVE review receipt
#                                (coder-agnostic: enforces the loop for ANY author)
#
# usage:
#   ./setup.sh                 # install both gates into the current repo
#   ./setup.sh <repo>          # ... into <repo>
#   ./setup.sh --no-review     # install ONLY the descendant guard
set -euo pipefail

toolkit="$(cd "$(dirname "$0")" && pwd)"

review=1
target=""
for a in "$@"; do
  case "$a" in
    --no-review) review=0 ;;
    -*) echo "error: unknown option: $a" >&2; exit 1 ;;
    *) target="$a" ;;
  esac
done
target="${target:-$PWD}"

# What becomes the repo's `pre-push`: the dispatcher (both gates) or just the guard.
if [ "$review" -eq 1 ]; then
  src="$toolkit/hooks/pre-push"
  parts="pre-push-main-guard.sh pre-push-review-gate.sh"
else
  src="$toolkit/hooks/pre-push-main-guard.sh"
  parts=""
fi
[ -f "$src" ] || { echo "error: $src not found — run setup.sh from the toolkit checkout." >&2; exit 1; }

cd "$target" || { echo "error: cannot cd to $target" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "error: $target is not inside a git repository." >&2; exit 1; }

# Resolve the EFFECTIVE hooks directory. `git rev-parse --git-path hooks` always
# returns the default $GIT_DIR/hooks and IGNORES core.hooksPath, so a repo with a
# custom hooks path would get the hook installed where Git never runs it. A
# RELATIVE core.hooksPath is resolved by Git against the worktree root, so do the
# same (this script may run from a subdirectory or with one as the target).
custom="$(git config --get core.hooksPath || true)"
if [ -n "$custom" ]; then
  case "$custom" in
    /* | [A-Za-z]:[/\\]*) hooks_dir="$custom" ;;
    *)                    hooks_dir="$(git rev-parse --show-toplevel)/$custom" ;;
  esac
  echo "• core.hooksPath is set — installing into: $hooks_dir"
  echo "  (if a hook manager owns that dir, add the gate scripts to its pre-push"
  echo "   chain instead of relying on this single-file install.)"
else
  hooks_dir="$(git rev-parse --git-path hooks)"
fi
mkdir -p "$hooks_dir"
dest="$hooks_dir/pre-push"

# install_file SRC DEST: replace DEST with SRC, preserving any unrelated existing
# file under a unique backup, never writing through a symlink.
install_file() {
  s="$1"; dst="$2"
  if [ -e "$dst" ] && cmp -s "$s" "$dst"; then return 0; fi   # already current
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo backup)"
    backup="$dst.backup.$ts"; n=0
    while [ -e "$backup" ] || [ -L "$backup" ]; do n=$((n + 1)); backup="$dst.backup.$ts.$n"; done
    cp -P "$dst" "$backup"   # -P: back up the symlink itself, not its target
    echo "• existing $(basename "$dst") preserved → $backup"
  fi
  rm -f "$dst"               # never write THROUGH an existing symlink
  cp "$s" "$dst"
  chmod +x "$dst"
}

install_file "$src" "$dest"
for p in $parts; do
  rm -f "$hooks_dir/$p"   # never write THROUGH an existing symlink into its target
  cp "$toolkit/hooks/$p" "$hooks_dir/$p"
  chmod +x "$hooks_dir/$p"
done
echo "✓ installed pre-push → $dest"
[ "$review" -eq 1 ] && echo "  (descendant guard + coder-agnostic review-receipt gate)"

cat <<EOF

Remaining wiring (once):
  1. Reviewer (the independent model):
       install @openai/codex and 'codex login' on the review host. To review on
       a remote host, export ARL_REVIEW_HOST=<host> before running review-gate.sh.
  2. Author with anything. Before pushing to a protected branch, record a review:
       $toolkit/review-gate.sh            # reviews HEAD vs main, writes the receipt
       git push                           # the gate above lets it through
  3. (Optional) Claude Code transcript gate — blocks a push when the session shows
       no APPROVE review. It does NOT write receipts; still run review-gate.sh to
       satisfy the receipt gate (or install with --no-review to gate by transcript).
       This toolkit ships .claude/settings.json registering hooks/require-review.py;
       copy that block into another repo's .claude/settings.json (see docs/install.md).

Reviewer AND coder are both pluggable — see docs/protocol.md.
EOF

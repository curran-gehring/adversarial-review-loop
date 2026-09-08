#!/usr/bin/env bash
# Build one labeled bake-off case from real git history.
#
# usage: make-bakeoff-case.sh <repo> <sha> <buggy|clean> <case_dir> [name]
#
#   buggy — <sha> must be a BUG-FIX commit. The case diff is that fix REVERSED,
#           i.e. a diff that provably reintroduces a bug someone really shipped.
#           Files are materialized at <sha>^ (the buggy state), so what the
#           reviewer sees on disk matches what the diff produces.
#   clean — <sha> is a commit believed good. The case diff is the commit itself,
#           files materialized at <sha>.
#
# Materializing only the touched files (rather than checking out a worktree)
# keeps this cheap on a machine that has run out of disk before.
#
# ⚠️ Two honest limits on the labels this produces:
#   1. A reversed fix can be unnaturally easy — it often reads as "a guard was
#      deleted", which is more legible than how the bug originally arrived.
#   2. "clean" means "never subsequently fixed", which is weak evidence of
#      correctness, not proof. False-positive rates are noisier than catch rates.
set -u

REPO="${1:?usage: make-bakeoff-case.sh <repo> <sha> <buggy|clean> <case_dir> [name]}"
SHA="${2:?missing <sha>}"
LABEL="${3:?missing label: buggy|clean}"
CASES="${4:?missing <case_dir>}"
NAME="${5:-}"

case "$LABEL" in buggy|clean) ;; *) echo "label must be buggy|clean" >&2; exit 2 ;; esac
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "not a git repo: $REPO" >&2; exit 2; }
full="$(git -C "$REPO" rev-parse --verify "${SHA}^{commit}" 2>/dev/null)" \
  || { echo "no such commit: $SHA in $REPO" >&2; exit 2; }

[ -n "$NAME" ] || NAME="$(basename "$REPO")-${full:0:8}"
mkdir -p "$CASES"

if [ "$LABEL" = "buggy" ]; then
  git -C "$REPO" rev-parse --verify "${full}^" >/dev/null 2>&1 \
    || { echo "$SHA has no parent; cannot reverse" >&2; exit 2; }
  state="${full}^"
  git -C "$REPO" show -R --no-color "$full" > "$CASES/$NAME.diff"
else
  state="$full"
  git -C "$REPO" show --no-color "$full" > "$CASES/$NAME.diff"
fi

echo "$LABEL" > "$CASES/$NAME.label"

# Materialize touched files at the state the diff leaves behind.
caserepo="$CASES/$NAME.files"
rm -rf "$caserepo"; mkdir -p "$caserepo"
git -C "$REPO" show --pretty=format: --name-only --no-color "$full" \
  | sed '/^$/d' | sort -u | while IFS= read -r f; do
      mkdir -p "$caserepo/$(dirname "$f")"
      git -C "$REPO" show "${state}:${f}" > "$caserepo/$f" 2>/dev/null || true
    done
echo "$caserepo" > "$CASES/$NAME.repo"

subj="$(git -C "$REPO" log -1 --format=%s "$full")"
printf '%-46s %-6s %s\n' "$NAME" "$LABEL" "$subj"
printf '  diff: %s lines, %s file(s)\n' \
  "$(wc -l < "$CASES/$NAME.diff" | tr -d ' ')" \
  "$(find "$caserepo" -type f | wc -l | tr -d ' ')"

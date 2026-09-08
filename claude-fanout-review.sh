#!/usr/bin/env bash
# Parallel scoped Claude adversarial review.
# usage: claude-fanout-review.sh <diff_path> <out_prefix> ["extra context"] [repo_dir]
#
# Launches 3 tightly-scoped Claude reviewers (correctness / data / ui) in
# parallel, each forbidden from exploring unrelated code, each ending with a
# VERDICT line. Same log contract as fanout-review.sh:
#   <out_prefix>.{correctness,data,ui}.log
#
# Requires the `claude` CLI on PATH, logged in to the Claude Code subscription.
# Subscription-only invariant: never pass --bare, never set a metered key, and
# scrub ANTHROPIC_API_KEY from each reviewer subprocess even if the parent shell
# has one.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lenses.sh
. "$here/lenses.sh"

DIFF="${1:?usage: claude-fanout-review.sh <diff_path> <out_prefix> [\"extra context\"] [repo_dir]}"
OUT="${2:?missing <out_prefix>}"
EXTRA="${3:-}"
REPO="${4:-$PWD}"

cd "$REPO" || { echo "claude-fanout-review: cannot cd to repo: $REPO" >&2; exit 1; }

CLAUDE_MODEL="${ARL_CLAUDE_MODEL:-claude-fable-5}"
CLAUDE_TIMEOUT="${ARL_CLAUDE_TIMEOUT:-600}"

# Which lenses this invocation runs. The panel runner sets this to a single
# lens so different lenses can run on different reviewer families; default is
# all three, so every existing caller is unaffected.
ARL_LENSES="${ARL_LENSES:-correctness data ui}"

C="$ARL_LENS_CORRECTNESS"
D="$ARL_LENS_DATA"
U="$ARL_LENS_UI"
RULES="$ARL_LENS_RULES"

run() {
  local name="$1" lens="$2" rc=0 tmo=""
  if command -v timeout >/dev/null 2>&1; then tmo="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then tmo="gtimeout"; fi

  {
    printf 'You are the %s lens of a parallel adversarial code review.\n\n' "$name"
    printf '%s\n\n' "$lens"
    [ -n "$EXTRA" ] && printf 'Extra context: %s\n\n' "$EXTRA"
    printf '%s\n\nUnified diff:\n' "$RULES"
    cat "$DIFF"
  } | {
    if [ -n "$tmo" ]; then
      env -u ANTHROPIC_API_KEY "$tmo" "$CLAUDE_TIMEOUT" claude -p --model "$CLAUDE_MODEL"
    else
      env -u ANTHROPIC_API_KEY claude -p --model "$CLAUDE_MODEL"
    fi
  } > "${OUT}.${name}.log" 2>&1
  rc=$?

  if [ "$rc" -ne 0 ]; then
    printf 'VERDICT: REJECT -- claude reviewer unavailable for %s lens (exit %s)\n' "$name" "$rc" >> "${OUT}.${name}.log"
  elif ! grep -qE '^[[:space:]]*VERDICT[[:space:]]*:' "${OUT}.${name}.log" 2>/dev/null; then
    printf 'VERDICT: REJECT -- claude reviewer emitted no verdict for %s lens\n' "$name" >> "${OUT}.${name}.log"
  fi
}

for _lens in $ARL_LENSES; do
  case "$_lens" in
    correctness) run correctness "$C" & ;;
    data)        run data        "$D" & ;;
    ui)          run ui          "$U" & ;;
    *) echo "unknown lens: $_lens" >&2; exit 2 ;;
  esac
done
wait

echo "FANOUT_DONE"

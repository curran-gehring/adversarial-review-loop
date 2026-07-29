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

DIFF="${1:?usage: claude-fanout-review.sh <diff_path> <out_prefix> [\"extra context\"] [repo_dir]}"
OUT="${2:?missing <out_prefix>}"
EXTRA="${3:-}"
REPO="${4:-$PWD}"

cd "$REPO" || { echo "claude-fanout-review: cannot cd to repo: $REPO" >&2; exit 1; }

CLAUDE_MODEL="${ARL_CLAUDE_MODEL:-claude-fable-5}"
CLAUDE_TIMEOUT="${ARL_CLAUDE_TIMEOUT:-600}"

C="Review ONLY correctness & concurrency: logic/ordering bugs, off-by-one and boundary errors, race conditions, threading/async and isolation, object lifecycle, null/undefined/force-unwrap and crash paths, resource leaks and reference cycles, error handling."
D="Review ONLY data & persistence: SQL and schema, migrations, sync/record round-trips, serialization/parsing, units and coordinate math, and set/index/dedupe logic."
U="Review ONLY UI/view-layer correctness & regressions: view/component state, list/key identity, framework/API validity for the target platform, reuse/duplication, and that unrelated surfaces are not regressed."
RULES="Read ONLY the files this diff touches; do NOT explore unrelated code. Be concise. The repo may not be compilable here, so do not rely on building it. End with a final line that is EXACTLY one of: 'VERDICT: APPROVE' or 'VERDICT: REJECT -- <one-line reason>'."

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

run correctness "$C" &
run data "$D" &
run ui "$U" &
wait

echo "FANOUT_DONE"

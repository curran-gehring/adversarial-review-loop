#!/usr/bin/env bash
# Parallel scoped Codex adversarial review.
# usage: fanout-review.sh <diff_path> <out_prefix> ["extra context"] [repo_dir]
#
# Launches 3 tightly-scoped codex workers (correctness / data / ui) in parallel,
# each forbidden from exploring unrelated code, each ending with a VERDICT line.
# Writes one log per lens: <out_prefix>.{correctness,data,ui}.log
#
# Aggregate APPROVE iff all 3 say APPROVE. The caller does the aggregation:
#   grep -h '^VERDICT:' <out_prefix>.*.log
# (a single REJECT among the three means REJECT.)
#
# Requires the `codex` CLI (@openai/codex) on PATH, logged in.
set -u

DIFF="${1:?usage: fanout-review.sh <diff_path> <out_prefix> [\"extra context\"] [repo_dir]}"
OUT="${2:?missing <out_prefix>}"
EXTRA="${3:-}"
REPO="${4:-$PWD}"   # default: current directory; pass the repo so codex can read source

cd "$REPO" || { echo "fanout-review: cannot cd to repo: $REPO" >&2; exit 1; }

C="Review ONLY correctness & concurrency: logic/ordering bugs, off-by-one and boundary errors, race conditions, threading/async and isolation, object lifecycle, null/undefined/force-unwrap and crash paths, resource leaks and reference cycles, error handling."
D="Review ONLY data & persistence: SQL and schema, migrations, sync/record round-trips, serialization/parsing, units and coordinate math, and set/index/dedupe logic."
U="Review ONLY UI/view-layer correctness & regressions: view/component state, list/key identity, framework/API validity for the target platform, reuse/duplication, and that unrelated surfaces are not regressed."
RULES="Read ONLY the files this diff touches; do NOT explore unrelated code. Be concise. The repo may not be compilable here, so do not rely on building it. End with a final line that is EXACTLY one of: 'VERDICT: APPROVE' or 'VERDICT: REJECT -- <one-line reason>'."

run() {
  local name="$1"; local lens="$2"
  cat "$DIFF" | codex exec -s read-only --skip-git-repo-check \
    "You are the ${name} lens of a parallel adversarial code review. ${lens} ${EXTRA} ${RULES}" \
    > "${OUT}.${name}.log" 2>&1
}

run correctness "$C" &
run data "$D" &
run ui "$U" &
wait

echo "FANOUT_DONE"

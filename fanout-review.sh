#!/usr/bin/env bash
# Model-aware parallel scoped adversarial review.
# usage: fanout-review.sh <diff_path> <out_prefix> ["extra context"] [repo_dir]
#
# If the primary coder is Codex, dispatch Claude reviewers. If the primary coder
# is Claude (or unknown/legacy), dispatch Codex reviewers. Override with:
#   ARL_PRIMARY_MODEL=codex|claude
#
# Launches 3 tightly-scoped workers (correctness / data / ui) in parallel, each
# forbidden from exploring unrelated code, each ending with a VERDICT line.
# Writes one log per lens: <out_prefix>.{correctness,data,ui}.log
#
# Aggregate APPROVE iff all 3 say APPROVE. The caller does the aggregation:
#   grep -h '^VERDICT:' <out_prefix>.*.log
# (a single REJECT among the three means REJECT.)
#
# Requires the `codex` CLI (@openai/codex) on PATH, logged in.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lenses.sh
. "$here/lenses.sh"

detect_primary_model() {
  case "${ARL_PRIMARY_MODEL:-}" in
    codex|Codex|CODEX) echo "codex"; return ;;
    claude|Claude|CLAUDE) echo "claude"; return ;;
  esac

  if [ -n "${CODEX_SHELL:-}" ] || [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_CI:-}" ]; then
    echo "codex"
    return
  fi

  echo "claude"
}

# An explicit backend choice wins over primary-coder detection. Use this to run
# the lenses on a model from neither the Claude nor the Codex family, so the
# three lenses stop sharing one model's blind spots.
if [ "${ARL_FANOUT_BACKEND:-}" = "openrouter" ]; then
  exec "$here/openrouter-fanout-review.sh" "$@"
fi

if [ "${ARL_FORCE_CODEX_FANOUT:-}" != "1" ] && [ "$(detect_primary_model)" = "codex" ]; then
  exec "$here/claude-fanout-review.sh" "$@"
fi

DIFF="${1:?usage: fanout-review.sh <diff_path> <out_prefix> [\"extra context\"] [repo_dir]}"
OUT="${2:?missing <out_prefix>}"
EXTRA="${3:-}"
REPO="${4:-$PWD}"   # default: current directory; pass the repo so codex can read source

cd "$REPO" || { echo "fanout-review: cannot cd to repo: $REPO" >&2; exit 1; }

C="$ARL_LENS_CORRECTNESS"
D="$ARL_LENS_DATA"
U="$ARL_LENS_UI"
RULES="$ARL_LENS_RULES"

run() {
  local name="$1"; local lens="$2"
  cat "$DIFF" | codex exec -s read-only --skip-git-repo-check --model "${ARL_CODEX_MODEL:-gpt-5.6-luna}" \
    "You are the ${name} lens of a parallel adversarial code review. ${lens} ${EXTRA} ${RULES}" \
    > "${OUT}.${name}.log" 2>&1
}

run correctness "$C" &
run data "$D" &
run ui "$U" &
wait

echo "FANOUT_DONE"

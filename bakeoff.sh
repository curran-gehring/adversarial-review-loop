#!/usr/bin/env bash
# Reviewer bake-off: score candidate models on a LABELED diff set.
#
# usage: bakeoff.sh <case_dir> <out_dir> [repo_dir]
#
# A case is a pair of files in <case_dir>:
#   <name>.diff    the unified diff to review
#   <name>.label   exactly one word: "buggy" or "clean"
#   <name>.repo    optional; repo the diff belongs to (else [repo_dir], else $PWD)
#
# Scoring, on the gate's own rule (APPROVE iff all three lenses APPROVE):
#   buggy diff -> a REJECT is a CATCH; an APPROVE is a MISS
#   clean diff -> an APPROVE is correct; a REJECT is a FALSE POSITIVE
#
# Both axes matter. A model that REJECTs everything scores a perfect catch rate
# and is useless as a gate — it trains you to ignore it. Read the two columns
# together, and read the logs behind them before trusting either.
#
# env:
#   ARL_BAKEOFF_MODELS  comma-separated OpenRouter slugs (default: the four candidates)
#   OPENROUTER_API_KEY  required (passed through to the backend)
set -u

here="$(cd "$(dirname "$0")" && pwd)"
CASES="${1:?usage: bakeoff.sh <case_dir> <out_dir> [repo_dir]}"
OUTDIR="${2:?missing <out_dir>}"
REPO="${3:-$PWD}"

[ -d "$CASES" ] || { echo "bakeoff: no such case dir: $CASES" >&2; exit 2; }
[ -n "${OPENROUTER_API_KEY:-}" ] || { echo "bakeoff: OPENROUTER_API_KEY is not set" >&2; exit 2; }

MODELS="${ARL_BAKEOFF_MODELS:-google/gemini-3.8-flash,moonshotai/kimi-k3,z-ai/glm-5.3,meituan/longcat-2.0}"
mkdir -p "$OUTDIR"

# Collect cases up front so a malformed set fails before any money is spent.
names=""
for d in "$CASES"/*.diff; do
  [ -f "$d" ] || continue
  n="$(basename "$d" .diff)"
  lf="$CASES/$n.label"
  [ -f "$lf" ] || { echo "bakeoff: $n.diff has no $n.label" >&2; exit 2; }
  case "$(tr -d '[:space:]' < "$lf")" in
    buggy|clean) ;;
    *) echo "bakeoff: $n.label must be exactly 'buggy' or 'clean'" >&2; exit 2 ;;
  esac
  names="$names $n"
done
[ -n "$names" ] || { echo "bakeoff: no .diff cases found in $CASES" >&2; exit 2; }

# The gate verdict for one run: APPROVE iff all three lenses APPROVE.
# Takes the LAST verdict line per lens — a chatty reviewer can emit the word
# earlier in its prose, and the final line is the contract.
gate_verdict() {
  local prefix="$1" lens v approve=0 seen=0
  for lens in correctness data ui; do
    [ -f "${prefix}.${lens}.log" ] || { echo REJECT; return; }
    v="$(grep -E '^[[:space:]]*VERDICT[[:space:]]*:' "${prefix}.${lens}.log" | tail -1)"
    seen=$((seen + 1))
    case "$v" in
      *APPROVE*) approve=$((approve + 1)) ;;
      *) ;;                      # REJECT, or no verdict at all -> not an approve
    esac
  done
  [ "$seen" -eq 3 ] && [ "$approve" -eq 3 ] && echo APPROVE || echo REJECT
}

printf 'bake-off: %s case(s) x %s model(s)\n\n' \
  "$(echo $names | wc -w | tr -d ' ')" "$(echo "$MODELS" | tr ',' '\n' | wc -l | tr -d ' ')"

report="$OUTDIR/report.txt"
: > "$report"

IFS=','
for model in $MODELS; do
  unset IFS
  slug="$(echo "$model" | tr '/:' '__')"
  caught=0; buggy=0; fp=0; clean=0
  started=$(date +%s)

  for n in $names; do
    label="$(tr -d '[:space:]' < "$CASES/$n.label")"
    repo="$REPO"; [ -f "$CASES/$n.repo" ] && repo="$(tr -d '[:space:]' < "$CASES/$n.repo")"
    prefix="$OUTDIR/${slug}.${n}"

    ARL_OPENROUTER_MODEL="$model" \
      "$here/openrouter-fanout-review.sh" "$CASES/$n.diff" "$prefix" \
      "bake-off case: $n" "$repo" >/dev/null 2>&1

    v="$(gate_verdict "$prefix")"
    if [ "$label" = "buggy" ]; then
      buggy=$((buggy + 1)); [ "$v" = "REJECT" ] && caught=$((caught + 1))
    else
      clean=$((clean + 1)); [ "$v" = "REJECT" ] && fp=$((fp + 1))
    fi
    printf '  %-28s %-10s %-8s -> %s\n' "$model" "$n" "$label" "$v"
  done

  elapsed=$(( $(date +%s) - started ))
  printf '%-28s caught %d/%d   false-pos %d/%d   %ds\n' \
    "$model" "$caught" "$buggy" "$fp" "$clean" "$elapsed" >> "$report"
  IFS=','
done
unset IFS

printf '\n=== bake-off results ===\n'
printf '%s\n' "(caught = bugs found on known-buggy diffs; false-pos = REJECTs on known-clean diffs)"
cat "$report"
printf '\nper-lens logs: %s\n' "$OUTDIR"
printf 'Read the logs before trusting the table — a model can be right for a wrong reason.\n'

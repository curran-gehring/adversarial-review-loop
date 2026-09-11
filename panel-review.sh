#!/usr/bin/env bash
# Mixed-panel adversarial review: run each lens on a DIFFERENT reviewer family.
#
# usage: panel-review.sh <diff_path> <out_prefix> ["extra context"] [repo_dir]
#
# Same log contract as every other backend — <out_prefix>.{correctness,data,ui}.log,
# each ending in a VERDICT line, APPROVE iff all three APPROVE — so review-gate.sh
# and the pre-push hook consume it unchanged.
#
# WHY THIS EXISTS (measured, 2026-09-08 bake-off over 12 labeled diffs from real
# Rendition history): a single-model panel ships real bugs, because the three
# lenses share one model's blind spots.
#
#   gpt-5.6-luna       8/8 caught, 1/4 false-pos, 29m — MISSED the @ObservationIgnored
#                      subscription bug in a5ffe186 (rejected that diff for an
#                      unrelated purchase-stats complaint)
#   gemini-3.8-flash   7/8 caught, 0/4 false-pos,  8m — FOUND it, but MISSED the
#                      unreachable Non-food screen in db693146
#
# Each found a real shipped bug the other missed. Both bugs are in main today.
#
# CONFIG — ARL_PANEL, comma-separated "lens=backend:model":
#   ARL_PANEL="correctness=codex:gpt-5.6-luna,data=gemini:gemini-3.1-pro-high,ui=gemini:gemini-3.1-pro-high"
# Backends: codex (ChatGPT subscription, reads the repo), claude (Claude
# subscription), gemini (Antigravity CLI on the Google AI Pro/Ultra
# subscription), openrouter (metered; needs OPENROUTER_API_KEY).
#
# The default panel is now entirely flat-rate: the Gemini lenses moved from
# openrouter to the `gemini` backend on 2026-09-11, which buys the same
# cross-family independence for $0/run instead of ~$0.07. openrouter is kept
# for models no subscription covers.
#
# A lens absent from ARL_PANEL FAILS CLOSED. An unreviewed lens is a failed
# review, not a pass — the same rule the individual backends follow.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
DIFF="${1:?usage: panel-review.sh <diff_path> <out_prefix> [\"extra context\"] [repo_dir]}"
OUT="${2:?missing <out_prefix>}"
EXTRA="${3:-}"
REPO="${4:-$PWD}"

DEFAULT_PANEL="correctness=codex:gpt-5.6-luna,data=gemini:gemini-3.1-pro-high,ui=gemini:gemini-3.1-pro-high"
PANEL="${ARL_PANEL:-$DEFAULT_PANEL}"

[ -f "$DIFF" ] || { echo "panel-review: no such diff: $DIFF" >&2; exit 2; }

# Validate the whole spec BEFORE running anything, so a typo fails in a second
# rather than after one lens has already been paid for.
assigned=""
IFS=','
for entry in $PANEL; do
  unset IFS
  lens="${entry%%=*}"; rest="${entry#*=}"
  backend="${rest%%:*}"; model="${rest#*:}"
  case "$lens" in
    correctness|data|ui) ;;
    *) echo "panel-review: unknown lens '$lens' in ARL_PANEL" >&2; exit 2 ;;
  esac
  case "$backend" in
    codex|claude|openrouter|gemini) ;;
    *) echo "panel-review: unknown backend '$backend' for lens '$lens' (codex|claude|openrouter|gemini)" >&2; exit 2 ;;
  esac
  [ -n "$model" ] && [ "$model" != "$rest" ] \
    || { echo "panel-review: lens '$lens' has no model (expected backend:model)" >&2; exit 2; }
  if [ "$backend" = "openrouter" ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo "panel-review: lens '$lens' uses openrouter but OPENROUTER_API_KEY is not set" >&2; exit 2
  fi
  if [ "$backend" = "gemini" ] && ! command -v "${ARL_GEMINI_BIN:-agy}" >/dev/null 2>&1; then
    echo "panel-review: lens '$lens' uses gemini but '${ARL_GEMINI_BIN:-agy}' is not on PATH (winget install Google.AntigravityCLI)" >&2; exit 2
  fi
  case " $assigned " in
    *" $lens "*) echo "panel-review: lens '$lens' assigned twice" >&2; exit 2 ;;
  esac
  assigned="$assigned $lens"
  IFS=','
done
unset IFS

# Clear every lens log BEFORE dispatching. The check at the bottom asks only
# whether a VERDICT line exists, and each backend is launched with its output
# suppressed, so a backend that dies in preflight leaves the PREVIOUS run's log
# in place and that run's `VERDICT: APPROVE` is read as this one's — passing a
# diff nobody reviewed. Backends clear the logs they own too, but only the panel
# can guarantee it, because only the panel sees a backend's exit code.
# The fix-then-rerun loop reuses one out-prefix by design, which is exactly when
# a stale approval is sitting there waiting to be inherited.
for lens in correctness data ui; do
  log="${OUT}.${lens}.log"
  : > "$log" 2>/dev/null || rm -f "$log" 2>/dev/null || true
  if [ -e "$log" ] && grep -qE '^[[:space:]]*VERDICT[[:space:]]*:' "$log" 2>/dev/null; then
    echo "panel-review: cannot clear a stale verdict in $log; refusing to run" >&2
    exit 2
  fi
done

# Launch each assigned lens on its own backend, all in parallel.
IFS=','
for entry in $PANEL; do
  unset IFS
  lens="${entry%%=*}"; rest="${entry#*=}"
  backend="${rest%%:*}"; model="${rest#*:}"
  case "$backend" in
    codex)      script="$here/fanout-review.sh";            var=ARL_CODEX_MODEL;      extra_env="ARL_FORCE_CODEX_FANOUT=1" ;;
    claude)     script="$here/claude-fanout-review.sh";     var=ARL_CLAUDE_MODEL;     extra_env="ARL_NOOP=1" ;;
    openrouter) script="$here/openrouter-fanout-review.sh"; var=ARL_OPENROUTER_MODEL; extra_env="ARL_NOOP=1" ;;
    gemini)     script="$here/gemini-fanout-review.sh";     var=ARL_GEMINI_MODEL;     extra_env="ARL_NOOP=1" ;;
  esac
  env ARL_LENSES="$lens" "$extra_env" "$var=$model" \
    "$script" "$DIFF" "$OUT" "$EXTRA" "$REPO" >/dev/null 2>&1 &
  IFS=','
done
unset IFS
wait

# Any lens the panel did not cover must fail closed.
for lens in correctness data ui; do
  log="${OUT}.${lens}.log"
  if ! grep -qE '^[[:space:]]*VERDICT[[:space:]]*:' "$log" 2>/dev/null; then
    printf 'VERDICT: REJECT -- panel produced no verdict for the %s lens\n' "$lens" >> "$log"
  fi
done

echo "FANOUT_DONE"

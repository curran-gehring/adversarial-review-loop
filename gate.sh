#!/bin/sh
# The review gate's entry point: pick a panel, pick a runner, hand off.
# usage: gate.sh <diff_path> <out_prefix> ["extra context"] [repo_dir]
#
# This logic used to live only in an untracked ~/fanout-review.sh on the
# mac-mini, which meant Windows had no gate at all and the two hosts could not
# be brought into line even in principle. It is version-controlled here so both
# machines run the same gate; the ONLY per-host difference is the default
# repo_dir, supplied as ARL_DEFAULT_REPO by a thin shim.
#
# DEFAULT GATE = MIXED PANEL (switched 2026-09-08, from the 12-case bake-off over
# real Rendition history). One model on all three lenses ships real bugs, because
# the lenses share that model's blind spots:
#   gpt-5.6-luna      8/8 caught, 1/4 false-pos, 29m — MISSED the @ObservationIgnored
#                     subscription bug (rejected that diff for an unrelated reason)
#   gemini-3.8-flash  7/8 caught, 0/4 false-pos,  8m — found it, but MISSED the
#                     unreachable Non-food screen
# Each caught a real shipped bug the other missed. The panel runs both families.
#
# The correctness lens stays on codex (ChatGPT subscription, and it can READ THE
# REPO, which the HTTP backends cannot). Since 2026-09-11 the two Gemini lenses
# run on the Google AI Pro subscription via Antigravity CLI rather than metered
# OpenRouter, so a default panel run now costs nothing.
set -u

here="$(cd "$(dirname "$0")" && pwd)"

DIFF="${1:?usage: gate.sh <diff_path> <out_prefix> [\"extra context\"] [repo_dir]}"
OUT="${2:?missing <out_prefix>}"
EXTRA="${3:-}"
REPO="${4:-${ARL_DEFAULT_REPO:-$PWD}}"

export ARL_PANEL="${ARL_PANEL:-correctness=codex:gpt-5.6-luna,data=gemini:gemini-3.1-pro-high,ui=gemini:gemini-3.1-pro-high}"

export ARL_CODEX_MODEL="${ARL_CODEX_MODEL:-gpt-5.6-luna}"
export ARL_CLAUDE_MODEL="${ARL_CLAUDE_MODEL:-claude-sonnet-5}"
export ARL_OPENROUTER_MODEL="${ARL_OPENROUTER_MODEL:-google/gemini-3.8-flash}"
export ARL_GEMINI_MODEL="${ARL_GEMINI_MODEL:-gemini-3.1-pro-high}"

# Escape hatches, all preserving the same log/VERDICT contract:
#   ARL_GATE=single  -> all three lenses on ONE model, chosen to be a different
#                       family from whoever is writing the code: fanout-review.sh
#                       sends a Claude author to codex and a codex author to
#                       Claude. It is not "always codex" — that would hand the
#                       review to the same family that wrote the diff, which is
#                       the single-model blind spot the panel exists to avoid.
#                       Set ARL_FORCE_CODEX_FANOUT=1 to pin codex regardless.
#   ARL_GATE=nocodex -> codex-free panel (see below)
#   ARL_PANEL=...    -> reassign lenses, e.g. escalate one to x-ai/grok-4.6
# Use ARL_GATE=single if OpenRouter is down or unfunded — the panel FAILS CLOSED
# on a missing key rather than silently degrading to a weaker review.

# ARL_GATE=nocodex -> codex-free panel, for when the ChatGPT subscription is out
# of usage. The correctness lens moves to the SAME model (gpt-5.6-luna) over
# OpenRouter, so the panel keeps its two-family structure and the bake-off
# numbers above still describe it. Two differences worth knowing:
#   - it costs money on all three lenses (~$0.10/run; luna is $0.20/$1.20 per
#     Mtok, cheaper than the Gemini lenses beside it), and
#   - the HTTP backend cannot browse the repo, so correctness sees the diff plus
#     the current contents of every file the diff touches, not the whole tree.
# openai/gpt-5.6-luna must stay on the proxy worker's ALLOWED_MODELS or this
# fails closed with a 400 (adversarial-review-loop/openrouter-proxy).
if [ "${ARL_GATE:-panel}" = "nocodex" ]; then
  export ARL_PANEL="correctness=openrouter:openai/gpt-5.6-luna,data=openrouter:google/gemini-3.8-flash,ui=openrouter:google/gemini-3.8-flash"
  exec "$here/panel-review.sh" "$DIFF" "$OUT" "$EXTRA" "$REPO"
fi

if [ "${ARL_GATE:-panel}" = "single" ]; then
  exec "$here/fanout-review.sh" "$DIFF" "$OUT" "$EXTRA" "$REPO"
fi

exec "$here/panel-review.sh" "$DIFF" "$OUT" "$EXTRA" "$REPO"

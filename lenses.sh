#!/usr/bin/env bash
# Shared lens definitions for every fan-out backend (codex / claude / openrouter).
#
# Sourced, never executed. Keeping one copy means a wording change lands in all
# backends at once — three drifting copies of a safety gate's prompts is a way
# for the gate to quietly stop asking the same question of each reviewer.
#
# Exposes: ARL_LENS_CORRECTNESS, ARL_LENS_DATA, ARL_LENS_UI, ARL_LENS_RULES

ARL_LENS_CORRECTNESS="Review ONLY correctness & concurrency: logic/ordering bugs, off-by-one and boundary errors, race conditions, threading/async and isolation, object lifecycle, null/undefined/force-unwrap and crash paths, resource leaks and reference cycles, error handling."
ARL_LENS_DATA="Review ONLY data & persistence: SQL and schema, migrations, sync/record round-trips, serialization/parsing, units and coordinate math, and set/index/dedupe logic."
ARL_LENS_UI="Review ONLY UI/view-layer correctness & regressions: view/component state, list/key identity, framework/API validity for the target platform, reuse/duplication, and that unrelated surfaces are not regressed."
# Two clauses below are load-bearing, both added 2026-09-08 from observed failures:
#
#   "State briefly what you checked" — a Gemini lens returned a 16-byte log
#   containing only 'VERDICT: APPROVE'. Contractually valid and, that time,
#   correct — but a verdict you cannot interrogate is close to no review at all,
#   and gives the author nothing to weigh when the lens is wrong.
#
#   The compile-claim clause — a codex lens REJECTed shipped, compiling code with
#   "PaletteKey cannot synthesize Hashable because RenditionTheme is not
#   Hashable". RenditionTheme is a String-raw-value enum, so Hashable IS
#   synthesized. This lens has a documented history of false "won't compile"
#   claims; it cannot build the repo and often cannot see the definitions it is
#   reasoning about. The clause narrows that without forbidding real findings.
ARL_LENS_RULES="Read ONLY the files this diff touches; do NOT explore unrelated code. Be concise, but ALWAYS state briefly what you checked and what you found before the verdict — a bare verdict with no reasoning is not a review, and will be treated as a failed one. You CANNOT build the repo here and you are seeing only part of it: do NOT assert a compile, type, or conformance error unless the diff itself plainly introduces it AND you can name the exact symbol and the rule it breaks. Remember that definitions, extensions and imports may live outside this diff, and that conformances are often synthesized rather than written (Swift derives Hashable/Equatable/Codable for enums with raw values and for structs whose members conform). If you are unsure whether something compiles, raise it as a question in your reasoning rather than as a REJECT. Reserve REJECT for a defect you can point at. End with a final line that is EXACTLY one of: 'VERDICT: APPROVE' or 'VERDICT: REJECT -- <one-line reason>'."

# --- shared safety preamble -------------------------------------------------
# Every backend takes <diff_path> <out_prefix> and then cds to the repo. Both
# paths must therefore be made absolute BEFORE that cd, and the two reasons are
# not symmetric:
#
#   DIFF relative -> fails to open from inside the repo, and neither `cat` nor
#   `awk` failing aborts under `set -u`. The reviewer receives an EMPTY diff,
#   and a model with nothing to criticize can answer APPROVE. That is a
#   fail-OPEN in a gate whose only job is to catch bad changes.
#
#   OUT relative -> logs land under the repo while the caller reads them from
#   its own directory, so a lens that genuinely APPROVED is scored as "produced
#   no verdict". Fails closed, but costs a whole review round to diagnose.
#
# These live here, beside the lens prompts, for the same stated reason those do:
# several drifting copies of a safety gate's argument handling is how the gate
# quietly stops protecting one of its backends.

# arl_abs <path> — print <path> resolved against $PWD if it is relative.
# Git Bash passes Windows-style absolute paths through unchanged, so C:/x and
# C:\x must count as absolute; treating them as relative would produce
# "$PWD/C:/x" and silently lose the file.
arl_abs() {
  case "$1" in
    /*|[A-Za-z]:[/\\]*) printf '%s\n' "$1" ;;
    *)                  printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

# arl_pick_python — print the first interpreter that actually RUNS.
# Resolving is not enough: on Windows `python3` is usually the App Execution
# Alias stub, which satisfies `command -v` and then fails at launch with
# 0x80070003. Trusting it turns a broken environment into three REJECTs that
# read like real review findings. ARL_PYTHON overrides the search.
arl_pick_python() {
  _arl_py=""
  for _arl_cand in ${ARL_PYTHON:-} python3 python py; do
    [ -n "$_arl_cand" ] || continue
    command -v "$_arl_cand" >/dev/null 2>&1 || continue
    "$_arl_cand" -c 'pass' >/dev/null 2>&1 || continue
    _arl_py="$_arl_cand"; break
  done
  [ -n "$_arl_py" ] || return 1
  printf '%s\n' "$_arl_py"
}

# arl_clear_logs <out_prefix> <lens>... — clear the lens logs this invocation
# owns, and return non-zero if a previous run's verdict survives.
#
# Must be called BEFORE any preflight check that can exit. Callers ask only
# whether a VERDICT line exists and suppress the backend's stderr, so a stale
# `VERDICT: APPROVE` left behind by an early exit is read as this run's verdict
# — passing a diff nobody reviewed. The fix-then-rerun loop reuses one
# out-prefix by design, which is exactly when that happens.
#
# Verifying rather than trusting the truncation is the point: `: >` can fail on
# a read-only parent, and `|| true` would turn that into a silent fail-open.
# arl_lock_prefix <out_prefix> — take an exclusive lock on an out-prefix.
# arl_unlock_prefix                — release it (call from an EXIT trap).
#
# Two runs sharing one prefix interleave their lens logs, and the aggregate is
# then read from a mixture of both — which can approve the wrong diff. The
# canonical entry point (review-gate.sh) uses mktemp so its runs never collide,
# and the documented protocol is one diff at a time, so this only bites when a
# prefix is passed by hand twice. Cheap to make impossible, though, and the
# failure it prevents is silent.
#
# mkdir is the lock because it is atomic on every filesystem we care about. Only
# the top-level runner locks; it exports ARL_PREFIX_LOCK_HELD so the backends it
# launches under the same prefix do not deadlock against their own parent.
arl_lock_prefix() {
  [ -z "${ARL_PREFIX_LOCK_HELD:-}" ] || return 0
  ARL_PREFIX_LOCK_DIR="$1.lock"
  if ! mkdir "$ARL_PREFIX_LOCK_DIR" 2>/dev/null; then
    echo "arl: another review already holds the out-prefix $1" >&2
    echo "arl: give this run a different out-prefix, or remove $ARL_PREFIX_LOCK_DIR if a previous run crashed." >&2
    ARL_PREFIX_LOCK_DIR=""
    return 1
  fi
  ARL_PREFIX_LOCK_HELD=1
  export ARL_PREFIX_LOCK_HELD
}

arl_unlock_prefix() {
  [ -n "${ARL_PREFIX_LOCK_DIR:-}" ] || return 0
  rmdir "$ARL_PREFIX_LOCK_DIR" 2>/dev/null || true
  ARL_PREFIX_LOCK_DIR=""
}

arl_clear_logs() {
  _arl_out="$1"; shift
  for _arl_lens in "$@"; do
    _arl_log="${_arl_out}.${_arl_lens}.log"
    : > "$_arl_log" 2>/dev/null || rm -f "$_arl_log" 2>/dev/null || true
    if [ -e "$_arl_log" ] && grep -qE '^[[:space:]]*VERDICT[[:space:]]*:' "$_arl_log" 2>/dev/null; then
      echo "arl: cannot clear a stale verdict in $_arl_log; refusing to run" >&2
      return 1
    fi
  done
}

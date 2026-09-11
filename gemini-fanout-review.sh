#!/usr/bin/env bash
# Parallel scoped adversarial review via the Antigravity CLI (`agy`).
# usage: gemini-fanout-review.sh <diff_path> <out_prefix> ["extra context"] [repo_dir]
#
# Same contract as fanout-review.sh / claude-fanout-review.sh / openrouter-*:
#   writes <out_prefix>.{correctness,data,ui}.log, each ending in a VERDICT line.
#   Aggregate APPROVE iff all three APPROVE.
#
# Why this backend exists: it puts Gemini lenses on the Google AI Pro / Ultra
# subscription instead of metered OpenRouter tokens. Google shut the personal
# tier of `gemini` (Gemini CLI) off on 2026-06-18 — it now answers OAuth with
# IneligibleTierError/UNSUPPORTED_CLIENT — and Antigravity CLI is the supported
# replacement for individual plans. So this is the gemini backend; there is no
# working `gemini`-CLI equivalent to fall back to.
#
# Like the openrouter backend and unlike the codex one, the reviewer does not
# read the repo: agy runs here with no tool permissions granted, so the current
# contents of every file the diff touches are inlined below the diff.
#
# env:
#   ARL_GEMINI_MODEL     agy model id (default gemini-3.1-pro-high).
#                        `agy models` lists valid ids.
#   ARL_GEMINI_BIN       CLI to invoke (default agy)
#   ARL_GEMINI_TIMEOUT   per-lens timeout, agy duration syntax (default 10m)
#   ARL_GEMINI_MAX_BYTES cap on total inlined file bytes (default 400000)
#   ARL_LENSES           which lenses to run (default "correctness data ui")
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lenses.sh
. "$here/lenses.sh"

DIFF="${1:?usage: gemini-fanout-review.sh <diff_path> <out_prefix> [\"extra context\"] [repo_dir]}"
OUT="${2:?missing <out_prefix>}"
EXTRA="${3:-}"
REPO="${4:-$PWD}"

BIN="${ARL_GEMINI_BIN:-agy}"
MODEL="${ARL_GEMINI_MODEL:-gemini-3.1-pro-high}"
TIMEOUT="${ARL_GEMINI_TIMEOUT:-10m}"
MAX_BYTES="${ARL_GEMINI_MAX_BYTES:-400000}"

# Fail fast at the boundary: a missing CLI or diff must not surface as three
# REJECTs that read like the reviewer found real bugs.
command -v "$BIN" >/dev/null 2>&1 || {
  echo "gemini-fanout: '$BIN' not found on PATH (install: winget install Google.AntigravityCLI)" >&2; exit 2; }

# Resolve the diff to an absolute path BEFORE the cd below. A relative path
# passes the -f check here and then fails to open from inside REPO, which would
# hand the reviewer an EMPTY diff — and a model with nothing to criticize can
# answer APPROVE. That is a fail-OPEN in a gate whose only job is to catch bad
# changes, so it must be impossible by construction rather than by convention.
case "$DIFF" in
  /*) ;;
  *)  DIFF="$PWD/$DIFF" ;;
esac
[ -f "$DIFF" ] || { echo "gemini-fanout: no such diff: $DIFF" >&2; exit 2; }

# Same treatment for the output prefix, for the mirror-image reason: logs written
# under REPO while panel-review.sh reads them from its own directory turn a lens
# that genuinely APPROVED into "produced no verdict" — a false REJECT.
case "$OUT" in
  /*) ;;
  *)  OUT="$PWD/$OUT" ;;
esac

# Pick an interpreter that actually runs, not merely one that resolves. On
# Windows `python3` is usually the App Execution Alias stub, which sits on PATH,
# satisfies `command -v`, and then fails at launch with 0x80070003 — turning a
# broken environment into three REJECTs that look like review findings.
PY=""
for _py in ${ARL_PYTHON:-} python3 python py; do
  [ -n "$_py" ] || continue
  command -v "$_py" >/dev/null 2>&1 || continue
  "$_py" -c 'pass' >/dev/null 2>&1 || continue
  PY="$_py"; break
done
[ -n "$PY" ] || {
  echo "gemini-fanout: no working Python found (tried ${ARL_PYTHON:+$ARL_PYTHON }python3 python py); set ARL_PYTHON" >&2; exit 2; }

cd "$REPO" || { echo "gemini-fanout: cannot cd to repo: $REPO" >&2; exit 2; }

# Which lenses this invocation runs. The panel runner sets this to a single
# lens so different lenses can run on different reviewer families; default is
# all three, so every existing caller is unaffected.
ARL_LENSES="${ARL_LENSES:-correctness data ui}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

# --- context: the diff, plus current contents of the files it touches --------
ctx="$tmp/context.txt"
{
  printf 'Unified diff under review:\n\n'
  cat "$DIFF"

  budget="$MAX_BYTES"
  # Paths from the "+++ b/path" lines; /dev/null marks a deletion.
  awk '/^\+\+\+ /{p=$2; sub(/^b\//,"",p); if (p != "/dev/null") print p}' "$DIFF" \
    | sort -u | while IFS= read -r f; do
      [ -f "$f" ] || continue
      size=$(wc -c < "$f" | tr -d ' ')
      printf '\n\n--- current contents of %s ---\n' "$f"
      if [ "$size" -gt "$budget" ]; then
        head -c "$budget" "$f"
        printf '\n[TRUNCATED: %s is %s bytes; inline budget exhausted]\n' "$f" "$size"
        budget=0
      else
        cat "$f"
        budget=$((budget - size))
      fi
      [ "$budget" -le 0 ] && break
    done
} > "$ctx"

# Belt and braces on the same failure class: whatever went wrong upstream, never
# let a context that does not actually contain the diff reach a reviewer.
grep -q '^\(diff --git\|--- \|+++ \|@@ \)' "$ctx" 2>/dev/null || {
  echo "gemini-fanout: built an empty or diff-less context from $DIFF; refusing to review nothing" >&2
  exit 3; }

# --- one lens ---------------------------------------------------------------
run() {
  local name="$1" lens="$2"
  local log="${OUT}.${name}.log"
  local msg="$tmp/${name}.ndjson" body="$tmp/${name}.out"
  local rc=0

  # The prompt goes down stdin as a stream-json message, never on argv: `agy -p`
  # takes its prompt as an argument and Windows caps a command line near 32 KB,
  # far below a real diff plus its inlined files.
  ARL_LENS_NAME="$name" ARL_LENS_TEXT="$lens" ARL_EXTRA="$EXTRA" \
  ARL_RULES="$ARL_LENS_RULES" ARL_CTX="$ctx" ARL_MSG="$msg" \
  "$PY" -c '
import json, os
prompt = "\n\n".join(x for x in [
    "You are the %s lens of a parallel adversarial code review." % os.environ["ARL_LENS_NAME"],
    os.environ["ARL_LENS_TEXT"],
    ("Extra context: " + os.environ["ARL_EXTRA"]) if os.environ.get("ARL_EXTRA") else "",
    os.environ["ARL_RULES"],
    open(os.environ["ARL_CTX"], encoding="utf-8", errors="replace").read(),
] if x)
with open(os.environ["ARL_MSG"], "w", encoding="utf-8") as fh:
    # One NDJSON message, one turn. ensure_ascii keeps it single-line-safe.
    fh.write(json.dumps({"event": "user", "message": {"content": prompt}}) + "\n")
' 2>>"$log" || {
    printf 'VERDICT: REJECT -- gemini %s lens could not build its request\n' "$name" >> "$log"; return; }

  "$BIN" --model "$MODEL" --print-timeout "$TIMEOUT" \
         --input-format stream-json --output-format stream-json \
         < "$msg" > "$body" 2>>"$log" || rc=$?

  if [ "$rc" -ne 0 ]; then
    head -c 2000 "$body" >> "$log" 2>/dev/null
    printf '\nVERDICT: REJECT -- gemini %s lens failed to run (agy exit %s)\n' "$name" "$rc" >> "$log"
    return
  fi

  # agy can exit 0 on a turn that errored internally, so the result event's
  # status is the authoritative signal, not $?.
  ARL_BODY="$body" "$PY" -c '
import json, os, sys
result = None
for line in open(os.environ["ARL_BODY"], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        continue          # progress chatter, not an event we consume
    if ev.get("event") == "result":
        result = ev.get("result") or {}
if result is None:
    sys.stderr.write("no result event in agy output\n"); sys.exit(1)
status = result.get("status", "")
if status != "SUCCESS":
    sys.stderr.write("agy reported status %s\n" % (status or "<missing>")); sys.exit(1)
sys.stdout.write(result.get("response") or "")
' >> "$log" 2>>"$log" || {
    printf '\nVERDICT: REJECT -- gemini %s lens did not return a successful result\n' "$name" >> "$log"
    return
  }

  # Fail closed: a lens that emitted no verdict is a failed review, not a pass.
  grep -qE '^[[:space:]]*VERDICT[[:space:]]*:' "$log" 2>/dev/null \
    || printf '\nVERDICT: REJECT -- gemini %s lens emitted no verdict\n' "$name" >> "$log"
}

for _lens in $ARL_LENSES; do
  : > "${OUT}.${_lens}.log"          # only the logs THIS invocation owns
  case "$_lens" in
    correctness) run correctness "$ARL_LENS_CORRECTNESS" & ;;
    data)        run data        "$ARL_LENS_DATA" & ;;
    ui)          run ui          "$ARL_LENS_UI" & ;;
    *) echo "gemini-fanout: unknown lens: $_lens" >&2; exit 2 ;;
  esac
done
wait

echo "FANOUT_DONE"

#!/usr/bin/env bash
# Verifies the Antigravity CLI (agy) fan-out backend honors the shared review
# contract: three lens logs, a VERDICT line in each, fail-closed on every
# failure shape, and the prompt delivered on stdin rather than argv.
#
# The stdin assertion is load-bearing, not stylistic. `agy -p` takes its prompt
# as an argument, and Windows caps a command line at ~32 KB — well under the
# size of a real diff plus the inlined files it touches. A backend that drifts
# back to argv would pass a smoke test and then truncate or fail on the first
# review that matters.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fanout="$here/../gemini-fanout-review.sh"
fails=0

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

stubdir="$(mktemp -d)"
work="$(mktemp -d)"
trap 'rm -rf "$stubdir" "$work"' EXIT

# --- stub agy --------------------------------------------------------------
# Mimics `agy --input-format stream-json --output-format stream-json`: consumes
# NDJSON on stdin and emits an NDJSON `result` event. Records argv and stdin so
# tests can assert how the prompt was delivered.
cat > "$stubdir/agy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARL_STUB_ARGV"
cat >> "$ARL_STUB_STDIN"
status="${ARL_STUB_STATUS:-SUCCESS}"
response="${ARL_STUB_RESPONSE:-reviewed the diff and the inlined files\nVERDICT: APPROVE}"
ARL_R="$response" ARL_S="$status" "${ARL_STUB_PY:-python3}" -c '
import json, os
print(json.dumps({"event": "result", "result": {
    "status": os.environ["ARL_S"],
    "response": os.environ["ARL_R"].replace("\\n", "\n"),
}}))
'
exit "${ARL_STUB_RC:-0}"
STUB
chmod +x "$stubdir/agy"

export PATH="$stubdir:$PATH"

# The harness needs its own working interpreter for the same reason the backend
# does: on Windows `python3` is an App Execution Alias stub that resolves but
# will not launch. A stub that silently fails would make the fail-closed cases
# pass for the wrong reason, which is worse than a red test.
for _py in ${ARL_PYTHON:-} python3 python py; do
  [ -n "$_py" ] || continue
  command -v "$_py" >/dev/null 2>&1 || continue
  "$_py" -c 'pass' >/dev/null 2>&1 || continue
  ARL_STUB_PY="$_py"; break
done
[ -n "${ARL_STUB_PY:-}" ] || { echo "no working Python for the test harness" >&2; exit 2; }
export ARL_STUB_PY

export ARL_STUB_ARGV="$work/argv.txt"
export ARL_STUB_STDIN="$work/stdin.txt"
: > "$ARL_STUB_ARGV"
: > "$ARL_STUB_STDIN"

# --- fixture repo ----------------------------------------------------------
repo="$work/repo"
mkdir -p "$repo"
printf 'let answer = 42\nlet sentinel = "UNIQUE_FILE_MARKER"\n' > "$repo/Calc.swift"
cat > "$work/change.diff" <<'DIFF'
diff --git a/Calc.swift b/Calc.swift
--- a/Calc.swift
+++ b/Calc.swift
@@ -1 +1,2 @@
 let answer = 42
+let sentinel = "UNIQUE_FILE_MARKER"
DIFF

run_fanout() {
  local prefix="$1"; shift
  ( cd "$work" && env "$@" "$fanout" "$work/change.diff" "$prefix" "test context" "$repo" )
}

# --- 1. fail fast when the CLI is absent -----------------------------------
# Points ARL_GEMINI_BIN at a name that is not on PATH rather than emptying PATH
# itself, which would break `env` and the shebang before the script ever ran.
if run_fanout "$work/nobin" ARL_GEMINI_BIN=agy-does-not-exist >"$work/nobin.out" 2>&1; then
  bad "missing agy binary should exit non-zero"
else
  grep -qi 'agy-does-not-exist' "$work/nobin.out" \
    && ok "missing CLI fails fast with a named cause" \
    || bad "missing CLI error does not name the binary"
fi

# --- 2. happy path: three lenses, three verdicts ---------------------------
outp="$work/happy"
run_fanout "$outp" > "$work/happy.out" 2>&1

grep -q 'FANOUT_DONE' "$work/happy.out" \
  && ok "prints FANOUT_DONE" || bad "missing FANOUT_DONE"

for lens in correctness data ui; do
  if [ -f "${outp}.${lens}.log" ]; then
    ok "wrote ${lens} log"
  else
    bad "missing ${lens} log"
    continue
  fi
  grep -qE '^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*APPROVE' "${outp}.${lens}.log" \
    && ok "${lens} lens emitted APPROVE" \
    || bad "${lens} lens has no APPROVE verdict"
done

# --- 3. the prompt travels on stdin, never on argv -------------------------
grep -q 'UNIQUE_FILE_MARKER' "$ARL_STUB_STDIN" \
  && ok "prompt is delivered on stdin" \
  || bad "prompt was not delivered on stdin"
grep -q 'UNIQUE_FILE_MARKER' "$ARL_STUB_ARGV" \
  && bad "prompt leaked onto argv (will blow the Windows command-line limit)" \
  || ok "prompt is absent from argv"
grep -q 'input-format stream-json' "$ARL_STUB_ARGV" \
  && ok "invokes agy in stream-json input mode" \
  || bad "does not use stream-json input mode"

# --- 4. stdin is well-formed NDJSON the CLI can parse ----------------------
if "${ARL_STUB_PY:-python3}" -c '
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert lines, "no stdin captured"
for l in lines:
    m = json.loads(l)
    assert m["event"] == "user", m["event"]
    assert m["message"]["content"].strip(), "empty prompt"
' "$ARL_STUB_STDIN" 2>"$work/ndjson.err"; then
  ok "stdin is valid one-message-per-line NDJSON"
else
  bad "stdin is not valid NDJSON: $(head -c 200 "$work/ndjson.err")"
fi

# --- 5. the configured model is passed through ------------------------------
outp="$work/model"
run_fanout "$outp" ARL_GEMINI_MODEL=gemini-3.1-pro-high > /dev/null 2>&1
grep -q -- '--model gemini-3.1-pro-high' "$ARL_STUB_ARGV" \
  && ok "request carries the configured model" \
  || bad "request does not carry ARL_GEMINI_MODEL"

# --- 6. touched-file contents are inlined ----------------------------------
# The backend runs agy without tool permissions, so it cannot open the repo
# itself; the files under review have to arrive in the prompt.
grep -q 'UNIQUE_FILE_MARKER' "$ARL_STUB_STDIN" \
  && ok "inlines contents of files the diff touches" \
  || bad "did not inline touched-file contents"

# --- 7. fail closed when agy exits non-zero --------------------------------
outp="$work/rcfail"
run_fanout "$outp" ARL_STUB_RC=3 > "$work/rcfail.out" 2>&1
for lens in correctness data ui; do
  grep -qE '^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*REJECT' "${outp}.${lens}.log" \
    && ok "${lens} fails closed when agy exits non-zero" \
    || bad "${lens} did not fail closed on non-zero exit"
done

# --- 8. fail closed when the CLI reports a non-SUCCESS status --------------
# agy can exit 0 on a turn that errored internally; the status field is the
# authoritative signal, so a backend trusting only $? would pass a dead review.
outp="$work/status"
run_fanout "$outp" ARL_STUB_STATUS=ERROR ARL_STUB_RESPONSE='' > "$work/status.out" 2>&1
for lens in correctness data ui; do
  grep -qE '^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*REJECT' "${outp}.${lens}.log" \
    && ok "${lens} fails closed on non-SUCCESS status" \
    || bad "${lens} did not fail closed on non-SUCCESS status"
done

# --- 9. fail closed when the model returns no verdict ----------------------
outp="$work/noverdict"
run_fanout "$outp" ARL_STUB_RESPONSE='I have opinions but no verdict.' \
  > "$work/noverdict.out" 2>&1
for lens in correctness data ui; do
  grep -qE '^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*REJECT' "${outp}.${lens}.log" \
    && ok "${lens} fails closed when no verdict is emitted" \
    || bad "${lens} did not fail closed on a missing verdict"
done

# --- 10. ARL_LENSES selects a subset --------------------------------------
# panel-review.sh drives one lens per backend; a backend that always wrote all
# three would clobber logs another backend owns.
outp="$work/single"
rm -f "${outp}".*.log
run_fanout "$outp" ARL_LENSES=data > /dev/null 2>&1
[ -f "${outp}.data.log" ] \
  && ok "honors ARL_LENSES (writes the selected lens)" \
  || bad "ARL_LENSES=data did not produce a data log"
if [ -f "${outp}.correctness.log" ] || [ -f "${outp}.ui.log" ]; then
  bad "ARL_LENSES=data wrote logs it does not own"
else
  ok "ARL_LENSES=data leaves other lens logs untouched"
fi

# --- 11. a relative diff path must still reach the reviewer ---------------
# The script cds to REPO before reading the diff, so a relative DIFF that
# resolved fine at the -f check silently fails to open afterwards. The reviewer
# then sees an empty diff and can answer APPROVE — a fail-OPEN in a gate whose
# entire job is to catch bad changes. panel-review.sh passes both paths through
# unchanged, so it is reachable from the normal entry point.
: > "$ARL_STUB_STDIN"
cp "$work/change.diff" "$work/relative-only.diff"
outp="$work/relpath"
( cd "$work" && env ARL_LENSES=data "$fanout" "relative-only.diff" "$outp" "ctx" "$repo" ) \
  > "$work/relpath.out" 2>&1
rel_rc=$?
if grep -q 'diff --git a/Calc.swift' "$ARL_STUB_STDIN" 2>/dev/null; then
  ok "relative diff path still reaches the reviewer"
elif [ "$rel_rc" -ne 0 ]; then
  ok "relative diff path rejected loudly instead of reviewing nothing"
else
  bad "relative diff path produced a review with no diff (fail-open)"
fi

# --- 12. an unreadable diff must never yield an empty review ---------------
# Belt and braces for the same failure class: if the diff cannot be read for any
# reason, the run must abort rather than hand the model an empty prompt.
: > "$ARL_STUB_STDIN"
outp="$work/unreadable"
if run_fanout "$outp" ARL_LENSES=data >/dev/null 2>&1 \
   && ! grep -q 'diff --git' "$ARL_STUB_STDIN" 2>/dev/null; then
  bad "sent an empty diff to the reviewer and still exited 0"
else
  ok "never reviews an empty diff silently"
fi

# --- 13. a relative output prefix must land where the caller expects -------
# Same failure class as the diff path, opposite direction: OUT resolved under
# REPO after the cd means panel-review.sh writes and reads different files, so a
# lens that actually APPROVED is scored as "produced no verdict" — a false
# REJECT that costs a whole review round to diagnose.
rm -rf "$work/outrel"; mkdir -p "$work/outrel"
( cd "$work/outrel" && env ARL_LENSES=data "$fanout" "$work/change.diff" "relout" "ctx" "$repo" ) \
  >/dev/null 2>&1
if [ -f "$work/outrel/relout.data.log" ]; then
  ok "relative out prefix resolves against the caller's directory"
else
  bad "relative out prefix wrote logs where the caller cannot read them"
fi

# --- 14. a preflight failure must not leave a previous run's APPROVE behind
# panel-review.sh only checks whether a VERDICT line exists, and swallows the
# backend's stderr. So if this invocation dies in preflight (missing CLI, no
# working Python, unreadable diff) without clearing the logs it owns, the panel
# reads the PREVIOUS run's APPROVE and passes the current diff. The fix-then-
# rerun loop reuses one out-prefix by design, which is exactly when this bites.
outp="$work/stale"
printf 'from an earlier, passing run\nVERDICT: APPROVE\n' > "${outp}.data.log"
run_fanout "$outp" ARL_LENSES=data ARL_GEMINI_BIN=agy-does-not-exist >/dev/null 2>&1
if grep -qE '^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*APPROVE' "${outp}.data.log" 2>/dev/null; then
  bad "preflight failure left a stale APPROVE the panel would accept"
else
  ok "preflight failure clears the stale verdict it would otherwise inherit"
fi

# --- 15. touched paths containing spaces must still be inlined -------------
# The +++ line was parsed with awk's $2, which stops at the first space, so
# "b/My Folder/File.swift" resolved to "b/My" and the file was silently dropped
# from the context. The diff still reached the reviewer, so this degrades the
# review rather than opening the gate — but it degrades it invisibly.
: > "$ARL_STUB_STDIN"
mkdir -p "$repo/Spaced Dir"
# SPACED_FILE_MARKER must appear ONLY in the file on disk, never in the diff --
# the whole diff is cat'd into the context, so a marker present in both proves
# nothing about whether the file itself was inlined.
printf 'let spaced = 1\nlet only_in_the_file = "SPACED_FILE_MARKER"\n' \
  > "$repo/Spaced Dir/My File.swift"
cat > "$work/spaced.diff" <<'DIFF'
diff --git a/Spaced Dir/My File.swift b/Spaced Dir/My File.swift
--- a/Spaced Dir/My File.swift
+++ b/Spaced Dir/My File.swift
@@ -0,0 +1 @@
+let spaced = 1
DIFF
( cd "$work" && env ARL_LENSES=data "$fanout" "$work/spaced.diff" "$work/spaced" "ctx" "$repo" ) \
  >/dev/null 2>&1
grep -q 'SPACED_FILE_MARKER' "$ARL_STUB_STDIN" \
  && ok "inlines touched files whose paths contain spaces" \
  || bad "dropped a touched file because its path contains a space"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'gemini-fanout: ALL PASS\n'; exit 0
else
  printf 'gemini-fanout: %d FAILURE(S)\n' "$fails"; exit 1
fi

#!/usr/bin/env bash
# Verifies the OpenRouter fan-out backend honors the shared review contract:
# three lens logs, a VERDICT line in each, fail-closed on transport/format
# failure, and no credential leakage into logs or argv.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fanout="$here/../openrouter-fanout-review.sh"
fails=0

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

stubdir="$(mktemp -d)"
work="$(mktemp -d)"
trap 'rm -rf "$stubdir" "$work"' EXIT

# --- stub curl -------------------------------------------------------------
# Honors the two flags the script relies on: -o <file> and -w '%{http_code}'.
# Records the request payload so tests can assert on prompt contents.
cat > "$stubdir/curl" <<'STUB'
#!/usr/bin/env bash
out=""; payload=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) payload="${2#@}"; shift 2 ;;
    -K) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$payload" ] && cat "$payload" >> "$ARL_STUB_PAYLOADS"
: > "${ARL_STUB_CALLS:-/dev/null}.hit"
# Built as its own variable: inlining JSON in a ${VAR:-default} makes bash treat
# the first '}' as the end of the expansion and silently emits malformed JSON.
default_body='{"choices":[{"message":{"content":"looks fine\nVERDICT: APPROVE"}}]}'
printf '%s' "${ARL_STUB_BODY:-$default_body}" > "$out"
printf '%s' "${ARL_STUB_HTTP:-200}"
exit "${ARL_STUB_RC:-0}"
STUB
chmod +x "$stubdir/curl"

export PATH="$stubdir:$PATH"
export ARL_STUB_PAYLOADS="$work/payloads.txt"
export ARL_STUB_CALLS="$work/calls.txt"
: > "$ARL_STUB_PAYLOADS"

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

# --- 1. fail fast on missing credentials -----------------------------------
outp="$work/nokey"
if run_fanout "$outp" OPENROUTER_API_KEY= ARL_OPENROUTER_MODEL=some/model >"$work/nokey.out" 2>&1; then
  bad "missing OPENROUTER_API_KEY should exit non-zero"
else
  grep -qi 'OPENROUTER_API_KEY' "$work/nokey.out" \
    && ok "missing key fails fast with a named cause" \
    || bad "missing key error does not name OPENROUTER_API_KEY"
fi

# --- 2. fail fast on missing model -----------------------------------------
if run_fanout "$work/nomodel" OPENROUTER_API_KEY=sk-test ARL_OPENROUTER_MODEL= >"$work/nomodel.out" 2>&1; then
  bad "missing ARL_OPENROUTER_MODEL should exit non-zero"
else
  grep -qi 'ARL_OPENROUTER_MODEL' "$work/nomodel.out" \
    && ok "missing model fails fast with a named cause" \
    || bad "missing model error does not name ARL_OPENROUTER_MODEL"
fi

# --- 3. happy path: three lenses, three verdicts ----------------------------
outp="$work/happy"
run_fanout "$outp" OPENROUTER_API_KEY=sk-secret-do-not-leak ARL_OPENROUTER_MODEL=vendor/model-x \
  > "$work/happy.out" 2>&1

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

# --- 4. the model slug is actually sent ------------------------------------
grep -q 'vendor/model-x' "$ARL_STUB_PAYLOADS" \
  && ok "request carries the configured model slug" \
  || bad "request does not carry ARL_OPENROUTER_MODEL"

# --- 5. touched-file contents are inlined (compensates for no repo access) --
grep -q 'UNIQUE_FILE_MARKER' "$ARL_STUB_PAYLOADS" \
  && ok "inlines contents of files the diff touches" \
  || bad "did not inline touched-file contents"

# --- 6. credential hygiene --------------------------------------------------
if grep -rq 'sk-secret-do-not-leak' "$work"/happy.*.log "$work/happy.out" 2>/dev/null; then
  bad "API key leaked into reviewer logs"
else
  ok "API key never appears in logs"
fi
if grep -q 'sk-secret-do-not-leak' "$ARL_STUB_PAYLOADS" 2>/dev/null; then
  bad "API key leaked into the request body"
else
  ok "API key is not in the request body"
fi

# --- 7. fail closed on transport failure ------------------------------------
outp="$work/httpfail"
run_fanout "$outp" OPENROUTER_API_KEY=sk-test ARL_OPENROUTER_MODEL=vendor/model-x \
  ARL_STUB_HTTP=500 ARL_STUB_BODY='{"error":{"message":"upstream exploded"}}' \
  > "$work/httpfail.out" 2>&1
for lens in correctness data ui; do
  grep -qE '^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*REJECT' "${outp}.${lens}.log" \
    && ok "${lens} fails closed on HTTP 500" \
    || bad "${lens} did not fail closed on HTTP 500"
done

# --- 8. fail closed when the model returns no verdict -----------------------
outp="$work/noverdict"
run_fanout "$outp" OPENROUTER_API_KEY=sk-test ARL_OPENROUTER_MODEL=vendor/model-x \
  ARL_STUB_BODY='{"choices":[{"message":{"content":"I have opinions but no verdict."}}]}' \
  > "$work/noverdict.out" 2>&1
for lens in correctness data ui; do
  grep -qE '^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*REJECT' "${outp}.${lens}.log" \
    && ok "${lens} fails closed when no verdict is emitted" \
    || bad "${lens} did not fail closed on a missing verdict"
done

# --- 9. fail closed when curl itself dies -----------------------------------
outp="$work/curlrc"
run_fanout "$outp" OPENROUTER_API_KEY=sk-test ARL_OPENROUTER_MODEL=vendor/model-x \
  ARL_STUB_RC=7 > "$work/curlrc.out" 2>&1
for lens in correctness data ui; do
  grep -qE '^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*REJECT' "${outp}.${lens}.log" \
    && ok "${lens} fails closed when curl exits non-zero" \
    || bad "${lens} did not fail closed on curl failure"
done

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'openrouter-fanout: ALL PASS\n'; exit 0
else
  printf 'openrouter-fanout: %d FAILURE(S)\n' "$fails"; exit 1
fi

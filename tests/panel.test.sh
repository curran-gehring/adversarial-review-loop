#!/usr/bin/env bash
# Verifies the mixed panel: different lenses run on different reviewer families,
# each writing into the same <out_prefix>.<lens>.log contract the gate reads.
#
# The bake-off (2026-09-08) is why this exists: gpt-5.6-luna and gemini-3.8-flash
# each caught a real shipped bug the other missed. A single-model panel ships one
# of them.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
panel="$here/../panel-review.sh"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

stubdir="$(mktemp -d)"; work="$(mktemp -d)"
trap 'rm -rf "$stubdir" "$work"' EXIT

cat > "$stubdir/codex" <<'STUB'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "$ARL_STUB_CALLS"
cat >/dev/null
printf 'codex reviewed\nVERDICT: APPROVE\n'
STUB
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
printf 'curl %s\n' "$(grep -oE '"model": ?"[^"]*"' "$payload" 2>/dev/null | head -1)" >> "$ARL_STUB_CALLS"
body='{"choices":[{"message":{"content":"openrouter reviewed\nVERDICT: APPROVE"}}]}'
printf '%s' "$body" > "$out"; printf '200'
STUB
chmod +x "$stubdir/codex" "$stubdir/curl"
export PATH="$stubdir:$PATH"
export ARL_STUB_CALLS="$work/calls.txt"; : > "$ARL_STUB_CALLS"
export OPENROUTER_API_KEY=sk-test

repo="$work/repo"; mkdir -p "$repo"; echo 'let x = 1' > "$repo/A.swift"
cat > "$work/d.diff" <<'DIFF'
diff --git a/A.swift b/A.swift
--- a/A.swift
+++ b/A.swift
@@ -0,0 +1 @@
+let x = 1
DIFF

out="$work/panel"
ARL_PANEL="correctness=codex:gpt-5.6-luna,data=openrouter:google/gemini-3.8-flash,ui=openrouter:google/gemini-3.8-flash" \
  bash "$panel" "$work/d.diff" "$out" "ctx" "$repo" > "$work/out.txt" 2>&1
rc=$?

[ "$rc" -eq 0 ] && ok "panel exits 0" || bad "panel exited $rc"
grep -q FANOUT_DONE "$work/out.txt" && ok "prints FANOUT_DONE" || bad "no FANOUT_DONE"

for lens in correctness data ui; do
  if grep -qE '^[[:space:]]*VERDICT[[:space:]]*:' "${out}.${lens}.log" 2>/dev/null; then
    ok "$lens log has a verdict"
  else
    bad "$lens log missing/verdictless"
  fi
done

# routing: exactly one codex call (correctness) and two openrouter calls
c=$(grep -c '^codex ' "$ARL_STUB_CALLS" 2>/dev/null || echo 0)
o=$(grep -c '^curl ' "$ARL_STUB_CALLS" 2>/dev/null || echo 0)
[ "$c" -eq 1 ] && ok "exactly one codex lens" || bad "expected 1 codex call, got $c"
[ "$o" -eq 2 ] && ok "exactly two openrouter lenses" || bad "expected 2 curl calls, got $o"
grep -q 'gpt-5.6-luna' "$ARL_STUB_CALLS" && ok "codex lens used its configured model" || bad "codex model not passed"
grep -q 'gemini-3.8-flash' "$ARL_STUB_CALLS" && ok "openrouter lens used its configured model" || bad "openrouter model not passed"

# a lens missing from the spec must fail closed, not silently pass
out2="$work/partial"
ARL_PANEL="correctness=codex:gpt-5.6-luna" \
  bash "$panel" "$work/d.diff" "$out2" "ctx" "$repo" >/dev/null 2>&1
if grep -qE '^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*REJECT' "${out2}.data.log" 2>/dev/null; then
  ok "lens absent from the panel spec fails closed"
else
  bad "unspecified lens did not fail closed"
fi

# a malformed spec must be rejected up front
if ARL_PANEL="correctness=nosuchbackend:x,data=codex:y,ui=codex:z" \
     bash "$panel" "$work/d.diff" "$work/bad" "ctx" "$repo" >/dev/null 2>&1; then
  bad "unknown backend should exit non-zero"
else
  ok "unknown backend rejected up front"
fi

# a stale APPROVE from a previous run must never be inherited by this one.
# The panel checks only for the presence of a VERDICT line and suppresses each
# backend's output, so a backend dying in preflight would otherwise hand the
# prior run's approval to the current diff. The fix-then-rerun loop reuses one
# out-prefix, which is exactly when this happens.
out3="$work/stale"
printf 'from an earlier, passing run\nVERDICT: APPROVE\n' > "${out3}.data.log"
ARL_PANEL="correctness=codex:gpt-5.6-luna,data=openrouter:google/gemini-3.8-flash,ui=openrouter:google/gemini-3.8-flash" \
  bash "$panel" "$work/d.diff" "$out3" "ctx" "$repo" >/dev/null 2>&1
if grep -q 'from an earlier, passing run' "${out3}.data.log" 2>/dev/null; then
  bad "panel inherited a stale log from a previous run"
else
  ok "panel clears stale lens logs before dispatching"
fi

printf '\n'
[ "$fails" -eq 0 ] && { echo "panel: ALL PASS"; exit 0; } || { echo "panel: $fails FAILURE(S)"; exit 1; }

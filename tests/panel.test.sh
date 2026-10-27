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
case "${ARL_STUB_CODEX:-}" in
  limit)  echo "ERROR: You've hit your usage limit." >&2; exit 1 ;;
  reject) printf 'real bug\nVERDICT: REJECT -- bug in A.swift\n' ;;
  *)      printf 'codex reviewed\nVERDICT: APPROVE\n' ;;
esac
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

# ...and a spec that fails validation must clear them too, since validation
# exits before any backend is launched.
out4="$work/stalebad"
printf 'earlier run\nVERDICT: APPROVE\n' > "${out4}.data.log"
ARL_PANEL="correctness=nosuchbackend:x,data=codex:y,ui=codex:z" \
  bash "$panel" "$work/d.diff" "$out4" "ctx" "$repo" >/dev/null 2>&1
if grep -q 'earlier run' "${out4}.data.log" 2>/dev/null; then
  bad "invalid panel spec left a stale APPROVE behind"
else
  ok "invalid panel spec still clears stale lens logs"
fi

# ...and so must a missing diff, the earliest exit of all.
out5="$work/stalenodiff"
printf 'earlier run\nVERDICT: APPROVE\n' > "${out5}.data.log"
bash "$panel" "$work/does-not-exist.diff" "$out5" "ctx" "$repo" >/dev/null 2>&1
if grep -q 'earlier run' "${out5}.data.log" 2>/dev/null; then
  bad "a missing diff left a stale APPROVE behind"
else
  ok "a missing diff still clears stale lens logs"
fi

# --- a Gemini (agy) lens that fails to run falls back to OpenRouter -----------
# The Gemini lenses run on the subscription first; OpenRouter is only the
# fallback. An infrastructure failure reruns that lens there. A real REJECT
# from Gemini is a review, and stands.
cat > "$stubdir/agy" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'agy %s\n' "$ARL_STUB_AGY" >> "$ARL_STUB_CALLS"
case "$ARL_STUB_AGY" in
  fail)   echo 'boom' >&2; exit 1 ;;
  reject) printf '{"event":"result","result":{"status":"SUCCESS","response":"real bug\\nVERDICT: REJECT -- bug in A.swift"}}\n' ;;
  *)      printf '{"event":"result","result":{"status":"SUCCESS","response":"gemini reviewed\\nVERDICT: APPROVE"}}\n' ;;
esac
STUB
chmod +x "$stubdir/agy"
gemini_panel="correctness=codex:gpt-5.6-luna,data=gemini:gemini-3.8-flash-high,ui=gemini:gemini-3.8-flash-high"

: > "$ARL_STUB_CALLS"; out6="$work/fallback"
ARL_STUB_AGY=fail ARL_PANEL="$gemini_panel" bash "$panel" "$work/d.diff" "$out6" "ctx" "$repo" >/dev/null 2>&1
for lens in data ui; do
  if grep -q 'openrouter reviewed' "${out6}.${lens}.log" 2>/dev/null && grep -qE '^VERDICT: APPROVE' "${out6}.${lens}.log"; then
    ok "failed agy $lens lens is rerun on OpenRouter"
  else
    bad "failed agy $lens lens was not rerun on OpenRouter"
  fi
  grep -q 'failed to run' "${out6}.${lens}.gemini.log" 2>/dev/null \
    && ok "agy failure for $lens is kept in .gemini.log" || bad "agy failure for $lens was discarded"
done
grep -q 'gemini-3.8-flash' "$ARL_STUB_CALLS" && ok "fallback uses the OpenRouter Gemini model" || bad "fallback did not call OpenRouter Gemini"

: > "$ARL_STUB_CALLS"; out7="$work/realreject"
ARL_STUB_AGY=reject ARL_PANEL="$gemini_panel" bash "$panel" "$work/d.diff" "$out7" "ctx" "$repo" >/dev/null 2>&1
grep -qE '^VERDICT: REJECT -- bug in A.swift' "${out7}.data.log" 2>/dev/null \
  && ok "a real Gemini REJECT stands" || bad "a real Gemini REJECT was replaced"
grep -q '^curl ' "$ARL_STUB_CALLS" && bad "a real Gemini REJECT triggered an OpenRouter rerun" || ok "a real Gemini REJECT is not rerun"

: > "$ARL_STUB_CALLS"; out8="$work/nokey"
env -u OPENROUTER_API_KEY -u ARL_PROXY_TOKEN ARL_STUB_AGY=fail ARL_PANEL="$gemini_panel" bash "$panel" "$work/d.diff" "$out8" "ctx" "$repo" >/dev/null 2>&1
grep -qE '^VERDICT: REJECT -- gemini data lens failed to run' "${out8}.data.log" 2>/dev/null \
  && ok "without an OpenRouter key the agy failure fails closed" || bad "no-key agy failure did not fail closed"

# The proxy's app token alone is enough for the fallback (no real key on this host).
: > "$ARL_STUB_CALLS"; out8b="$work/proxytoken"
env -u OPENROUTER_API_KEY ARL_PROXY_TOKEN=tok-proxy ARL_OPENROUTER_BASE_URL=https://arl-openrouter-proxy.example.workers.dev/api/v1 \
  ARL_STUB_AGY=fail ARL_PANEL="$gemini_panel" bash "$panel" "$work/d.diff" "$out8b" "ctx" "$repo" >/dev/null 2>&1
grep -qE '^VERDICT: APPROVE' "${out8b}.data.log" 2>/dev/null \
  && ok "ARL_PROXY_TOKEN alone lets a failed agy lens fall back" || bad "ARL_PROXY_TOKEN alone did not enable the fallback"

# --- a Codex correctness lens that fails to run falls back to OpenRouter ------
# Same idea as the Gemini fallback: a usage limit or crash leaves no verdict, so
# the lens reruns on the same model over OpenRouter. A real Codex REJECT stands.
codex_panel="correctness=codex:gpt-5.6-luna,data=openrouter:google/gemini-3.8-flash,ui=openrouter:google/gemini-3.8-flash"

: > "$ARL_STUB_CALLS"; out9="$work/codexlimit"
ARL_STUB_CODEX=limit ARL_PANEL="$codex_panel" bash "$panel" "$work/d.diff" "$out9" "ctx" "$repo" >/dev/null 2>&1
if grep -q 'openrouter reviewed' "${out9}.correctness.log" 2>/dev/null && grep -qE '^VERDICT: APPROVE' "${out9}.correctness.log"; then
  ok "failed codex correctness lens is rerun on OpenRouter"
else
  bad "failed codex correctness lens was not rerun on OpenRouter"
fi
grep -q 'usage limit' "${out9}.correctness.codex.log" 2>/dev/null \
  && ok "codex failure is kept in .codex.log" || bad "codex failure was discarded"
grep -q 'openai/gpt-5.6-luna' "$ARL_STUB_CALLS" && ok "fallback uses the same model over OpenRouter" || bad "fallback did not call openai/gpt-5.6-luna"

: > "$ARL_STUB_CALLS"; out10="$work/codexreject"
ARL_STUB_CODEX=reject ARL_PANEL="$codex_panel" bash "$panel" "$work/d.diff" "$out10" "ctx" "$repo" >/dev/null 2>&1
grep -qE '^VERDICT: REJECT -- bug in A.swift' "${out10}.correctness.log" 2>/dev/null \
  && ok "a real Codex REJECT stands" || bad "a real Codex REJECT was replaced"
grep -q 'openai/gpt-5.6-luna' "$ARL_STUB_CALLS" && bad "a real Codex REJECT triggered an OpenRouter rerun" || ok "a real Codex REJECT is not rerun"

out11="$work/codexnokey"
env -u OPENROUTER_API_KEY -u ARL_PROXY_TOKEN ARL_STUB_CODEX=limit ARL_PANEL="correctness=codex:gpt-5.6-luna" bash "$panel" "$work/d.diff" "$out11" "ctx" "$repo" >/dev/null 2>&1
grep -qE '^VERDICT: REJECT' "${out11}.correctness.log" 2>/dev/null && ! grep -qE '^VERDICT: APPROVE' "${out11}.correctness.log" \
  && ok "without an OpenRouter key the codex failure fails closed" || bad "no-key codex failure did not fail closed"

out12="$work/codexstale"
printf 'old\n' > "${out12}.correctness.codex.log"
ARL_PANEL="$codex_panel" bash "$panel" "$work/d.diff" "$out12" "ctx" "$repo" >/dev/null 2>&1
[ -e "${out12}.correctness.codex.log" ] && bad "a stale .codex.log survived a clean run" || ok "a stale .codex.log is cleared"

printf '\n'
[ "$fails" -eq 0 ] && { echo "panel: ALL PASS"; exit 0; } || { echo "panel: $fails FAILURE(S)"; exit 1; }

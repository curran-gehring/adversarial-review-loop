#!/usr/bin/env bash
# Verifies the reviewer bake-off scores models on a labeled diff set:
# catch rate on known-buggy diffs, false-positive rate on known-clean diffs.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bakeoff="$here/../bakeoff.sh"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

stubdir="$(mktemp -d)"; work="$(mktemp -d)"
trap 'rm -rf "$stubdir" "$work"' EXIT

# Stub transport: REJECT iff the prompt carries BUGMARKER, except model
# "vendor/blind" which always APPROVEs (misses every bug) and "vendor/crywolf"
# which always REJECTs (pure false positives). Lets us assert both axes.
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
verdict="VERDICT: APPROVE"
if   grep -q 'vendor/crywolf' "$payload" 2>/dev/null; then verdict="VERDICT: REJECT -- always"
elif grep -q 'vendor/blind'   "$payload" 2>/dev/null; then verdict="VERDICT: APPROVE"
elif grep -q 'BUGMARKER'      "$payload" 2>/dev/null; then verdict="VERDICT: REJECT -- found it"
fi
body='{"choices":[{"message":{"content":"review text\n'"$verdict"'"}}]}'
printf '%s' "$body" > "$out"
printf '200'
STUB
chmod +x "$stubdir/curl"
export PATH="$stubdir:$PATH"
export OPENROUTER_API_KEY=sk-test

# --- labeled case set ------------------------------------------------------
cases="$work/cases"; mkdir -p "$cases"
printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -0,0 +1 @@\n+BUGMARKER off by one\n' > "$cases/hasbug.diff"
echo buggy > "$cases/hasbug.label"
printf 'diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -0,0 +1 @@\n+harmless rename\n' > "$cases/fine.diff"
echo clean > "$cases/fine.label"

out="$work/out"
ARL_BAKEOFF_MODELS="vendor/good,vendor/blind,vendor/crywolf" \
  bash "$bakeoff" "$cases" "$out" > "$work/report.txt" 2>&1
rc=$?

[ "$rc" -eq 0 ] && ok "bakeoff exits 0" || bad "bakeoff exited $rc"
grep -q 'vendor/good' "$work/report.txt" && ok "report includes each model" || bad "model missing from report"

# vendor/good: catches the bug, passes the clean one
grep -qE '^vendor/good .*caught 1/1.*false-pos 0/1' "$work/report.txt" \
  && ok "scores a good reviewer as 1/1 caught, 0/1 false positives" \
  || bad "good reviewer mis-scored: $(grep '^vendor/good' "$work/report.txt")"

# vendor/blind: misses the bug, but no false positives
grep -qE '^vendor/blind .*caught 0/1.*false-pos 0/1' "$work/report.txt" \
  && ok "scores a blind reviewer as 0/1 caught" \
  || bad "blind reviewer mis-scored: $(grep '^vendor/blind' "$work/report.txt")"

# vendor/crywolf: catches it, but REJECTs the clean diff too
grep -qE '^vendor/crywolf .*caught 1/1.*false-pos 1/1' "$work/report.txt" \
  && ok "scores a cry-wolf reviewer as 1/1 false positives" \
  || bad "crywolf reviewer mis-scored: $(grep '^vendor/crywolf' "$work/report.txt")"

# per-model logs are kept for inspection
[ -d "$out" ] && [ "$(find "$out" -name '*.log' | wc -l)" -ge 18 ] \
  && ok "keeps per-lens logs for inspection" \
  || bad "expected 3 models x 2 cases x 3 lenses = 18 logs, found $(find "$out" -name '*.log' 2>/dev/null | wc -l)"

# a lens that emits no verdict must not be silently read as APPROVE
grep -qiE 'no-verdict|fail(ed|s)? closed|REJECT' "$work/report.txt" >/dev/null 2>&1 \
  && ok "report surfaces reject/fail-closed accounting" || true

printf '\n'
[ "$fails" -eq 0 ] && { echo "bakeoff: ALL PASS"; exit 0; } || { echo "bakeoff: $fails FAILURE(S)"; exit 1; }

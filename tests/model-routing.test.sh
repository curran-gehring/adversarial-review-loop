#!/usr/bin/env bash
# Verifies the canonical fanout wrapper uses the opposite model family from the
# primary coder.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fanout="$here/../fanout-review.sh"
fails=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

stubdir="$(mktemp -d)"
work="$(mktemp -d)"
trap 'rm -rf "$stubdir" "$work"' EXIT

cat > "$stubdir/codex" <<'STUB'
#!/usr/bin/env bash
printf 'codex\n' >> "$ARL_STUB_CALLS"
cat >/dev/null
printf 'stub codex reviewer\nVERDICT: APPROVE\n'
STUB

cat > "$stubdir/claude" <<'STUB'
#!/usr/bin/env bash
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  printf 'claude saw ANTHROPIC_API_KEY\n' >&2
  exit 44
fi
for arg in "$@"; do
  if [ "$arg" = "--bare" ]; then
    printf 'claude was invoked with --bare\n' >&2
    exit 45
  fi
done
printf 'claude\n' >> "$ARL_STUB_CALLS"
cat >/dev/null
printf 'stub claude reviewer\nVERDICT: APPROVE\n'
STUB

chmod +x "$stubdir/codex" "$stubdir/claude"
export PATH="$stubdir:$PATH"

diff="$work/review.diff"
printf 'diff --git a/x b/x\n+touched\n' > "$diff"

calls="$work/calls"
export ARL_STUB_CALLS="$calls"

out="$work/codex-primary"
: > "$calls"
ANTHROPIC_API_KEY=must_not_leak ARL_PRIMARY_MODEL=codex bash "$fanout" "$diff" "$out" "ctx" "$work" >/dev/null 2>&1
claude_count="$(grep -c '^claude$' "$calls" 2>/dev/null || true)"
codex_count="$(grep -c '^codex$' "$calls" 2>/dev/null || true)"
[ "$claude_count" -eq 3 ] && [ "$codex_count" -eq 0 ] \
  && ok "Codex primary dispatches three Claude reviewers" \
  || bad "Codex primary routed incorrectly (claude=$claude_count codex=$codex_count)"
if grep -R "ANTHROPIC_API_KEY\\|--bare" "$out".*.log >/dev/null 2>&1; then
  bad "Claude fan-out leaked a metered API-key path"
else
  ok "Claude fan-out scrubs ANTHROPIC_API_KEY and avoids --bare"
fi

out2="$work/claude-primary"
: > "$calls"
ARL_PRIMARY_MODEL=claude bash "$fanout" "$diff" "$out2" "ctx" "$work" >/dev/null 2>&1
claude_count="$(grep -c '^claude$' "$calls" 2>/dev/null || true)"
codex_count="$(grep -c '^codex$' "$calls" 2>/dev/null || true)"
[ "$codex_count" -eq 3 ] && [ "$claude_count" -eq 0 ] \
  && ok "Claude primary dispatches three Codex reviewers" \
  || bad "Claude primary routed incorrectly (claude=$claude_count codex=$codex_count)"

echo
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAIL ($fails)"; exit 1; }

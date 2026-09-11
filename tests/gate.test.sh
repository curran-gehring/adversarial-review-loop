#!/usr/bin/env bash
# Pins gate.sh's routing: which runner each ARL_GATE mode reaches, and with what
# panel. This logic used to live only in an untracked ~/fanout-review.sh on the
# mac-mini, so Windows had no gate at all and the two hosts could not drift
# toward each other even in principle.
#
# gate.sh resolves its runners relative to its own location, so the whole thing
# is exercised by copying it next to stub runners.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
gate_src="$here/../gate.sh"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[ -f "$gate_src" ] || { echo "  FAIL gate.sh does not exist"; echo; echo "gate: 1 FAILURE(S)"; exit 1; }

sandbox="$work/bin"
mkdir -p "$sandbox"
cp "$gate_src" "$sandbox/gate.sh"
chmod +x "$sandbox/gate.sh"

# Stub runners record which one ran, with what panel and what arguments.
for runner in panel-review.sh fanout-review.sh; do
  cat > "$sandbox/$runner" <<STUB
#!/usr/bin/env bash
printf '%s|panel=%s|args=%s\n' "$runner" "\${ARL_PANEL:-<unset>}" "\$*" >> "\$ARL_TEST_CALLS"
STUB
  chmod +x "$sandbox/$runner"
done

export ARL_TEST_CALLS="$work/calls.txt"
: > "$ARL_TEST_CALLS"
printf 'diff --git a/x b/x\n' > "$work/d.diff"

run_gate() { : > "$ARL_TEST_CALLS"; env "$@" "$sandbox/gate.sh" "$work/d.diff" "$work/out" "ctx"; }

# --- default: mixed panel, Gemini lenses on the subscription ---------------
run_gate ARL_DEFAULT_REPO="$work" >/dev/null 2>&1
calls="$(cat "$ARL_TEST_CALLS")"
case "$calls" in
  panel-review.sh*) ok "default routes to the panel runner" ;;
  *) bad "default did not route to panel-review.sh (got: $calls)" ;;
esac
case "$calls" in
  *correctness=codex:*) ok "default keeps correctness on codex" ;;
  *) bad "default lost the codex correctness lens" ;;
esac
case "$calls" in
  *data=gemini:*ui=gemini:*) ok "default runs both Gemini lenses on the subscription" ;;
  *) bad "default did not put the Gemini lenses on the gemini backend" ;;
esac

# --- nocodex: the fallback, no ChatGPT subscription required ---------------
# This is what to use while the Codex subscription is out of usage, so it must
# keep two model families rather than collapsing onto one.
run_gate ARL_GATE=nocodex ARL_DEFAULT_REPO="$work" >/dev/null 2>&1
calls="$(cat "$ARL_TEST_CALLS")"
case "$calls" in
  *codex:*) bad "nocodex still routed a lens to codex" ;;
  *) ok "nocodex uses no codex lens" ;;
esac
case "$calls" in
  *correctness=openrouter:openai/gpt-5.6-luna*) ok "nocodex keeps correctness on luna over OpenRouter" ;;
  *) bad "nocodex did not put correctness on luna" ;;
esac
case "$calls" in
  *data=openrouter:*ui=openrouter:*) ok "nocodex runs the remaining lenses over OpenRouter" ;;
  *) bad "nocodex did not route data/ui to OpenRouter" ;;
esac

# --- single: one model, all three lenses -----------------------------------
run_gate ARL_GATE=single ARL_DEFAULT_REPO="$work" >/dev/null 2>&1
case "$(cat "$ARL_TEST_CALLS")" in
  fanout-review.sh*) ok "single routes to the codex fan-out runner" ;;
  *) bad "single did not route to fanout-review.sh" ;;
esac

# --- an explicit ARL_PANEL wins over the mode defaults ---------------------
run_gate ARL_PANEL="correctness=claude:x,data=claude:y,ui=claude:z" ARL_DEFAULT_REPO="$work" >/dev/null 2>&1
case "$(cat "$ARL_TEST_CALLS")" in
  *correctness=claude:x*) ok "an explicit ARL_PANEL is respected" ;;
  *) bad "an explicit ARL_PANEL was overridden" ;;
esac

# --- repo_dir defaulting ---------------------------------------------------
# The host default is the ONLY thing that differs between machines; everything
# above it is shared, which is the point of moving this into the repo.
run_gate ARL_DEFAULT_REPO="/host/default/repo" >/dev/null 2>&1
case "$(cat "$ARL_TEST_CALLS")" in
  *"/host/default/repo"*) ok "falls back to ARL_DEFAULT_REPO when no repo_dir is given" ;;
  *) bad "ignored ARL_DEFAULT_REPO" ;;
esac

run_gate ARL_DEFAULT_REPO="/host/default/repo" >/dev/null 2>&1 # 4th arg absent above
: > "$ARL_TEST_CALLS"
env ARL_DEFAULT_REPO="/host/default/repo" "$sandbox/gate.sh" \
  "$work/d.diff" "$work/out" "ctx" "/explicit/repo" >/dev/null 2>&1
case "$(cat "$ARL_TEST_CALLS")" in
  *"/explicit/repo"*) ok "an explicit repo_dir overrides the host default" ;;
  *) bad "explicit repo_dir was ignored" ;;
esac

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'gate: ALL PASS\n'; exit 0
else
  printf 'gate: %d FAILURE(S)\n' "$fails"; exit 1
fi

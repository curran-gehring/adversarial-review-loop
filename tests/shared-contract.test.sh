#!/usr/bin/env bash
# Pins the safety preamble every backend shares: absolute path resolution and
# interpreter selection.
#
# These live in lenses.sh for the same reason the lens prompts do — three
# drifting copies of a safety gate's argument handling is how the gate quietly
# stops protecting one of its backends. Two of the eight review rounds that
# landed the gemini backend were this exact bug, and the fix only reached that
# one file; openrouter, claude and codex were left exposed.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

work="$(mktemp -d)"
stubdir="$(mktemp -d)"
trap 'rm -rf "$work" "$stubdir"' EXIT

# shellcheck source=../lenses.sh
. "$here/../lenses.sh"

# --- arl_abs ---------------------------------------------------------------
for fn in arl_abs arl_pick_python; do
  command -v "$fn" >/dev/null 2>&1 \
    && ok "lenses.sh exposes $fn" \
    || bad "lenses.sh does not expose $fn"
done

if command -v arl_abs >/dev/null 2>&1; then
  ( cd "$work" && [ "$(arl_abs rel.diff)" = "$work/rel.diff" ] ) \
    && ok "arl_abs resolves a relative path against \$PWD" \
    || bad "arl_abs did not resolve a relative path"

  [ "$(arl_abs /already/absolute)" = "/already/absolute" ] \
    && ok "arl_abs leaves an absolute path alone" \
    || bad "arl_abs mangled an absolute path"

  # Git Bash hands through Windows-style absolute paths; treating C:/x as
  # relative would silently produce "$PWD/C:/x" and lose the file.
  [ "$(arl_abs 'C:/Dev/x.diff')" = 'C:/Dev/x.diff' ] \
    && ok "arl_abs leaves a Windows-style absolute path alone" \
    || bad "arl_abs mangled a Windows-style absolute path"
fi

# --- arl_pick_python -------------------------------------------------------
# Must pick an interpreter that RUNS, not merely one that resolves. On Windows
# `python3` is an App Execution Alias that satisfies `command -v` and then dies
# at launch with 0x80070003 — which turned a broken environment into three
# REJECTs that read like review findings.
# Resolve a genuinely working interpreter BEFORE shadowing anything, otherwise
# the stub `python` below re-enters the broken `python3` we are about to plant.
real_py=""
for c in python3 python py; do
  command -v "$c" >/dev/null 2>&1 || continue
  "$c" -c 'pass' >/dev/null 2>&1 || continue
  real_py="$(command -v "$c")"; break
done
[ -n "$real_py" ] || { echo "no working interpreter to build the fixture with" >&2; exit 2; }

cat > "$stubdir/python3" <<'STUB'
#!/usr/bin/env bash
echo "[ERROR] Failed to launch (0x80070003)" >&2
exit 9009
STUB
cat > "$stubdir/python" <<STUB
#!/usr/bin/env bash
exec "$real_py" "\$@"
STUB
chmod +x "$stubdir/python3" "$stubdir/python"

if command -v arl_pick_python >/dev/null 2>&1; then
  picked="$(PATH="$stubdir:$PATH" arl_pick_python)"
  if [ "$picked" = "python3" ]; then
    bad "arl_pick_python chose a resolvable-but-broken python3"
  elif [ -n "$picked" ]; then
    ok "arl_pick_python skips a broken python3 for one that runs"
  else
    bad "arl_pick_python found no interpreter at all"
  fi

  PATH="/nonexistent-dir-only" arl_pick_python >/dev/null 2>&1 \
    && bad "arl_pick_python succeeded with no interpreter present" \
    || ok "arl_pick_python fails when nothing runs"
fi

# --- arl_clear_logs --------------------------------------------------------
# Callers ask only whether a VERDICT line exists and suppress the backend's
# stderr, so a stale APPROVE that survives clearing is read as this run's
# verdict. Swallowing the failure with `|| true` is what fails the gate open.
command -v arl_clear_logs >/dev/null 2>&1 \
  && ok "lenses.sh exposes arl_clear_logs" \
  || bad "lenses.sh does not expose arl_clear_logs"

if command -v arl_clear_logs >/dev/null 2>&1; then
  pfx="$work/clear"
  printf 'earlier run\nVERDICT: APPROVE\n' > "${pfx}.data.log"
  printf 'earlier run\nVERDICT: APPROVE\n' > "${pfx}.ui.log"
  if arl_clear_logs "$pfx" data ui 2>/dev/null; then
    if grep -q VERDICT "${pfx}.data.log" "${pfx}.ui.log" 2>/dev/null; then
      bad "arl_clear_logs returned success with a verdict still present"
    else
      ok "arl_clear_logs clears the verdicts it owns"
    fi
  else
    bad "arl_clear_logs failed on ordinary writable logs"
  fi

  # It must not touch a lens it was not asked to clear.
  printf 'VERDICT: APPROVE\n' > "${pfx}.correctness.log"
  arl_clear_logs "$pfx" data >/dev/null 2>&1
  grep -q VERDICT "${pfx}.correctness.log" 2>/dev/null \
    && ok "arl_clear_logs leaves lenses it does not own alone" \
    || bad "arl_clear_logs cleared a lens it was not given"

  # And it must REFUSE when a stale verdict cannot be removed. Only meaningful
  # where the filesystem actually enforces directory write permission, so the
  # precondition is verified rather than assumed.
  # Both locks are needed: truncation is denied by the FILE's mode, removal by
  # the DIRECTORY's. Locking only the directory leaves `: >` working, which is
  # why this assertion silently skipped on macOS the first time around.
  rodir="$work/ro"; mkdir -p "$rodir"
  printf 'VERDICT: APPROVE\n' > "$rodir/x.data.log"
  chmod 444 "$rodir/x.data.log" 2>/dev/null
  chmod 555 "$rodir" 2>/dev/null
  # Subshell: a redirection failure is reported by the shell itself, so the
  # 2>/dev/null has to wrap the whole thing or the probe prints a scary-looking
  # "Permission denied" that reads like a test failure.
  if ( : > "$rodir/x.data.log" ) 2>/dev/null || rm -f "$rodir/x.data.log" 2>/dev/null; then
    chmod 755 "$rodir" 2>/dev/null
    ok "(skipped: this filesystem does not enforce write permission)"
  else
    if arl_clear_logs "$rodir/x" data 2>/dev/null; then
      bad "arl_clear_logs returned success while a stale APPROVE survived"
    else
      ok "arl_clear_logs refuses when a stale verdict cannot be cleared"
    fi
    chmod 755 "$rodir" 2>/dev/null
  fi
fi

# --- every backend must behave the same on a preflight failure -------------
# This is the parity assertion. Each fix in this area historically landed in one
# backend and was assumed to cover the rest; it never did. Asserting the whole
# set at once is the only version of this test that stays true.
#
# A nonexistent diff is the common preflight failure: every backend checks it,
# and every backend must already have cleared its logs by then.
backends="openrouter-fanout-review.sh claude-fanout-review.sh fanout-review.sh gemini-fanout-review.sh"
for b in $backends; do
  script="$here/../$b"
  [ -f "$script" ] || { bad "$b is missing"; continue; }
  pfx="$work/pre_$(printf '%s' "$b" | tr -c 'a-zA-Z0-9' '_')"
  printf 'from an earlier, passing run\nVERDICT: APPROVE\n' > "${pfx}.data.log"
  (
    cd "$work" || exit 1
    env ARL_LENSES=data \
        OPENROUTER_API_KEY=sk-test ARL_OPENROUTER_MODEL=vendor/model \
        ARL_FORCE_CODEX_FANOUT=1 \
        ARL_GEMINI_BIN=agy-does-not-exist \
        "$script" "$work/definitely-missing.diff" "$pfx" "" "$work"
  ) >/dev/null 2>&1
  if grep -q 'from an earlier, passing run' "${pfx}.data.log" 2>/dev/null; then
    bad "$b left a stale APPROVE after a preflight failure"
  else
    ok "$b clears stale verdicts before preflight"
  fi
done

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'shared-contract: ALL PASS\n'; exit 0
else
  printf 'shared-contract: %d FAILURE(S)\n' "$fails"; exit 1
fi

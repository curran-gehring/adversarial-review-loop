#!/usr/bin/env bash
# Pins review-gate.sh's remote mode (ARL_REVIEW_HOST). ssh and scp are stubs
# that treat "the host" as this machine, so the whole round trip runs offline.
#
# Observed 2026-10-12: remote mode copied only the fan-out script to the host.
# Every real fan-out sources lenses.sh from its own directory, so on the host it
# died at once, its output went to /dev/null, and the gate printed "<no verdict
# emitted>" for all three lenses with no hint why. A fan-out must arrive with
# the scripts beside it, and a remote failure must say what failed.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/../review-gate.sh"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- stub ssh and scp: the "host" is this machine --------------------------
stubs="$work/stubs"
mkdir -p "$stubs"
cat > "$stubs/ssh" <<'STUB'
#!/usr/bin/env bash
shift                       # the host
exec bash -c "$*"
STUB
cat > "$stubs/scp" <<'STUB'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  case "$a" in
    -q) ;;
    *:*) args+=("${a#*:}") ;;   # host:path -> path
    *) args+=("$a") ;;
  esac
done
exec cp "${args[@]}"
STUB
chmod +x "$stubs/ssh" "$stubs/scp"
export PATH="$stubs:$PATH"
export TMPDIR="$work/remote-tmp"
mkdir -p "$TMPDIR"

# --- a fan-out that needs a sibling script, like every real one -------------
tools="$work/tools"
mkdir -p "$tools"
cat > "$tools/helper.sh" <<'SH'
write_verdict() { printf 'checked the diff\nVERDICT: %s\n' "$2" > "$1"; }
SH
cat > "$tools/fan.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/helper.sh" || exit 3
for lens in correctness data ui; do write_verdict "$2.$lens.log" APPROVE; done
SH
cat > "$tools/broken.sh" <<'SH'
#!/usr/bin/env bash
echo "REMOTE_FAILURE_MARKER: reviewer CLI not found" >&2
exit 4
SH

# --- a repo with one commit on a branch off main ----------------------------
repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$repo" checkout -q -b change
printf 'x = 1\n' > "$repo/a.py"
git -C "$repo" add a.py
git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m change
sha="$(git -C "$repo" rev-parse HEAD)"
receipt="$(git -C "$repo" rev-parse --absolute-git-dir)/adversarial-review/$sha"

# --- 1. a fan-out with a sibling script reviews remotely --------------------
( cd "$repo" && ARL_REVIEW_HOST=fakehost ARL_FANOUT="$tools/fan.sh" "$gate" main ) > "$work/ok.out" 2>&1
grep -q '^VERDICT: APPROVE' "$work/ok.out" \
  && ok "remote review sees the fan-out's sibling scripts and approves" \
  || bad "remote review failed: $(tail -c 400 "$work/ok.out")"
[ -f "$receipt" ] && ok "receipt recorded for the reviewed commit" || bad "no receipt for $sha"

# --- 2. a remote failure says what failed ------------------------------------
rm -f "$receipt"
( cd "$repo" && ARL_REVIEW_HOST=fakehost ARL_FANOUT="$tools/broken.sh" "$gate" main ) > "$work/bad.out" 2>&1
grep -q 'VERDICT: REJECT' "$work/bad.out" \
  && ok "a failed remote fan-out rejects" || bad "a failed remote fan-out did not reject"
grep -q 'REMOTE_FAILURE_MARKER' "$work/bad.out" \
  && ok "the remote fan-out's error is shown" \
  || bad "the remote fan-out's error was swallowed"
[ ! -f "$receipt" ] && ok "no receipt after a failed review" || bad "a failed review wrote a receipt"

# --- 3. the remote workspace is cleaned up ------------------------------------
left="$(find "$TMPDIR" -maxdepth 1 -name 'arl.*' | wc -l | tr -d ' ')"
[ "$left" = 0 ] && ok "remote workspaces are removed" || bad "$left remote workspace(s) left behind"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'review-gate: ALL PASS\n'; exit 0
else
  printf 'review-gate: %d FAILURE(S)\n' "$fails"; exit 1
fi

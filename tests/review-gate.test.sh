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

# --- 4. review rules come from the base commit --------------------------------
# The gate reviews a working tree at HEAD, so the repo's own REVIEW-RULES.md is
# the one the diff may have rewritten. A change must be judged by the rules it
# was written against, locally and on a remote host alike.
cp "$here/../lenses.sh" "$tools/lenses.sh"
cat > "$tools/rules-fan.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/lenses.sh" || exit 3
arl_with_repo_rules "$3" "$1" "$4" > "$ARL_TEST_CTX" || exit 3
for lens in correctness data ui; do printf 'checked\nVERDICT: APPROVE\n' > "$2.$lens.log"; done
SH
chmod +x "$tools/rules-fan.sh"

rrepo="$work/rules-repo"
git init -q -b main "$rrepo"
printf '## Base rule\npaths: *\n- BASE_RULE_MARKER\n' > "$rrepo/REVIEW-RULES.md"
git -C "$rrepo" add REVIEW-RULES.md
git -C "$rrepo" -c user.email=t@t -c user.name=t commit -q -m base
git -C "$rrepo" checkout -q -b change
printf '## Weakened rule\npaths: *\n- HEAD_RULE_MARKER\n' > "$rrepo/REVIEW-RULES.md"
printf 'x = 1\n' > "$rrepo/a.py"
git -C "$rrepo" add REVIEW-RULES.md a.py
git -C "$rrepo" -c user.email=t@t -c user.name=t commit -q -m change

# An ARL_RULES_FILE already set in the environment (on this machine, or on the
# review host, which the stub ssh shares) must not replace the base's rules.
printf '## Stale rule\npaths: *\n- STALE_RULE_MARKER\n' > "$work/stale-rules.md"
for mode in local remote; do
  ctx="$work/rules-$mode.ctx"; : > "$ctx"
  if [ "$mode" = remote ]; then
    ( cd "$rrepo" && ARL_RULES_FILE="$work/stale-rules.md" ARL_TEST_CTX="$ctx" ARL_REVIEW_HOST=fakehost ARL_FANOUT="$tools/rules-fan.sh" "$gate" main ) > "$work/rules-$mode.out" 2>&1
  else
    ( cd "$rrepo" && env -u ARL_REVIEW_HOST ARL_RULES_FILE="$work/stale-rules.md" ARL_TEST_CTX="$ctx" ARL_FANOUT="$tools/rules-fan.sh" "$gate" main ) > "$work/rules-$mode.out" 2>&1
  fi
  grep -q BASE_RULE_MARKER "$ctx" && ! grep -q -e HEAD_RULE_MARKER -e STALE_RULE_MARKER "$ctx" \
    && ok "$mode review uses the base commit's rules" \
    || bad "$mode review did not use the base commit's rules: $(tr '\n' '|' < "$ctx")"
done

# A base with no rules file reviews without rules, even when the diff adds one.
nrepo="$work/norules-repo"
git init -q -b main "$nrepo"
git -C "$nrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$nrepo" checkout -q -b change
printf '## New rule\npaths: *\n- ADDED_RULE_MARKER\n' > "$nrepo/REVIEW-RULES.md"
git -C "$nrepo" add REVIEW-RULES.md
git -C "$nrepo" -c user.email=t@t -c user.name=t commit -q -m change
ctx="$work/norules.ctx"; : > "$ctx"
( cd "$nrepo" && env -u ARL_REVIEW_HOST ARL_TEST_CTX="$ctx" ARL_FANOUT="$tools/rules-fan.sh" "$gate" main ) > "$work/norules.out" 2>&1
grep -q '^VERDICT: APPROVE' "$work/norules.out" && ! grep -q ADDED_RULE_MARKER "$ctx" \
  && ok "a base without rules reviews without them" \
  || bad "a base without rules: $(tail -c 300 "$work/norules.out")"

# A base whose REVIEW-RULES.md is a directory has rules nobody can read; the
# review must stop rather than run without them (git show prints a listing).
drepo="$work/dir-rules-repo"
git init -q -b main "$drepo"
mkdir -p "$drepo/REVIEW-RULES.md"; printf 'x\n' > "$drepo/REVIEW-RULES.md/inner.md"
git -C "$drepo" add REVIEW-RULES.md
git -C "$drepo" -c user.email=t@t -c user.name=t commit -q -m base
git -C "$drepo" checkout -q -b change
printf 'x = 1\n' > "$drepo/a.py"
git -C "$drepo" add a.py
git -C "$drepo" -c user.email=t@t -c user.name=t commit -q -m change
dsha="$(git -C "$drepo" rev-parse HEAD)"
( cd "$drepo" && env -u ARL_REVIEW_HOST ARL_TEST_CTX="$work/dir.ctx" ARL_FANOUT="$tools/rules-fan.sh" "$gate" main ) > "$work/dir.out" 2>&1
[ ! -f "$(git -C "$drepo" rev-parse --absolute-git-dir)/adversarial-review/$dsha" ] && grep -q 'REVIEW-RULES.md' "$work/dir.out" \
  && ok "a base whose REVIEW-RULES.md is not a file stops the review" \
  || bad "a base with a REVIEW-RULES.md directory was reviewed: $(tail -c 300 "$work/dir.out")"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'review-gate: ALL PASS\n'; exit 0
else
  printf 'review-gate: %d FAILURE(S)\n' "$fails"; exit 1
fi

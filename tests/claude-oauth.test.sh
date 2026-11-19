#!/usr/bin/env bash
# Pins how the claude backend picks its subscription credential.
#
# A long-lived `claude setup-token` token (CLAUDE_REVIEW_OAUTH_TOKEN, kept in
# ~/.claude/secrets.env) must reach ONLY the reviewer subprocess, as
# CLAUDE_CODE_OAUTH_TOKEN. Setting it globally would move every Claude Code
# session on the machine onto that token, and sourcing the whole secrets file
# would hand every other secret in it to the reviewer.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../claude-fanout-review.sh"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A stub `claude` that records the credential environment it was given.
mkdir -p "$work/bin"
cat > "$work/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
{
  printf 'oauth=[%s]\n' "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
  printf 'apikey=[%s]\n' "${ANTHROPIC_API_KEY-<unset>}"
  printf 'other=[%s]\n' "${OTHER_SECRET-<unset>}"
  printf 'review=[%s]\n' "${CLAUDE_REVIEW_OAUTH_TOKEN-<unset>}"
} > "$ARL_TEST_SEEN"
echo "VERDICT: APPROVE"
STUB
chmod +x "$work/bin/claude"

printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1 @@\n+y\n' > "$work/ok.diff"

# run <case-name> <home-dir> [env assignments...]: runs the data lens once and
# leaves what the stub saw in $work/<case-name>.seen
run_case() {
  local name="$1" home="$2"; shift 2
  (
    cd "$work" || exit 1
    env -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_REVIEW_OAUTH_TOKEN -u OTHER_SECRET \
        HOME="$home" PATH="$work/bin:$PATH" ANTHROPIC_API_KEY=sk-metered \
        ARL_LENSES=data ARL_TEST_SEEN="$work/$name.seen" "$@" \
        "$script" "$work/ok.diff" "$work/$name" "" "$work"
  ) >/dev/null 2>&1
}
seen() { grep -qxF "$2" "$work/$1.seen" 2>/dev/null; }

# --- token read from the secrets file, CRLF and quotes stripped --------------
mkdir -p "$work/home-file/.claude"
printf 'OTHER_SECRET=do-not-leak\r\nCLAUDE_REVIEW_OAUTH_TOKEN="sk-ant-oat01-fromfile"\r\n' \
  > "$work/home-file/.claude/secrets.env"
run_case file "$work/home-file"
seen file 'oauth=[sk-ant-oat01-fromfile]' \
  && ok "reviewer gets the secrets-file token as CLAUDE_CODE_OAUTH_TOKEN" \
  || bad "reviewer did not get the secrets-file token ($(cat "$work/file.seen" 2>/dev/null | head -1))"
seen file 'other=[<unset>]' \
  && ok "no other secret from the file reaches the reviewer" \
  || bad "another secret from the secrets file leaked into the reviewer"
seen file 'apikey=[<unset>]' \
  && ok "ANTHROPIC_API_KEY is still scrubbed" \
  || bad "ANTHROPIC_API_KEY reached the reviewer"

# --- the environment wins over the file -------------------------------------
run_case envwins "$work/home-file" CLAUDE_REVIEW_OAUTH_TOKEN=sk-ant-oat01-fromenv
seen envwins 'oauth=[sk-ant-oat01-fromenv]' \
  && ok "CLAUDE_REVIEW_OAUTH_TOKEN in the environment wins over the file" \
  || bad "the environment token was not used"

# --- no token anywhere: unchanged, the reviewer uses its own login ----------
mkdir -p "$work/home-none/.claude"
printf 'OTHER_SECRET=x\n' > "$work/home-none/.claude/secrets.env"
run_case none "$work/home-none"
seen none 'oauth=[<unset>]' \
  && ok "without a review token the reviewer keeps its own login" \
  || bad "a credential appeared from nowhere"
run_case nofile "$work/no-such-home"
seen nofile 'oauth=[<unset>]' \
  && ok "a missing secrets file is not an error" \
  || bad "a missing secrets file broke the run"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'claude-oauth: ALL PASS\n'; exit 0
else
  printf 'claude-oauth: %d FAILURE(S)\n' "$fails"; exit 1
fi

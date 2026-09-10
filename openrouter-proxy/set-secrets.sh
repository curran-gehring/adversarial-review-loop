#!/usr/bin/env bash
# Put the two credentials in place and deploy, without either one ever appearing
# in a terminal, a chat, or shell history. Run this ON THE MAC MINI.
#
#   cd ~/adversarial-review-loop/openrouter-proxy && ./set-secrets.sh
#
# Values are read with `read -rs` (no echo) and piped straight to wrangler.
set -euo pipefail
cd "$(dirname "$0")"

# Every file this script creates holds a credential, so restrict by default rather
# than by remembering. A later `chmod 600` is not enough on its own: a shell
# redirect creates the file at the moment the command STARTS, so `read > .cf-token`
# leaves it world-readable for as long as a human takes to paste -- and if the
# paste is interrupted, permanently.
umask 077

# One run at a time. Atomic rename stops a PARTIAL token appearing, but two runs
# can still each complete and the loser silently overwrites the winner, leaving a
# credential in place that nobody thinks they installed. mkdir is the portable
# atomic test-and-set: it fails if the directory already exists, with no separate
# check-then-act window.
LOCK=".set-secrets.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another set-secrets.sh is running (or died holding $LOCK)." >&2
  echo "If nothing else is running: rmdir $LOCK" >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

read_secret() {                 # read_secret <prompt> -> prints to stdout
  local prompt="$1" value=""
  printf '%s: ' "$prompt" > /dev/tty
  IFS= read -rs value < /dev/tty
  printf '\n' > /dev/tty
  [ -n "$value" ] || { echo "empty value; aborting" >&2; exit 1; }
  printf %s "$value"
}

# -s not -f: an interrupted paste used to leave a 0-byte .cf-token behind, after
# which this script said "already present" while deploy.sh said "no token" -- a
# dead end that contradicted itself. A file that exists but holds nothing is not a
# credential.
if [ ! -s .cf-token ]; then
  echo "== Cloudflare Workers API token (the 'Edit Cloudflare Workers' one) =="
  # Write to a temp file in THIS directory and rename into place. Rename is atomic
  # on the same filesystem, so .cf-token only ever exists complete: no truncated
  # file during the paste, and two runs cannot interleave into one concatenated
  # credential. The trap means an abort leaves no half-written secret lying around.
  # Trap FIRST, then create. Nothing secret exists in the gap either way -- umask
  # 077 makes mktemp produce a 0600 file and read_secret does not run until below --
  # but arming the cleanup before the thing it cleans up removes the question.
  # `rm -f ""` is a silent no-op, so the trap is safe while tmp is still unset.
  tmp=""
  # Keep the lock cleanup here too: replacing the EXIT trap instead of extending it
  # would leak the lock directory on abort and wedge every later run.
  trap 'rm -f "$tmp"; rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM
  tmp="$(mktemp ./.cf-token.XXXXXX)"
  chmod 600 "$tmp"
  read_secret "  paste token" > "$tmp"
  [ -s "$tmp" ] || { echo "  empty token; aborting" >&2; exit 1; }
  mv "$tmp" .cf-token
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM
  echo "  saved to .cf-token ($(stat -f '%OLp' .cf-token 2>/dev/null || stat -c '%a' .cf-token), gitignored)"
else
  echo "== .cf-token already present, leaving it alone =="
fi

[ -f .app-token ] || { echo "no .app-token; run: openssl rand -hex 32 > .app-token" >&2; exit 1; }

echo
echo "== OpenRouter key (the NEW one; revoke the leaked one at openrouter.ai/settings/keys) =="
OPENROUTER_NEW="$(read_secret '  paste key')"

echo
echo "== pushing secrets to the worker =="
printf %s "$OPENROUTER_NEW" | ./deploy.sh secret put OPENROUTER_API_KEY
tr -d '[:space:]' < .app-token | ./deploy.sh secret put APP_TOKEN
unset OPENROUTER_NEW

echo
echo "== deploying =="
./deploy.sh deploy

cat <<'MSG'

Done. Two follow-ups this script deliberately does NOT do:

  1. ~/.zshenv still holds the OLD, leaked OPENROUTER_API_KEY. Reviews run from
     this machine use it directly, so replace that line by hand. Editing a shell
     rc file out from under running sessions is not something to automate.

  2. The leaked key is still live until you delete it at
     openrouter.ai/settings/keys. A new key does not disable an old one.
MSG

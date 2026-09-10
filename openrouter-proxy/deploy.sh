#!/usr/bin/env bash
# Run wrangler against the TUCKERMILLING WORK account, deliberately.
#
#   ./deploy.sh whoami
#   ./deploy.sh secret put OPENROUTER_API_KEY
#   ./deploy.sh secret put APP_TOKEN
#   ./deploy.sh deploy
#
# This is the mirror image of FirstWord's ai-proxy/deploy.sh. That script clears
# the ambient credentials because ~/.zshenv points at the work account and
# FirstWord must NOT land there. This worker is review infrastructure for work,
# so the work account is correct — but "correct by default" is how the FirstWord
# proxy nearly shipped to the wrong place, so the account is asserted here rather
# than inherited.
set -euo pipefail
cd "$(dirname "$0")"

WORK_ACCOUNT=6d915d673eea7cb5b949c7479351ccdb

case "${1:-}" in
  login | logout | whoami)
    exec npx wrangler "$@"
    ;;
esac

# The ambient token in ~/.zshenv can read this account but has no Workers scope
# (verified 2026-09-10: /workers/scripts returns 403, /zones returns 200). Two
# ways forward, and this script supports both:
#
#   1. Grant the token "Workers Scripts: Edit" (dash > profile > API tokens), or
#      mint a new one. Then this script works as-is.
#   2. ARL_CF_OAUTH=1 ./deploy.sh deploy — clears the env token so wrangler falls
#      back to `wrangler login` OAuth. Log in as curran@tuckermilling.com first.
#      The env var takes precedence over the login, which is why it must be
#      cleared explicitly rather than just ignored.
if [[ "${ARL_CF_OAUTH:-}" == "1" ]]; then
  unset CLOUDFLARE_API_TOKEN
  export CLOUDFLARE_ACCOUNT_ID="$WORK_ACCOUNT"
  echo "wrangler $* → tuckermilling account $WORK_ACCOUNT (OAuth)"
  exec npx wrangler "$@"
fi

# Prefer a Workers-only token from .cf-token (gitignored, chmod 600).
#
# Do NOT put a Workers token in ~/.zshenv's CLOUDFLARE_API_TOKEN. That variable
# holds an R2 token (id 6fadf0f3…, buckets: dev, ios-ipa, ios-ipa-private,
# tucker-customer-photos) which FirstWord's data pipeline depends on —
# ship_interlinear.py, upload_bible_core_to_r2.py, publish_r2_manifest.py and
# several refresh-*.yml workflows all read it. Overwriting it would break Bible
# data publishing ambiently, with nothing pointing back to this worker.
#
# Least privilege also argues for a second token rather than adding
# "Workers Scripts: Edit" to a storage credential.
if [[ -f .cf-token ]]; then
  CLOUDFLARE_API_TOKEN="$(tr -d '[:space:]' < .cf-token)"
  export CLOUDFLARE_API_TOKEN
  # .cf-token exists for this worker specifically, so the account it belongs to
  # is not in doubt. Still asserted below rather than assumed.
  export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-$WORK_ACCOUNT}"
  echo "using Workers token from .cf-token"
fi

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  cat >&2 <<'MSG'
Refusing to run: no Cloudflare token.

Create a Workers-scoped token (dash > API Tokens > "Edit Cloudflare Workers"
template, scoped to the tuckermilling account), then:

    printf %s '<token>' > .cf-token && chmod 600 .cf-token

Do not reuse the R2 token in ~/.zshenv; see the comment above.
MSG
  exit 1
fi

if [[ "${CLOUDFLARE_ACCOUNT_ID:-}" != "$WORK_ACCOUNT" ]]; then
  cat >&2 <<MSG
Refusing to run: this worker belongs on the tuckermilling work account.

  expected  $WORK_ACCOUNT
  got       ${CLOUDFLARE_ACCOUNT_ID:-<unset>}

If you are on another machine, export CLOUDFLARE_ACCOUNT_ID for the work account.
MSG
  exit 1
fi

echo "wrangler $* → tuckermilling account $CLOUDFLARE_ACCOUNT_ID"
exec npx wrangler "$@"

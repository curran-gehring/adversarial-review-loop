# OpenRouter proxy for the review gate

Keeps the metered OpenRouter key off machines that only need to *run* reviews.

The gate's two OpenRouter lenses need a key that can spend money. Exporting it on
every machine that runs a review puts it on every one of those machines —
including an employer-administered PC, where a personal metered credential does
not belong. With this worker in front, those machines hold an app token instead.

**What that actually buys.** The app token is still a bearer credential; whoever
holds it can spend. What changes is blast radius and recovery. A leaked app token
reaches only this worker, which caps the model, caps output tokens and rate-limits
the caller, and is revoked by re-putting one secret. A leaked OpenRouter key can be
spent on any model, at any volume, until someone notices the bill.

It is **not** a resilience layer. When OpenRouter or the upstream provider is rate
limited, the proxy fails the same way a direct call would.

## Using it from another machine

No change to the review loop — it already honours `ARL_OPENROUTER_BASE_URL` and
sends `OPENROUTER_API_KEY` as the bearer. On a proxied machine that variable holds
the **app token**, not the real key:

    export ARL_OPENROUTER_BASE_URL=https://arl-openrouter-proxy.<subdomain>.workers.dev/api/v1
    export OPENROUTER_API_KEY=<app token>

The correctness lens runs on `codex` against a ChatGPT subscription and never
touches this worker — so that machine also needs `codex` logged in. Without it you
are running two Gemini lenses and no Astra, which on real work has been the lens
that finds things.

## Deploying

Deploys to the **tuckermilling work account** (`6d915d67…`), asserted rather than
inherited — see the header of `deploy.sh` for why that distinction is not
pedantic.

    ./deploy.sh secret put OPENROUTER_API_KEY   # the real metered key
    ./deploy.sh secret put APP_TOKEN            # what callers present
    ./deploy.sh deploy

⚠️ **The `CLOUDFLARE_API_TOKEN` in `~/.zshenv` cannot deploy this.** It reads the
account fine (`/zones` → 200) but has no Workers scope (`/workers/scripts` → 403),
so `wrangler deploy` fails with `Authentication error [code: 10000]`. Either add
*Workers Scripts: Edit* to that token, or:

    ARL_CF_OAUTH=1 ./deploy.sh deploy    # after `wrangler login`

`ARL_CF_OAUTH=1` clears the env token so wrangler falls back to OAuth. The env var
takes precedence over `wrangler login`, so it must be cleared explicitly.

## Limits

`wrangler.toml` holds the allowlist (`ALLOWED_MODELS`) and the output cap
(`MAX_TOKENS`). Adding a model there is the only way to make it spendable through
this proxy. That is the design, not an oversight.

Tests: `npm test` (20 vitest cases, no network).

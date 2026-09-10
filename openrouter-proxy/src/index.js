/// OpenRouter proxy for the adversarial review gate.
///
/// Why this exists: the gate's two OpenRouter lenses need a metered key. Putting
/// that key in the shell of every machine that runs a review means the key is on
/// every one of those machines — including an employer-administered PC, where a
/// personal metered credential does not belong. Callers present APP_TOKEN
/// instead; the real key stays here.
///
/// What that actually buys, stated honestly: the app token is still a bearer
/// credential and whoever holds it can spend money. What changes is the blast
/// radius and the recovery. A leaked app token reaches only this worker, which
/// caps the model, caps output tokens and rate-limits the caller, and is revoked
/// by re-putting one secret. A leaked OpenRouter key can be spent on any model,
/// at any volume, until someone notices the bill.
///
/// No code change is needed in the review loop: it already honours
/// ARL_OPENROUTER_BASE_URL, and it sends OPENROUTER_API_KEY as the bearer. On a
/// proxied machine that variable holds the app token, not the real key.

const UPSTREAM = "https://openrouter.ai/api/v1/chat/completions";
const PATH = "/api/v1/chat/completions";
/// Used when MAX_TOKENS is unset or malformed. Never left to NaN.
const DEFAULT_MAX_TOKENS = 4000;

/// Constant-time compare. A plain === leaks the token a character at a time to
/// anyone who can measure the response, and this endpoint spends money.
function tokensMatch(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const problem = (status, message) =>
  new Response(JSON.stringify({ error: { message, type: "arl_proxy" } }), {
    status,
    headers: { "content-type": "application/json" },
  });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ ok: true }), {
        headers: { "content-type": "application/json" },
      });
    }

    if (url.pathname !== PATH) {
      return problem(404, `no route for ${url.pathname}; this proxy serves only ${PATH}`);
    }
    if (request.method !== "POST") {
      return problem(405, "POST only");
    }

    // Fail closed. A worker deployed before `wrangler secret put APP_TOKEN` must
    // refuse everyone rather than accept everyone, which is what an empty-string
    // comparison would quietly do.
    if (!env.APP_TOKEN) {
      return problem(500, "proxy is misconfigured: APP_TOKEN is not set");
    }
    if (!env.OPENROUTER_API_KEY) {
      return problem(500, "proxy is misconfigured: OPENROUTER_API_KEY is not set");
    }

    const presented = (request.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!tokensMatch(presented, env.APP_TOKEN)) {
      return problem(401, "bad or missing app token");
    }

    // Rate limit AFTER auth, so an unauthenticated flood cannot consume the
    // budget of a legitimate caller sharing an IP.
    if (env.RATE_LIMITER) {
      const key = request.headers.get("cf-connecting-ip") ?? "unknown";
      const { success } = await env.RATE_LIMITER.limit({ key });
      if (!success) return problem(429, "rate limited by the proxy");
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return problem(400, "body is not valid JSON");
    }
    if (!body || typeof body !== "object" || !Array.isArray(body.messages)) {
      return problem(400, "expected an object with a messages array");
    }

    const allowed = (env.ALLOWED_MODELS ?? "")
      .split(",").map((m) => m.trim()).filter(Boolean);
    if (!allowed.includes(body.model)) {
      return problem(400,
        `model ${JSON.stringify(body.model)} is not on this proxy's allowlist (${allowed.join(", ") || "empty"})`);
    }

    // Cap rather than reject: a review that asks for too much output should come
    // back shorter, not fail the gate. A lens returning no VERDICT line counts as
    // REJECT, so turning a spend mistake into a hard failure would be worse than
    // truncating.
    //
    // But "cap" only holds if what goes out is a valid token count. Math.min
    // alone happily forwards -5, 0, 1.5, or NaN, and OpenRouter answers those
    // with a 400 -- which is precisely the silent gate failure this branch exists
    // to avoid. Anything that is not a positive integer becomes the cap.
    const positiveInt = (value, fallback) => {
      const n = Number(value);
      return Number.isFinite(n) && n >= 1 ? Math.floor(n) : fallback;
    };
    const cap = positiveInt(env.MAX_TOKENS, DEFAULT_MAX_TOKENS);
    const outgoing = {
      ...body,
      max_tokens: Math.min(positiveInt(body.max_tokens, cap), cap),
    };

    let upstream;
    try {
      upstream = await fetch(UPSTREAM, {
        method: "POST",
        headers: {
          authorization: `Bearer ${env.OPENROUTER_API_KEY}`,
          "content-type": "application/json",
          "HTTP-Referer": "https://github.com/curran-gehring/adversarial-review-loop",
          "X-Title": "adversarial-review-loop",
        },
        body: JSON.stringify(outgoing),
      });
    } catch (e) {
      return problem(502, `upstream request failed: ${e?.message ?? "unknown"}`);
    }

    // Pass the upstream status and body straight back so the review loop sees
    // OpenRouter's own errors. Upstream never receives, and so cannot echo, the
    // app token; the only credential in play here is the real key, which is in a
    // request header and not in any response.
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
    });
  },
};

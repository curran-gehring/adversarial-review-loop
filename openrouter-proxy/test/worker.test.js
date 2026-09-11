import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index.js";

const env = {
  OPENROUTER_API_KEY: "sk-or-the-real-metered-key",
  APP_TOKEN: "gate-token",
  ALLOWED_MODELS: "google/gemini-3.8-flash",
  MAX_TOKENS: "16000",
};

const body = {
  model: "google/gemini-3.8-flash",
  messages: [{ role: "user", content: "review this diff" }],
  max_tokens: 2000,
};

// The review loop calls `$ARL_OPENROUTER_BASE_URL/chat/completions`, so with the
// base URL pointed here the path is /api/v1/chat/completions.
const post = (b = body, { token = "gate-token", path = "/api/v1/chat/completions" } = {}) =>
  new Request(`https://proxy.example${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token === null ? {} : { authorization: `Bearer ${token}` }),
    },
    body: JSON.stringify(b),
  });

const upstreamOk = () =>
  vi.stubGlobal("fetch", vi.fn(async () =>
    new Response(JSON.stringify({ choices: [{ message: { content: "VERDICT: APPROVE" } }] }),
      { status: 200, headers: { "content-type": "application/json" } })));

afterEach(() => vi.unstubAllGlobals());

describe("auth", () => {
  it("rejects a missing token without calling upstream", async () => {
    const spy = vi.fn();
    vi.stubGlobal("fetch", spy);
    const res = await worker.fetch(post(body, { token: null }), env);
    expect(res.status).toBe(401);
    expect(spy).not.toHaveBeenCalled();
  });

  it("rejects a wrong token without calling upstream", async () => {
    const spy = vi.fn();
    vi.stubGlobal("fetch", spy);
    const res = await worker.fetch(post(body, { token: "guessed" }), env);
    expect(res.status).toBe(401);
    expect(spy).not.toHaveBeenCalled();
  });

  it("never echoes the real key back to the caller", async () => {
    upstreamOk();
    const res = await worker.fetch(post(), env);
    const text = await res.text();
    expect(text).not.toContain(env.OPENROUTER_API_KEY);
  });
});

describe("upstream call", () => {
  it("swaps the app token for the real key", async () => {
    upstreamOk();
    await worker.fetch(post(), env);
    const [url, init] = globalThis.fetch.mock.calls[0];
    expect(url).toBe("https://openrouter.ai/api/v1/chat/completions");
    expect(init.headers.authorization).toBe(`Bearer ${env.OPENROUTER_API_KEY}`);
    // The caller's token must not travel upstream.
    expect(JSON.stringify(init.headers)).not.toContain("gate-token");
  });

  it("passes the review body through", async () => {
    upstreamOk();
    await worker.fetch(post(), env);
    const sent = JSON.parse(globalThis.fetch.mock.calls[0][1].body);
    expect(sent.messages[0].content).toBe("review this diff");
  });
});

describe("spend limits", () => {
  it("refuses a model that is not on the allowlist", async () => {
    const spy = vi.fn();
    vi.stubGlobal("fetch", spy);
    const res = await worker.fetch(post({ ...body, model: "openai/gpt-5" }), env);
    expect(res.status).toBe(400);
    expect(spy).not.toHaveBeenCalled();
  });

  it("caps max_tokens rather than rejecting an over-large request", async () => {
    upstreamOk();
    await worker.fetch(post({ ...body, max_tokens: 999999 }), env);
    const sent = JSON.parse(globalThis.fetch.mock.calls[0][1].body);
    expect(sent.max_tokens).toBe(16000);
  });

  // A bad max_tokens must never reach OpenRouter. An upstream 400 makes the lens
  // return no VERDICT line, and the gate counts a missing VERDICT as REJECT -- so
  // a junk value would silently fail a review rather than merely truncating it.
  it.each([
    ["negative", -5],
    ["zero", 0],
    ["a string", "lots"],
    ["null", null],
  ])("replaces a %s max_tokens with the cap", async (_label, value) => {
    upstreamOk();
    await worker.fetch(post({ ...body, max_tokens: value }), env);
    const sent = JSON.parse(globalThis.fetch.mock.calls[0][1].body);
    expect(sent.max_tokens).toBe(16000);
  });

  // Fractional values are floored, not replaced -- 100.9 is a coherent ask, just
  // not an integer. Only values that cannot mean a token count (<=0, non-numeric)
  // fall back to the cap.
  it("floors a fractional request that is under the cap", async () => {
    upstreamOk();
    await worker.fetch(post({ ...body, max_tokens: 100.9 }), env);
    const sent = JSON.parse(globalThis.fetch.mock.calls[0][1].body);
    expect(sent.max_tokens).toBe(100);
  });

  it("falls back to a sane cap when MAX_TOKENS itself is malformed", async () => {
    upstreamOk();
    await worker.fetch(post(), { ...env, MAX_TOKENS: "not-a-number" });
    const sent = JSON.parse(globalThis.fetch.mock.calls[0][1].body);
    expect(Number.isInteger(sent.max_tokens)).toBe(true);
    expect(sent.max_tokens).toBeGreaterThan(0);
  });

  it("supplies max_tokens when the caller omits it", async () => {
    upstreamOk();
    const { max_tokens, ...noCap } = body;
    await worker.fetch(post(noCap), env);
    const sent = JSON.parse(globalThis.fetch.mock.calls[0][1].body);
    expect(sent.max_tokens).toBe(16000);
  });
});

describe("routing", () => {
  it("answers /health without a token", async () => {
    const res = await worker.fetch(new Request("https://proxy.example/health"), env);
    expect(res.status).toBe(200);
  });

  it("404s an unknown path even with a valid token", async () => {
    const spy = vi.fn();
    vi.stubGlobal("fetch", spy);
    const res = await worker.fetch(post(body, { path: "/api/v1/embeddings" }), env);
    expect(res.status).toBe(404);
    expect(spy).not.toHaveBeenCalled();
  });

  it("rejects GET on the completions path", async () => {
    const res = await worker.fetch(
      new Request("https://proxy.example/api/v1/chat/completions", {
        method: "GET", headers: { authorization: "Bearer gate-token" },
      }), env);
    expect(res.status).toBe(405);
  });
});

describe("failure modes", () => {
  it("refuses to run if APP_TOKEN was never set, rather than allowing everyone", async () => {
    const spy = vi.fn();
    vi.stubGlobal("fetch", spy);
    const res = await worker.fetch(post(), { ...env, APP_TOKEN: undefined });
    expect(res.status).toBe(500);
    expect(spy).not.toHaveBeenCalled();
  });

  it("surfaces an upstream error without leaking the key", async () => {
    vi.stubGlobal("fetch", vi.fn(async () =>
      new Response(JSON.stringify({ error: "rate limited" }), { status: 429 })));
    const res = await worker.fetch(post(), env);
    expect(res.status).toBe(429);
    expect(await res.text()).not.toContain(env.OPENROUTER_API_KEY);
  });

  it("rejects a malformed body", async () => {
    const spy = vi.fn();
    vi.stubGlobal("fetch", spy);
    const res = await worker.fetch(new Request("https://proxy.example/api/v1/chat/completions", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer gate-token" },
      body: "{not json",
    }), env);
    expect(res.status).toBe(400);
    expect(spy).not.toHaveBeenCalled();
  });
});

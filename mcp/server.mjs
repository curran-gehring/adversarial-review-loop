#!/usr/bin/env node
// Async MCP wrapper around `codex exec`. Two-call review flow (start → poll)
// so long adversarial reviews survive the synchronous MCP tool-call timeout,
// and a `codex_ask` for short questions. ChatGPT-account safe (no --model by
// default), honest errors (surfaces codex's real stderr).
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { startReview, pollReview, listJobs, askCodex } from "./lib/codex.mjs";

const server = new Server(
  { name: "codex-review-mcp", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

const TOOLS = [
  {
    name: "codex_review_start",
    description:
      "Start an adversarial code review with `codex exec` (read-only sandbox) " +
      "and return a job_id IMMEDIATELY — does not wait, so it survives long " +
      "(20–40 min) reviews that would time out a synchronous tool call. Pipe " +
      "the diff via `diff`. Poll with codex_review_poll. Runs on the account's " +
      "default model (ChatGPT-account safe); never passes --ask-for-approval.",
    inputSchema: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "Review instructions. Ask codex to end with a `VERDICT: APPROVE` / `VERDICT: REJECT — <reason>` line." },
        diff: { type: "string", description: "The unified diff (or any context) to pipe to codex's stdin." },
        diffPath: { type: "string", description: "Alternative to `diff`: an absolute path on the codex host to read the diff from." },
        cwd: { type: "string", description: "Working dir for codex (default: home). Point at the repo so codex can read source/DBs." },
        model: { type: "string", description: "Optional model override. OMIT on a ChatGPT-subscription account (it rejects gpt-5-codex); the default works." },
      },
      required: ["prompt"],
    },
  },
  {
    name: "codex_review_poll",
    description:
      "Poll a review started with codex_review_start. Returns {status: " +
      "running|done|error}. When done, includes the verdict (APPROVE/REJECT), " +
      "the findings, or — on error — codex's REAL message (e.g. an unsupported " +
      "model), not a misleading wrapper error.",
    inputSchema: {
      type: "object",
      properties: { job_id: { type: "string", description: "The job_id from codex_review_start." } },
      required: ["job_id"],
    },
  },
  {
    name: "codex_review_list",
    description: "List recent review jobs and whether each is still running.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "codex_ask",
    description:
      "Ask codex a SHORT question and get the answer in one call (synchronous, " +
      "bounded by timeoutMs). For quick consults where the async review flow is " +
      "overkill. Runs read-only; ChatGPT-account safe; surfaces codex's real " +
      "error. For anything that might run long, use codex_review_start instead.",
    inputSchema: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "The question / task for codex." },
        context: { type: "string", description: "Optional text (e.g. a snippet or diff) piped to codex's stdin." },
        cwd: { type: "string", description: "Working dir for codex (default: home)." },
        model: { type: "string", description: "Optional model override. OMIT on a ChatGPT account." },
        timeoutMs: { type: "number", description: "Max wait in ms (default 120000). Kept under the MCP tool-call limit." },
      },
      required: ["prompt"],
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

function textResult(obj, summary) {
  const body = typeof obj === "string" ? obj : JSON.stringify(obj, null, 2);
  return { content: [{ type: "text", text: summary ? `${summary}\n\n${body}` : body }] };
}

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args = {} } = req.params;
  try {
    if (name === "codex_review_start") {
      const r = startReview(args);
      return textResult(r, `▶ review started — poll with codex_review_poll({ job_id: "${r.job_id}" })`);
    }
    if (name === "codex_review_poll") {
      if (!args.job_id) throw new Error("job_id is required");
      const r = pollReview(args.job_id);
      const summary =
        r.status === "running" ? `⏳ still running (${Math.round((r.elapsed_ms || 0) / 1000)}s)`
        : r.status === "error" ? `❌ codex error: ${r.error}`
        : `✅ done — VERDICT: ${r.verdict || "(none emitted)"}`;
      return textResult(r, summary);
    }
    if (name === "codex_review_list") {
      return textResult(listJobs());
    }
    if (name === "codex_ask") {
      const r = await askCodex(args);
      if (r.ok) return textResult(r.answer || "(empty)");
      return { isError: true, content: [{ type: "text", text: `❌ ${r.error}${r.partial ? `\n\n--- partial ---\n${r.partial}` : ""}` }] };
    }
    throw new Error(`unknown tool: ${name}`);
  } catch (e) {
    return { isError: true, content: [{ type: "text", text: `❌ ${e?.message || e}` }] };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
// stderr only — stdout is the MCP channel.
process.stderr.write("codex-review-mcp ready\n");

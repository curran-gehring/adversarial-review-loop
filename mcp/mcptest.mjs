// End-to-end MCP protocol test: spawns server.mjs over stdio, lists tools,
// and exercises the async review flow with a TRIVIAL codex prompt (so it's
// fast) — proving the start→poll loop and honest verdict extraction work
// through the real MCP transport.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const transport = new StdioClientTransport({ command: "node", args: [join(here, "server.mjs")] });
const client = new Client({ name: "mcptest", version: "1.0" }, { capabilities: {} });
await client.connect(transport);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const textOf = (r) => r.content?.map((c) => c.text).join("\n") ?? "";

const tools = await client.listTools();
console.log("tools:", tools.tools.map((t) => t.name).join(", "));

// Start a trivial review: ask codex to just emit a verdict. Fast.
const start = await client.callTool({
  name: "codex_review_start",
  arguments: {
    prompt: "This is a connectivity self-test. Do not analyze anything. Reply with exactly one line and nothing else: VERDICT: APPROVE",
  },
});
console.log("\nstart →\n" + textOf(start));
const jobId = JSON.parse(textOf(start).split("\n").slice(1).join("\n")).job_id;

let last;
for (let i = 0; i < 40; i++) {
  await sleep(5000);
  const poll = await client.callTool({ name: "codex_review_poll", arguments: { job_id: jobId } });
  last = JSON.parse(textOf(poll).split("\n").slice(1).join("\n"));
  console.log(`poll[${i}] status=${last.status}` + (last.verdict ? ` verdict=${last.verdict}` : "") + (last.error ? ` error=${last.error}` : ""));
  if (last.status !== "running") break;
}

await client.close();
const ok = last && last.status === "done" && last.verdict === "APPROVE";
console.log("\n" + (ok ? "MCP E2E OK" : "MCP E2E FAILED"));
process.exit(ok ? 0 : 1);

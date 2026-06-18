# codex-review-mcp

A thin **async** MCP wrapper around `codex exec` for long, honest adversarial
code reviews. Built because the obvious off-the-shelf wrappers had three
problems:

1. **Synchronous tool calls time out** on long (20–40 min) reviews — the MCP
   client kills the call before codex finishes. This wrapper is **async**:
   `codex_review_start` returns a `job_id` immediately; `codex_review_poll`
   reads the verdict when it's done. No timeout.
2. **ChatGPT-account breakage.** Passing `model: gpt-5-codex` fails on a
   ChatGPT-subscription codex (`"…not supported when using Codex with a
   ChatGPT account"`). This wrapper **omits `--model` by default** (account
   default works) and never passes `--ask-for-approval` (removed in codex
   0.30+).
3. **Misleading errors.** Some wrappers brand any error mentioning "sandbox" as
   a sandbox violation — and codex's preamble always prints `sandbox: read-only`,
   so an unsupported-model 400 looks like a permissions problem. This wrapper
   surfaces codex's **real** stderr.

## Tools

- `codex_review_start({ prompt, diff?, diffPath?, cwd?, model? })` → `{ job_id }`.
  Pipes `diff` to codex stdin; runs `codex exec -s read-only --skip-git-repo-check`.
- `codex_review_poll({ job_id })` → `{ status: running|done|error, verdict, findings, error }`.
  Verdict is codex's LAST `VERDICT:` line (the early ones are the echoed prompt).
- `codex_review_list()` → recent jobs.
- `codex_ask({ prompt, context?, cwd?, model?, timeoutMs? })` → a SHORT
  synchronous consult (default 120s cap). For quick questions where the async
  review flow is overkill; for anything long use `codex_review_start`.

## Run

```sh
npm install
node server.mjs        # stdio MCP server
npm run selftest       # pure-parser unit tests (no codex needed)
node mcptest.mjs       # end-to-end over the MCP transport (needs codex on PATH)
```

Requires the `codex` CLI (`@openai/codex`) on PATH and logged in. See
`../docs/install.md` for the full setup, including how to wire this server into
Claude Code for both local and remote (SSH) Codex hosts.

## Wiring (summary)

- **Codex on the same machine as Claude Code:** register a stdio MCP server
  whose command is `node /ABS/PATH/TO/mcp/server.mjs`.
- **Codex on a remote host you SSH to:** make the command SSH there and run the
  server on that host, e.g.
  `ssh <REVIEW_HOST> node /ABS/PATH/ON/REMOTE/mcp/server.mjs`.

Job state lives under `~/.codex-review-mcp/jobs` by default; override with the
`CODEX_REVIEW_JOBS_DIR` env var.

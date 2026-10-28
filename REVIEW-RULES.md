# adversarial-review-loop review rules

Sent to the adversarial review lenses when a diff touches a matching path. Each rule records a defect that shipped or was caught once. Add a rule when a reviewer could have seen the defect in the diff.

## Gate must fail closed
paths: lenses.sh gate.sh panel-review.sh review-gate.sh *fanout-review.sh

- The gate's only job is to catch bad changes, so every uncertain state ends in `VERDICT: REJECT -- <why>`: a runner exit, timeout, empty output, unparseable response, missing verdict, or a lens absent from the panel. Never let one end as APPROVE or as a log with no verdict. For agy, judge by the `result` event's status, not the exit code (it can exit 0 on a failed turn).
- `DIFF` and `OUT` go through `arl_abs` before any `cd "$REPO"`, and `arl_require_diff` runs before a reviewer launches. A relative `DIFF` fails to open after the `cd`, `cat` feeds an empty diff, and a model with nothing to criticize answers APPROVE. A relative `OUT` leaves logs under the repo, so a real approval reads as "no verdict".
- `arl_clear_logs "$OUT" ...` is the first executable statement after the arguments are read, before the diff check, spec validation or any dependency preflight that can `exit`. Callers only grep for `VERDICT` and discard stderr, so a surviving log from the previous run passes a diff nobody reviewed. It happened three review rounds in a row, each one line lower.
- A fix to argument handling, locking or prompts lands in `lenses.sh` and applies to all four backends (codex, claude, gemini, openrouter). Fixing the file you are looking at has repeatedly left the other three exposed; tests must loop over the backends.
- Verdicts are read from a line start, the last `VERDICT:` line wins, and the decision token is compared exactly. `VERDICT: REJECT -- the prior APPROVE was stale` must not count as an approval (also `hooks/require-review.py`, `mcp/lib/codex.mjs`).
- Never put the diff or inlined files on a command line (Windows caps argv near 32 KB): agy gets stream-json on stdin, codex and claude get the diff piped. Credentials go in a curl `-K` file created under `umask 077`, not argv.
- Pick the interpreter with `arl_pick_python`, which runs `-c pass`. On Windows `python3` is an App Execution Alias that satisfies `command -v` and then dies with 0x80070003, turning a broken environment into three REJECTs that read like findings.
- `arl_lock_prefix` locks with mkdir, and `ARL_PREFIX_LOCK_HELD` holds the prefix, not a boolean. A trap that replaces the unlock-only trap must still call `arl_unlock_prefix`.
- `review-gate.sh` pins `sha` and `basesha` once and decides from its own mktemp logs, never the shared `last-review` copy. It never deletes a receipt on REJECT. Remote mode sends every `*.sh`, since each runner sources `lenses.sh` from its own directory.
- A new `*.sh` must be mode 100755; files authored on Windows commit as 100644 and fail with permission denied on macOS.

## Panel and backends
paths: gate.sh panel-review.sh gemini-fanout-review.sh openrouter-fanout-review.sh claude-fanout-review.sh lenses.sh

- One model on all three lenses ships real bugs (the 12-case bake-off). Defaults and fallbacks keep two families; `ARL_GATE=single` picks the family opposite the author and is not "always codex".
- The OpenRouter fallback reruns a lens only when it produced no review (no `VERDICT`, or an infra-failure REJECT the gemini runner wrote). A REJECT a reviewer actually wrote stands. Keep the fallback's regex in step with the exact REJECT strings `gemini-fanout-review.sh` emits.
- agy runs from an empty per-lens directory with no tool permissions, and the prompt says it has no tools. Started inside the repo it ran the tests, print mode denied them, and the turn ended with no review.
- Keep both load-bearing clauses of `ARL_LENS_RULES` ("state briefly what you checked"; the no-compile-claim clause). The `claude` backend runs `env -u ANTHROPIC_API_KEY` and never `--bare`. Inlined file paths come from the rest of each `+++ b/` line, not `awk $2`, which drops paths with spaces.

## OpenRouter proxy
paths: openrouter-proxy/* gate.sh openrouter-fanout-review.sh

- The Worker refuses everyone when `APP_TOKEN` or `OPENROUTER_API_KEY` is unset, compares tokens in constant time, rate-limits after auth, and enforces `ALLOWED_MODELS`. Clients send `ARL_PROXY_TOKEN` to any base URL other than openrouter.ai, never the real key. Do not widen the allowlist for other apps.
- Every slug a gate mode uses (including `openai/gpt-5.6-luna` for `ARL_GATE=nocodex`) must be in `ALLOWED_MODELS`, or the lens fails with a 400. `max_tokens` is clamped to a positive integer (`-5`, `0`, `1.5`, `NaN` come back as 400s) and stays 16000: at 4000 the data lens was cut off before its verdict on large diffs.

## MCP wrapper
paths: mcp/*

- `codex exec` runs read-only, without `--ask-for-approval` (removed in codex 0.30+) and without `--model` by default (a ChatGPT account rejects `gpt-5-codex`). While a job is still alive, a `VERDICT` in its log is the echoed prompt; read the verdict only after the process exits.

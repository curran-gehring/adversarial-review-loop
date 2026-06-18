# adversarial-review-loop

**Nothing reaches `main` until a *different* model adversarially reviews it and
returns `APPROVE`.**

The leverage here isn't any one tool — it's **two independent models**. The model
that *writes* a change shares its own blind spots; a model from a *different*
family, reviewing with an independent chain-of-thought, catches what the author
can't see. This repo wires that into your push path as a loop:

```
  ┌────────────┐    diff     ┌────────────────────────────────┐
  │   author   │ ──────────▶ │  independent reviewer (fan-out) │
  │  (Claude)  │             │   correctness │ data │ ui       │
  └────────────┘             └───────────────┬────────────────┘
        ▲                                     │ 3 × VERDICT lines
        │  REJECT → fix & re-run              ▼
        │                        APPROVE iff ALL THREE approve
        └─────────────────────────────────────┤
                                               ▼  APPROVE
                                         git push → main
                                         (pre-push gate verifies)
```

The **reviewer is pluggable** — the only contract is "a different model that ends
its review with a `VERDICT: APPROVE` / `VERDICT: REJECT — <reason>` line." This
repo ships **Codex as the reference reviewer** (it's a strong, independent model
you can run on a ChatGPT subscription with no API cost), but the protocol and the
gate don't care which model produces the verdict.

## What's in the box

| Path | What it is |
|---|---|
| `mcp/` | `codex-review-mcp` — an **async** MCP wrapper around `codex exec` (the reference reviewer adapter). Start→poll so long reviews survive the tool-call timeout; ChatGPT-account safe; surfaces the reviewer's real errors. |
| `fanout-review.sh` | The 3-lens parallel review (correctness / data / ui). APPROVE iff all three approve. |
| `hooks/pre-push-main-guard.sh` | A git pre-push hook: refuses pushes to `main` that aren't descendants of `origin/main`. |
| `hooks/require-review.py` | A Claude Code PreToolUse hook: blocks any `git push` reaching `main` unless the recent transcript shows a completed review with `VERDICT: APPROVE`. |
| `docs/protocol.md` | The protocol: why fan out, the aggregation rule, the loop, operational gotchas. |
| `docs/install.md` | **Full step-by-step setup** — prerequisites, MCP registration (local & remote), both hooks, the fan-out, and a copy-pasteable end-to-end walkthrough. |
| `examples/CLAUDE.md.example` | A drop-in review convention for your repo's `CLAUDE.md`. |

## Quickstart (5 minutes)

1. **Reviewer CLI**: install `@openai/codex`, `codex login` (ChatGPT account is
   fine — omit `--model`). Confirm:
   `echo hi | codex exec -s read-only --skip-git-repo-check "reply: VERDICT: APPROVE"`
2. **MCP**: `cd mcp && npm install && npm run selftest` → register with Claude
   Code: `claude mcp add codex-review -- node "$PWD/server.mjs"`.
3. **Gates**: copy `hooks/pre-push-main-guard.sh` → your repo's
   `.git/hooks/pre-push` (chmod +x); register `hooks/require-review.py` as a
   `PreToolUse` `Bash` hook in Claude Code `settings.json`.
4. **Review a change**:
   ```sh
   git diff main...HEAD > /tmp/review.diff
   ./fanout-review.sh /tmp/review.diff /tmp/review-fan "short context" "$PWD"
   grep -h '^VERDICT:' /tmp/review-fan.{correctness,data,ui}.log
   ```
   All three APPROVE → `git push origin main`. Any REJECT → fix, re-run, repeat.

Full details, the remote-reviewer (SSH) shape, and troubleshooting are in
[`docs/install.md`](docs/install.md). The protocol and its rationale are in
[`docs/protocol.md`](docs/protocol.md).

## Scope

This is the **review loop**, not a deployment system. It ends at the gated
`git push` to `main`; wire your own build/ship to trigger after that. The one
guarantee it makes: nothing lands on `main` without an independent APPROVE.

## Swapping the reviewer

Use any independent model you like. To swap Codex out, point `fanout-review.sh`
at a different CLI (keep the `VERDICT:` last-line contract), and/or add an MCP
adapter alongside `mcp/`. The gate (`require-review.py`) already matches any MCP
tool whose name ends `__ask-codex` or `__codex_review_poll`, plus a
general-purpose `Agent` review — so an agent-driven review by a non-Codex model
satisfies it too.

## License

MIT — see [LICENSE](LICENSE).

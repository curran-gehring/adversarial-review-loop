<h1 align="center">adversarial-review-loop</h1>

<p align="center">
  <strong>Nothing reaches <code>main</code> until a <em>different</em> model adversarially reviews it and returns <code>APPROVE</code>.</strong>
</p>

<p align="center">
  <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue.svg">
  <img alt="Reviewer: pluggable" src="https://img.shields.io/badge/reviewer-pluggable-6f42c1.svg">
  <img alt="Default reviewer: Codex" src="https://img.shields.io/badge/default%20reviewer-Codex-black.svg">
  <img alt="Philosophy: quality over quantity" src="https://img.shields.io/badge/philosophy-quality%20%3E%20quantity-2ea44f.svg">
</p>

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

<details open>
<summary><strong>Install &amp; run — the whole thing on one page</strong></summary>

```sh
# 1. Reviewer CLI (the independent model). ChatGPT account is fine — omit --model.
npm install -g @openai/codex && codex login
echo hi | codex exec -s read-only --skip-git-repo-check "reply exactly: VERDICT: APPROVE"

# 2. This toolkit + the MCP wrapper (lets Claude drive long reviews).
git clone https://github.com/curran-gehring/adversarial-review-loop
cd adversarial-review-loop/mcp && npm install && npm run selftest    # "ALL PASS"
claude mcp add codex-review -- node "$PWD/server.mjs"

# 3. The two gates, installed into a repo you want protected.
cp ../hooks/pre-push-main-guard.sh <your-repo>/.git/hooks/pre-push
chmod +x <your-repo>/.git/hooks/pre-push
#    + register hooks/require-review.py as a PreToolUse "Bash" hook in
#      Claude Code settings.json (snippet in docs/install.md).

# 4. Review a change, then push only on a clean sweep.
git diff main...HEAD > /tmp/review.diff
../fanout-review.sh /tmp/review.diff /tmp/review-fan "short context" "$PWD"
grep -h '^VERDICT:' /tmp/review-fan.{correctness,data,ui}.log
#   all three APPROVE → git push origin main
#   any REJECT        → fix, regenerate the diff, re-run. Repeat.
```

Full setup (incl. the remote-reviewer / SSH shape and troubleshooting):
**[`docs/install.md`](docs/install.md)** · The protocol and its rationale:
**[`docs/protocol.md`](docs/protocol.md)**.

</details>

---

## This is not a "10× your output" hack

Most Claude-Code repos sell you **speed**: more code, more PRs, more velocity,
"ship 10× faster." This one sells the opposite, on purpose.

Here an independent model has to find **nothing wrong** before anything lands on
`main`. That makes building **slower** — there's a review gate and a
fix-until-approved loop standing between you and every merge. You will write less
code per day.

What you get back:

- **Correctness at "done."** When a change merges, it has survived a model that
  doesn't share the author's blind spots, scoped across correctness, data, and
  UI. "Done" means done — not "done pending the bugs we find next week."
- **Far less time spent fixing.** The cheapest bug is the one that never reaches
  `main`. Time you'd have spent debugging in production is spent up front, once,
  by a reviewer — and most of it never becomes your problem.
- **Less throwaway.** Fewer revert-and-retry cycles. The code you write tends to
  be the code that stays.

The leverage isn't a clever prompt or a faster model. It's **two independent
models**: the one that *writes* a change can't see its own mistakes; a model from
a *different* family, reviewing with an independent chain-of-thought, can. The
real measure isn't lines per hour — it's **how little of your week goes to
fixing what already shipped**.

> Quality over quantity. Slower to build, sturdier when built.

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

## Scope

This is the **review loop**, not a deployment system. It ends at the gated
`git push` to `main`; wire your own build/ship to trigger after that. The one
guarantee it makes: nothing lands on `main` without an independent APPROVE.

## Swapping the reviewer

The **reviewer is pluggable** — the only contract is "a different model that ends
its review with a `VERDICT: APPROVE` / `VERDICT: REJECT — <reason>` line." This
repo ships **Codex as the reference reviewer** (a strong, independent model you
can run on a ChatGPT subscription with no API cost), but the protocol and the
gate don't care which model produces the verdict.

To swap Codex out, point `fanout-review.sh` at a different CLI (keep the
`VERDICT:` last-line contract), and/or add an MCP adapter alongside `mcp/`. The
gate (`require-review.py`) already matches any MCP tool whose name ends
`__ask-codex` or `__codex_review_poll`, plus a general-purpose `Agent` review —
so an agent-driven review by a non-Codex model satisfies it too.

## License

MIT — see [LICENSE](LICENSE).

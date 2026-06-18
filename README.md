<h1 align="center">adversarial-review-loop</h1>

<p align="center">
  <strong>Nothing reaches <code>main</code> until a <em>different</em> model adversarially reviews it and returns <code>APPROVE</code>.</strong>
</p>

<p align="center">
  <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue.svg">
  <img alt="Reviewer: pluggable" src="https://img.shields.io/badge/reviewer-pluggable-6f42c1.svg">
  <img alt="Coder: pluggable" src="https://img.shields.io/badge/coder-pluggable-6f42c1.svg">
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

# 3. Install the gates into a repo you want protected (descendant guard +
#    coder-agnostic review-receipt gate).
/path/to/adversarial-review-loop/setup.sh <your-repo>

# 4. Author with anything (Claude Code, Cursor, Aider, a human…). Before pushing,
#    record a review — review-gate.sh runs the fan-out and writes the receipt:
cd <your-repo>
ARL_REVIEW_HOST=<host-where-codex-lives> /path/to/adversarial-review-loop/review-gate.sh main
#   all three lenses APPROVE → receipt written → git push   (the gate lets it through)
#   any REJECT               → read the lens logs, fix, re-run. Repeat.
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
| `review-gate.sh` | **Coder-agnostic runner.** Reviews `HEAD` vs base with the fan-out and, on a unanimous APPROVE, writes a per-commit receipt. Any author runs this, then pushes. |
| `fanout-review.sh` | The 3-lens parallel review (correctness / data / ui). APPROVE iff all three approve. |
| `mcp/` | `codex-review-mcp` — an **async** MCP wrapper around `codex exec` (the reference reviewer adapter). Start→poll so long reviews survive the tool-call timeout; ChatGPT-account safe; surfaces the reviewer's real errors. |
| `hooks/pre-push` | The pre-push **dispatcher** installed by `setup.sh` — runs both gates below. |
| `hooks/pre-push-main-guard.sh` | Git pre-push gate: refuses pushes to `main` that aren't descendants of `origin/main`. |
| `hooks/pre-push-review-gate.sh` | Git pre-push gate (**coder-agnostic**): refuses pushes to `main` without an APPROVE receipt for the pushed commit — enforces the loop for *any* author. |
| `hooks/require-review.py` | Optional **Claude Code transcript gate**: a PreToolUse hook that blocks a push when the session shows no APPROVE review. It does *not* write receipts — pair it with `setup.sh --no-review`, or just run `review-gate.sh`. |
| `setup.sh` | Installs the gates into a repo (honors `core.hooksPath`; `--no-review` for the guard only). |
| `docs/protocol.md` | The protocol: the two pluggable axes, why fan out, the aggregation rule, the loop, operational gotchas. |
| `docs/install.md` | **Full step-by-step setup** — prerequisites, MCP registration (local & remote), gates, the fan-out, and a copy-pasteable end-to-end walkthrough. |
| `examples/CLAUDE.md.example` | A drop-in review convention for your repo's `CLAUDE.md`. |

## Scope

This is the **review loop**, not a deployment system. It ends at the gated
`git push` to `main`; wire your own build/ship to trigger after that. The one
guarantee it makes: nothing lands on `main` without an independent APPROVE.

## Both ends are pluggable

The whole design rests on the author and reviewer being **two independent
models** — so neither end is hard-wired.

**Swap the reviewer.** The only contract is "a different model that ends its
review with a `VERDICT: APPROVE` / `VERDICT: REJECT — <reason>` line." This repo
ships **Codex as the reference reviewer** (a strong, independent model you can run
on a ChatGPT subscription with no API cost). To swap it, point `fanout-review.sh`
at a different CLI (keep the `VERDICT:` last-line contract) and/or add an MCP
adapter alongside `mcp/`.

**Swap the coder.** Enforcement does **not** depend on who or what wrote the code.
The pre-push gate (`hooks/pre-push-review-gate.sh`) only checks for an APPROVE
**receipt** bound to the exact commit being pushed. Any author — Claude Code,
Cursor, Aider, Codex-as-coder, another agent, or a human — produces that receipt
the same way:

```sh
review-gate.sh main      # reviews HEAD, writes the receipt on a clean sweep
```

Because the receipt is written for the reviewed `HEAD` and the gate matches it to
the pushed commit SHA, amending or adding commits after a review invalidates it —
you review exactly what you push.

`hooks/require-review.py` is an **optional** Claude Code extra: a PreToolUse hook
that blocks a push if the current session shows no APPROVE review. It is a
*transcript gate only* — it deliberately does **not** write receipts (a
transcript APPROVE can't be soundly bound to the current commit), so use it with
`setup.sh --no-review` for transcript-based gating, or just run `review-gate.sh`.

## License

MIT — see [LICENSE](LICENSE).

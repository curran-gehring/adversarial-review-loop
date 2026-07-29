<h1 align="center">adversarial-review-loop</h1>

<p align="center">
  <strong>Nothing reaches <code>main</code> until an <em>independent</em> reviewer adversarially checks it and returns <code>APPROVE</code>.</strong>
</p>

<p align="center">
  <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue.svg">
  <img alt="Author: pluggable" src="https://img.shields.io/badge/author-pluggable-6f42c1.svg">
  <img alt="Reviewer: pluggable" src="https://img.shields.io/badge/reviewer-pluggable-6f42c1.svg">
  <img alt="Philosophy: quality over quantity" src="https://img.shields.io/badge/philosophy-quality%20%3E%20quantity-2ea44f.svg">
</p>

```
  ┌─────────────────┐    diff     ┌────────────────────────────────┐
  │     author      │ ──────────▶ │  independent reviewer (fan-out) │
  │ (any tool/human)│             │   correctness │ data │ ui       │
  └─────────────────┘             └───────────────┬────────────────┘
        ▲                                          │ 3 × VERDICT lines
        │  REJECT → fix & re-run                   ▼
        │                             APPROVE iff ALL THREE approve
        └──────────────────────────────────────────┤
                                                    ▼  APPROVE
                                              git push → main
                                              (pre-push gate verifies)
```

There are two roles, and **both are pluggable**:

- **author** — whatever writes the change: an agent (Claude Code, Cursor, Aider,
  a Codex coder), or a human in an editor.
- **reviewer** — a *different* model that adversarially reviews the diff and emits
  a `VERDICT:` line.

The repo doesn't care which tools fill those roles. It enforces the *loop* — an
independent APPROVE before anything lands on `main` — not a particular vendor on
either side. The default fan-out uses the opposite model family from the primary
coder: Claude-primary work routes to Codex reviewers; Codex-primary work routes
to Claude reviewers.

---

## This is not a "10× your output" hack

Most AI-coding tools and templates sell you **speed**: more code, more PRs, more
velocity, "ship 10× faster." This one sells the opposite, on purpose.

Here an independent reviewer has to find **nothing wrong** before anything lands on
`main`. That makes building **slower** — there's a review gate and a
fix-until-approved loop standing between you and every merge. You will write less
code per day.

What you get back:

- **Correctness at "done."** When a change merges, it has survived a reviewer that
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

## How it enforces the loop (and why that makes it agnostic)

Enforcement is a **git pre-push gate** that checks for a per-commit APPROVE
**receipt** — it never inspects the author's editor or transcript. That's the
whole reason the author side is pluggable:

1. The author writes a change (any tool, any human).
2. `review-gate.sh` reviews the exact commit, and on a unanimous APPROVE writes a
   receipt bound to that commit SHA.
3. `git push` to `main` is allowed only if the pushed commit has a valid receipt.

Swap either side freely:

- **Swap the author** — nothing to configure. Whatever produced the commit, run
  `review-gate.sh <base>` before pushing. (Claude Code can also use the optional
  `require-review.py` transcript gate as an in-session backstop.)
- **Swap the reviewer** — the only contract is "a different model that ends its
  review with `VERDICT: APPROVE` / `VERDICT: REJECT — <reason>`." Point
  `fanout-review.sh` at a different CLI, or add an MCP adapter alongside `mcp/`.

Because the receipt is bound to the reviewed commit (and its base), amending or
adding commits after a review invalidates it — you review exactly what you push.

## Quickstart

> Uses the model-aware default: set `ARL_PRIMARY_MODEL=claude` for Codex
> reviewers, or `ARL_PRIMARY_MODEL=codex` for Claude reviewers.

```sh
# 1. Bring up a reviewer. Reference: the Codex CLI (a ChatGPT account is fine).
npm install -g @openai/codex && codex login
echo hi | codex exec -s read-only --skip-git-repo-check "reply exactly: VERDICT: APPROVE"

# 2. Get the toolkit and install the gates into a repo you want protected
#    (descendant guard + author-agnostic review-receipt gate).
git clone https://github.com/curran-gehring/adversarial-review-loop
adversarial-review-loop/setup.sh <your-repo>

# 3. Author with ANYTHING. Before pushing, record a review of your change:
cd <your-repo>
ARL_REVIEW_HOST=<host-where-the-reviewer-runs> /path/to/adversarial-review-loop/review-gate.sh main
#   all three lenses APPROVE → receipt written → git push   (the gate lets it through)
#   any REJECT               → read the lens logs, fix, re-run. Repeat.
```

Full setup (the optional MCP wrapper for agent authors, the remote/SSH shape,
troubleshooting): **[`docs/install.md`](docs/install.md)** · The protocol and its
rationale: **[`docs/protocol.md`](docs/protocol.md)**.

## Reference setup: opposite-model reviewers

The configuration this repo ships with and uses on itself:

- **Claude primary:** reviewers are Codex (`@openai/codex`) in a 3-lens fan-out.
  Codex runs on the ChatGPT subscription path.
- **Codex primary:** reviewers are Claude (`claude -p`) in a 3-lens fan-out.
  Claude runs only on the Claude Code subscription path. The fan-out never passes
  `--bare`, never sets `ANTHROPIC_API_KEY`, and scrubs any inherited
  `ANTHROPIC_API_KEY` from reviewer subprocesses.

Every component is replaceable: a human author needs only `review-gate.sh`; a
different reviewer needs only to honor the `VERDICT:` contract.

## What's in the box

| Path | What it is |
|---|---|
| `review-gate.sh` | **Author-agnostic runner.** Reviews `HEAD` vs base with the fan-out and, on a unanimous APPROVE, writes a per-commit receipt. Any author runs this, then pushes. |
| `fanout-review.sh` | Model-aware 3-lens parallel review (correctness / data / ui). Claude primary → Codex fan-out; Codex primary → Claude fan-out. APPROVE iff all three approve. |
| `claude-fanout-review.sh` | Subscription-only Claude reviewer fan-out used when Codex is the primary coder. Scrubs `ANTHROPIC_API_KEY` and never uses `--bare`. |
| `mcp/` | `codex-review-mcp` — an **async** MCP wrapper around `codex exec` (the reference reviewer adapter). Start→poll so long reviews survive the tool-call timeout; ChatGPT-account safe; surfaces the reviewer's real errors. |
| `hooks/pre-push` | The pre-push **dispatcher** installed by `setup.sh` — runs both gates below. |
| `hooks/pre-push-main-guard.sh` | Git pre-push gate: refuses pushes to `main` that aren't descendants of `origin/main`. |
| `hooks/pre-push-review-gate.sh` | Git pre-push gate (**author-agnostic**): refuses pushes to `main` without a valid APPROVE receipt for the pushed commit — enforces the loop for *any* author. |
| `hooks/require-review.py` | Optional **Claude Code transcript gate**: a PreToolUse hook that blocks a push when the session shows no APPROVE review. It does *not* write receipts — pair it with `setup.sh --no-review`, or just run `review-gate.sh`. |
| `setup.sh` | Installs the gates into a repo (honors `core.hooksPath`; `--no-review` for the guard only). |
| `docs/protocol.md` | The protocol: the two pluggable roles, why fan out, the aggregation rule, the loop, operational gotchas. |
| `docs/install.md` | **Full step-by-step setup** — prerequisites, MCP registration (local & remote), gates, the fan-out, and a copy-pasteable end-to-end walkthrough. |
| `examples/CLAUDE.md.example` | A drop-in review convention for a Claude Code author's `CLAUDE.md`. |

## Scope

This is the **review loop**, not a deployment system. It ends at the gated
`git push` to `main`; wire your own build/ship to trigger after that. The one
guarantee it makes: nothing lands on `main` without an independent APPROVE.

## License

MIT — see [LICENSE](LICENSE).

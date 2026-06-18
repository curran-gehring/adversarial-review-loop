# The review-loop protocol

The pipeline is a single rule with a backstop:

> **No change reaches `main` until an independent adversarial reviewer
> returns `VERDICT: APPROVE`.**

The author of the change is one model (e.g. Claude, via Claude Code). The
reviewer is a **different** model (Codex), so it reviews with a fully
independent chain-of-thought — it doesn't share the author's blind spots.

```
  ┌────────────┐     diff      ┌──────────────────────────────┐
  │  author    │ ────────────▶ │  Codex fan-out (3 lenses)    │
  │ (Claude)   │               │  correctness │ data │ ui     │
  └────────────┘               └──────────────┬───────────────┘
        ▲                                      │
        │  REJECT — fix & re-run               │  3 × VERDICT lines
        │                                      ▼
        │                         APPROVE iff ALL THREE approve
        │                                      │
        └──────────────────────────────────────┤
                                                ▼  APPROVE
                                          git push → main
                                          (pre-push gate verifies)
```

## Why fan out into 3 lenses

A single broad `codex exec` over a diff wanders into unrelated files and takes
30–45 min. Three **scoped** workers, each told to read *only* the files the diff
touches, are faster and catch more because each has one job:

- **correctness** — logic/ordering bugs, boundaries, races, threading/async,
  lifecycle, null/crash paths, leaks and reference cycles, error handling.
- **data** — SQL & schema, migrations, sync/record round-trips,
  serialization/parsing, units & coordinate math, set/index/dedupe logic.
- **ui** — view/component state, list/key identity, framework/API validity for
  the target platform, reuse/duplication, no regressions to unrelated surfaces.

Tune the lens prompts in `fanout-review.sh` to your stack.

## The aggregation rule

Each lens ends its log with exactly one line:

```
VERDICT: APPROVE
```
or
```
VERDICT: REJECT -- <one-line reason>
```

**Aggregate: APPROVE iff all three say APPROVE; REJECT if any one does.** Collect
the union of findings from the rejecting lenses. Then emit a single final
`VERDICT:` line (this is what the pre-push gate keys on).

## The loop

1. Produce the diff: `git diff main...HEAD > /tmp/review.diff`.
2. Run the fan-out against it.
3. Read the three lens logs; aggregate.
4. **REJECT** → fix the blockers, regenerate the diff, run the fan-out again.
   Repeat. Don't argue with a rejection — either fix it, or explain to the user
   why the reviewer is wrong and ask for guidance.
5. **APPROVE** → push to `main`.

## Operational notes (learned the hard way)

- **One diff at a time.** A ChatGPT-subscription Codex contends badly with more
  than ~3 concurrent workers, so parallelize the *3 lenses of one diff*, not
  multiple diffs at once.
- **Re-run a stalled lens solo.** If a lens dies on a transient
  `ERROR: Reconnecting...` or returns the banner with no response, re-run that
  one lens by itself rather than blocking the whole review.
- **Keep the reviewer independent.** Don't substitute author-family subagents
  for Codex — same model family means shared blind spots, which defeats the
  point.
- **APPROVE is not "it compiles".** Codex reviews read-only and can't build your
  project. If a green build matters, gate it separately in CI; treat a red build
  like a REJECT.

## Two ways to run the reviewer

- **MCP (no shell needed):** the async wrapper in `mcp/` exposes
  `codex_review_start` / `codex_review_poll`, so a sandboxed Claude client with
  no shell can still drive a review. Long reviews survive the tool-call timeout.
- **Shell (`codex exec` directly):** when a shell is available, `fanout-review.sh`
  is the fastest path. Pipe the diff to stdin; read the lens logs.

## Enforcement is coder-agnostic (receipts)

Both ends of the loop are pluggable — the reviewer (which model reviews) **and**
the coder (which tool, agent, or human writes the code). The reviewer is
swappable because the only contract is the `VERDICT:` line. The **coder** is
swappable because enforcement never reads the author's harness; it checks a
**receipt**:

- `review-gate.sh` runs the fan-out, and on a unanimous APPROVE writes
  `$GIT_DIR/adversarial-review/<sha>` (first line `APPROVE`) for the current
  `HEAD`.
- The pre-push gate `hooks/pre-push-review-gate.sh` lets a push to the protected
  branch through **only** if the commit being pushed has such a receipt.

Because the receipt is keyed to the commit SHA, amending or adding commits after
a review invalidates it — you review exactly what you push. The receipt lives
under `$GIT_DIR` (never committed); the gate is a local guardrail, not a
cryptographic boundary (`ARL_SKIP_REVIEW=1` bypasses it deliberately).

**Producing a receipt** — every coder uses the same command:

| Coder | How the receipt gets written |
|---|---|
| Claude Code / Cursor / Aider / Codex-as-coder / any agent / a human | run `review-gate.sh <base>` before pushing (Claude Code can run it in-session as its review step). |

`hooks/require-review.py` is an optional Claude-Code-only *transcript gate*: a
PreToolUse hook that blocks a push when the session shows no APPROVE review. It
does **not** write receipts — a transcript APPROVE can't be soundly bound to the
current commit (you might amend after the review), and certifying that as a
receipt would let unreviewed content through. Pair it with `setup.sh --no-review`
if you want transcript-based gating instead of the receipt gate.

See [`install.md`](install.md) for wiring.

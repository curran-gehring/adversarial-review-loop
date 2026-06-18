# Setup guide

Stand up the full review loop — author with any tool, gate every push to `main`
on an independent Codex adversarial review — from zero. Follow top to bottom.

There are two deployment shapes; pick one and the steps tell you where they
differ:

- **Local** — Codex runs on the same machine you author on.
- **Remote** — Codex runs on another host (e.g. a Mac for `codex`/macOS tooling)
  that you reach over SSH. We'll call its hostname `REVIEW_HOST` throughout;
  substitute your own (an `~/.ssh/config` alias is easiest).

---

## 1. Prerequisites

On the machine where **Codex** runs (local or `REVIEW_HOST`):

1. **Install the Codex CLI** (`@openai/codex`):
   ```sh
   npm install -g @openai/codex
   codex --version
   ```
2. **Log in:**
   ```sh
   codex login
   ```
   - **ChatGPT subscription** (the default, no API cost): log in with your
     ChatGPT account. This account type **rejects `--model gpt-5-codex`**, which
     is exactly why this toolkit never passes `--model` by default. Leave model
     selection to the account default.
   - **API key**: if you authenticate with an API key that supports a specific
     model, you *may* pass `model:` to the MCP tools or edit `fanout-review.sh`.
     Otherwise omit it.
3. Confirm a trivial review works end to end:
   ```sh
   echo "say nothing else, output exactly: VERDICT: APPROVE" \
     | codex exec -s read-only --skip-git-repo-check "Emit only the requested line."
   ```

On the machine you **author** on:

- **git**, and **bash** (for `review-gate.sh` / the hooks).
- **Node ≥ 18** if you use the MCP wrapper (`node --version`).
- **Python 3** only if you use the Claude Code adapter (`require-review.py`).
- Your coder of choice — Claude Code, Cursor, Aider, another agent, or just you.

---

## 2. Get this toolkit

Clone it onto the machine where **Codex** runs (the MCP server and
`fanout-review.sh` both call `codex`, so they live next to it). For the local
shape that's the same machine as Claude Code.

```sh
git clone <this-repo-url> adversarial-review-loop
cd adversarial-review-loop/mcp
npm install
npm run selftest      # pure-parser unit tests; should print "ALL PASS"
```

If `codex` is on PATH, also run the end-to-end check:

```sh
node mcptest.mjs      # spawns the server, runs a trivial review → "MCP E2E OK"
```

---

## 3. Register the MCP server in Claude Code

The MCP wrapper lets Claude drive long reviews (`codex_review_start` →
`codex_review_poll`) without hitting the synchronous tool-call timeout, and works
even from a shell-less / sandboxed client.

### Local shape

```sh
claude mcp add codex-review -- node /ABS/PATH/TO/adversarial-review-loop/mcp/server.mjs
```

Or add it by hand to your Claude Code MCP config:

```json
{
  "mcpServers": {
    "codex-review": {
      "command": "node",
      "args": ["/ABS/PATH/TO/adversarial-review-loop/mcp/server.mjs"]
    }
  }
}
```

### Remote shape (Codex on REVIEW_HOST)

Run the server *on the remote host* by making the command SSH there:

```json
{
  "mcpServers": {
    "codex-review": {
      "command": "ssh",
      "args": ["REVIEW_HOST", "node", "/ABS/PATH/ON/REMOTE/adversarial-review-loop/mcp/server.mjs"]
    }
  }
}
```

Requirements for the remote shape: key-based SSH to `REVIEW_HOST` (no password
prompt), and `node` + `codex` on the **remote** PATH for non-interactive SSH
sessions (put them in `~/.zshenv` / `~/.bashrc` as needed).

Restart Claude Code and confirm the `codex_review_*` tools are listed.

> Job state is written under `~/.codex-review-mcp/jobs` on the Codex host.
> Override with the `CODEX_REVIEW_JOBS_DIR` env var if needed.

---

## 4. Install the gates (one command)

`setup.sh` installs a pre-push hook into a repo you want protected. By default it
installs **both** gates as a dispatcher:

- `pre-push-main-guard.sh` — refuses pushes to `main` that aren't descendants of
  `origin/main` (no clobbering with a stale base).
- `pre-push-review-gate.sh` — **coder-agnostic**: refuses pushes to `main` unless
  the commit being pushed has an APPROVE **receipt**. This is what enforces the
  review loop regardless of who or what authored the code.

```sh
/ABS/PATH/TO/adversarial-review-loop/setup.sh <your-repo>
#   --no-review   install only the descendant guard
```

It honors `core.hooksPath` (incl. a relative one, resolved against the worktree
root), backs up any existing `pre-push` under a unique name, and never writes
through a symlink. Re-running is safe.

Escape hatches (env vars read by the review gate):
`ARL_PROTECTED_BRANCH` (default `main`) · `ARL_SKIP_REVIEW=1` (bypass — say why).

---

## 5. Author with anything, then record a review

The gate checks a receipt, not your editor — so **any** coder works: Claude Code,
Cursor, Aider, Codex-as-coder, another agent, or a human. Before pushing to
`main`, record a review with `review-gate.sh`:

```sh
cd <your-repo>
# Local reviewer:
/ABS/PATH/TO/adversarial-review-loop/review-gate.sh main
# Remote reviewer (Codex on another host):
ARL_REVIEW_HOST=REVIEW_HOST /ABS/PATH/TO/adversarial-review-loop/review-gate.sh main
```

It diffs `main...HEAD`, runs the 3-lens fan-out, prints each lens's verdict, and
**on a unanimous APPROVE writes the receipt** for the current `HEAD`
(`$GIT_DIR/adversarial-review/<sha>`). On any REJECT it writes nothing and exits
non-zero. The lens logs are persisted to
`$GIT_DIR/adversarial-review/last-review/fan.{correctness,data,ui}.log` — read the
findings there, fix, and re-run.

Local vs remote: **local** mode lets the reviewer open full source files for
surrounding context; **remote** (`ARL_REVIEW_HOST`) is **diff-scoped** — only the
unified diff is sent to the review host, so the reviewer judges the
(self-contained) diff, not a checkout.

### Claude Code adapter (optional transcript gate)

If you author with Claude Code, you can register `require-review.py` as a
PreToolUse hook. It blocks any `git push` reaching `main` when the current session
shows no APPROVE review — a fast, in-session backstop. It is a **gate only**: it
does NOT write a receipt (a transcript APPROVE can't be soundly bound to the
commit you end up pushing). So either pair it with `setup.sh --no-review` (gate by
transcript instead of receipt), or keep the receipt gate and still run
`review-gate.sh` to produce the receipt. This toolkit's own `.claude/settings.json`
is exactly this block:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/hooks/require-review.py\""
          }
        ]
      }
    ]
  }
}
```

On Windows use `python` if that's your launcher. The hook falls open (allows the
push) only when it genuinely can't see the transcript; the git receipt gate from
step 4 remains the hard backstop.

---

## 6. The fan-out, directly (optional)

`review-gate.sh` wraps the fan-out for you. To run it on its own:

```
fanout-review.sh <diff_path> <out_prefix> ["extra context"] [repo_dir]
```

- `diff_path` — the unified diff to review.
- `out_prefix` — log prefix; produces `<out_prefix>.{correctness,data,ui}.log`.
- `extra context` — optional one-line description appended to each lens prompt.
- `repo_dir` — repo root so Codex can read source (defaults to the current dir).

Edit the lens prompts (`C`, `D`, `U`) and `RULES` at the top to match your stack —
the defaults are language-agnostic but you can sharpen them.

---

## 7. End-to-end walkthrough

From a feature branch with changes ready for `main`:

```sh
# 1. Review HEAD and record the receipt on a clean sweep.
ARL_REVIEW_HOST=REVIEW_HOST /ABS/PATH/TO/adversarial-review-loop/review-gate.sh main
#   prints each lens verdict, then:
#     VERDICT: APPROVE  + "receipt recorded …"   → proceed
#     VERDICT: REJECT   → fix, re-run (no receipt written)

# 2. Push. The pre-push dispatcher runs the descendant guard AND the receipt
#    gate; both pass because the receipt matches HEAD.
git push origin main
```

If you amend or add commits after the review, the SHA changes and the receipt no
longer matches — re-run `review-gate.sh`. That's intended: you review exactly what
you push.

> Driving this from Claude Code: Claude runs `review-gate.sh` as its review step
> (it can call it directly), fixes on REJECT, and on a clean sweep the receipt is
> written — then the plain `git push` sails through the same gate every other
> coder uses. The optional `require-review.py` transcript gate is a separate,
> in-session backstop; it does not replace the receipt.

---

## 8. Bring your own ship step

This toolkit deliberately ends at the **gated `git push` to `main`**. What
happens after — building artifacts, deploying, releasing — is yours to wire:
trigger your CI/CD on push to `main`, or run a deploy after the push succeeds.
The contract this toolkit guarantees is simply that nothing reaches `main`
without an APPROVE.

---

## Troubleshooting

- **Push blocked with "Review missing"** — you pushed to `main` without a review
  in the recent transcript. Run the fan-out (or MCP review) first.
- **`gpt-5-codex ... not supported`** — you passed a `model:` on a ChatGPT
  account. Omit it.
- **A lens log ends with `ERROR: Reconnecting...` or just the banner** —
  transient throttle; re-run that single lens solo.
- **MCP tools not visible in Claude Code** — check the absolute path in the
  config, restart Claude Code, and (remote shape) confirm passwordless SSH and a
  remote PATH that includes `node` and `codex`.
- **`npm run selftest` fails** — that's a pure-parser regression; the wrapper is
  broken independent of Codex. File it before going further.

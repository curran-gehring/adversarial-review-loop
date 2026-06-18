# Setup guide

Stand up the full review loop — author with Claude, gate every push to `main` on
an independent Codex adversarial review — from zero. Follow top to bottom.

There are two deployment shapes; pick one and the steps tell you where they
differ:

- **Local** — Codex and Claude Code run on the same machine.
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

On the machine where **Claude Code** runs:

- **Node ≥ 18** (`node --version`) and **git**.
- **Python 3** (for the pre-push gate hook).
- **Claude Code** installed and working.

---

## 2. Get this toolkit

Clone it onto the machine where **Codex** runs (the MCP server and
`fanout-review.sh` both call `codex`, so they live next to it). For the local
shape that's the same machine as Claude Code.

```sh
git clone <this-repo-url> codex-review-loop
cd codex-review-loop/mcp
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
claude mcp add codex-review -- node /ABS/PATH/TO/codex-review-loop/mcp/server.mjs
```

Or add it by hand to your Claude Code MCP config:

```json
{
  "mcpServers": {
    "codex-review": {
      "command": "node",
      "args": ["/ABS/PATH/TO/codex-review-loop/mcp/server.mjs"]
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
      "args": ["REVIEW_HOST", "node", "/ABS/PATH/ON/REMOTE/codex-review-loop/mcp/server.mjs"]
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

## 4. Install the pre-push gate (git hook)

This refuses any push to `main` whose local HEAD isn't a descendant of
`origin/main` — it stops you from clobbering `main` with a stale base. Install it
**per repo** you want protected:

```sh
cp /ABS/PATH/TO/codex-review-loop/hooks/pre-push-main-guard.sh \
   <your-repo>/.git/hooks/pre-push
chmod +x <your-repo>/.git/hooks/pre-push
```

(To protect every clone automatically, set `git config --global core.hooksPath`
to a directory containing this file — but note that overrides per-repo hooks.)

---

## 5. Install the review gate (Claude Code PreToolUse hook)

`hooks/require-review.py` is the backstop that enforces the protocol: before any
`git push` reaching `main`, it scans the session transcript for a recent review
whose result carries `VERDICT: APPROVE`. No review / a REJECT / a review still in
flight → it blocks the push (exit 2). It recognizes the `ask-codex` MCP tool,
this repo's `codex_review_poll`, a general-purpose `Agent` review, and a direct
`codex exec` run via Bash. A bare `echo "VERDICT: APPROVE"` does **not** satisfy
it — the verdict must come from reading Codex's own output.

Register it in your Claude Code `settings.json` (user-level or the project's
`.claude/settings.json`):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 /ABS/PATH/TO/codex-review-loop/hooks/require-review.py"
          }
        ]
      }
    ]
  }
}
```

On Windows use `python` (not `python3`) if that's your launcher. The hook reads
the Claude Code hook payload on stdin and falls open (allows the push) only when
it genuinely can't see the transcript.

---

## 6. Install the fan-out script

On the Codex host, make it executable and put it somewhere convenient:

```sh
chmod +x /ABS/PATH/TO/codex-review-loop/fanout-review.sh
```

Usage:

```
fanout-review.sh <diff_path> <out_prefix> ["extra context"] [repo_dir]
```

- `diff_path` — the unified diff to review.
- `out_prefix` — log path prefix; produces
  `<out_prefix>.correctness.log`, `.data.log`, `.ui.log`.
- `extra context` — optional one-line description appended to each lens prompt.
- `repo_dir` — repo root so Codex can read source (defaults to the current dir).

Edit the three lens prompts (`C`, `D`, `U`) and `RULES` at the top of the script
to match your stack — the defaults are language-agnostic but you can sharpen them
(e.g. name your concurrency primitives or framework).

---

## 7. End-to-end walkthrough

From inside a feature branch with changes ready for `main`:

```sh
# 1. Capture the diff against main.
git diff main...HEAD > /tmp/review.diff

# 2. Fan out the 3-lens review.
#    Local: run directly. Remote: scp the diff over first, then ssh.
/ABS/PATH/TO/codex-review-loop/fanout-review.sh \
    /tmp/review.diff /tmp/review-fan "short context for this change" "$PWD"
#  ... prints FANOUT_DONE when all three lenses finish.

# 3. Read the verdicts.
grep -h '^VERDICT:' /tmp/review-fan.correctness.log \
                    /tmp/review-fan.data.log \
                    /tmp/review-fan.ui.log
```

**Remote variant** of step 2:

```sh
scp /tmp/review.diff REVIEW_HOST:/tmp/review.diff
ssh REVIEW_HOST '/ABS/PATH/ON/REMOTE/fanout-review.sh /tmp/review.diff /tmp/review-fan "short context" /path/to/repo/on/remote'
ssh REVIEW_HOST "grep -h '^VERDICT:' /tmp/review-fan.{correctness,data,ui}.log"
```

**Aggregate and act:**

- All three `VERDICT: APPROVE` → push:
  ```sh
  git push origin main          # the pre-push gate + review gate both pass
  ```
- Any `VERDICT: REJECT` → read that lens's full log for the findings, **fix
  them**, then loop back to step 1. Re-run until all three approve. A single
  rejection means the change isn't ready — don't push around it.

> Driving this from Claude Code: Claude produces the diff, runs the fan-out (or
> the MCP `codex_review_start`/`codex_review_poll` tools), aggregates, fixes on
> REJECT, and only then runs `git push`. The PreToolUse gate from step 5 is the
> safety net if the convention is ever skipped.

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

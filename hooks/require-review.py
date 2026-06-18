#!/usr/bin/env python3
"""PreToolUse hook: enforce adversarial review before pushing to main.

Reads the Claude Code hook payload on stdin, inspects the proposed
Bash command, and — if it's a `git push` that would reach `main` —
scans the session transcript for a recent adversarial review whose
result carries a `VERDICT: APPROVE` line. Four review shapes are
accepted (whichever is newest wins):
  1. An `ask-codex` MCP tool — verdict in the tool's own result.
  2. The async codex-review wrapper (this repo's
     `mcp__codex-review__codex_review_poll`, or any connector whose
     tool name ends `__codex_review_poll`) — start→poll split, verdict
     in the `codex_review_poll` result once the review finishes.
  3. A general-purpose `Agent` review — verdict in its result /
     `<task-notification>`.
  4. A direct `codex exec` review run via Bash (the working path when an
     MCP connector injects an unsupported `--ask-for-approval` flag and
     errors out — and the documented preference when a shell exists).
     Recognized by an actual `codex exec` invocation in the window PLUS
     a codex-derived Bash result carrying the VERDICT line (the `grep`
     of the codex log).
If a review's result is APPROVE, the push is allowed. Any other state
(REJECT verdict, review still in flight, no review at all) blocks with
exit 2 and a remediation message.

Falls open (exit 0) when:
  - The proposed command isn't `git push` reaching main
  - The payload doesn't expose a transcript path (can't enforce
    what the hook can't see)
  - The transcript file is unreadable

`git push` shapes that reach main:
  - Explicit refspec: `git push origin main`, `git push origin
    HEAD:main`, `git push origin +main`
  - Bare push from main branch: `git push`, `git push origin`,
    `git push origin HEAD`, `git push -u origin HEAD`
The hook consults `git rev-parse --abbrev-ref HEAD` to detect the
bare-push cases without false-flagging feature-branch pushes.
"""
import json
import os
import re
import subprocess
import sys

# How many records back to scan. A non-trivial fix iteration easily
# produces 100+ records (each tool call = 2 records), so 30 was way too
# small. 250 covers a full review-fix loop comfortably.
RECENT_RECORD_WINDOW = 250

# Verdict line shape. Anchored to the beginning of a line (so verdict
# words inside file contents the reviewer Read'd as part of its review
# don't false-match) and captures the decision token.
VERDICT_LINE_RE = re.compile(
    r"^[ \t]*VERDICT[ \t]*:[ \t]*(APPROVE|REJECT)\b",
    re.IGNORECASE | re.MULTILINE,
)

# A real `codex exec` review invocation in a Bash command. The read-only /
# skip-git flag must appear in the FLAG region — before the first quote, i.e.
# before the prompt payload — so `-s read-only` sitting inside a quoted prompt
# (`codex exec "...use -s read-only..."`) does NOT qualify. The `[^"']*?`
# (not `.*?`) is what enforces "before any quote".
CODEX_EXEC_RE = re.compile(
    r"\bcodex\s+exec\b[^\"']*?(?:-s\s+read-only|--sandbox[ =]+read-only|--skip-git-repo-check)",
    re.IGNORECASE,
)
# The verdict is bound to the ACTUAL log file the `codex exec` dispatch wrote
# to: a verdict only counts when a read/extract command reads THAT dispatch's
# own log, AFTER the dispatch. So a fake log, a "codex" in a comment, or a
# stale read of a different/older log can't satisfy the gate.
#  - _REDIRECT_RE pulls the `> file` / `>> file` targets from the dispatch
#    command (ignoring `2>&1`-style fd dups, whose target starts with `&`).
#  - _READ_VERB_RE confirms the verdict-bearing command actually reads a file.
_REDIRECT_RE = re.compile(r"(?:^|[\s|;&])\d*>>?\s*([^\s'\"&|;()<>]+)")
_READ_VERB_RE = re.compile(
    r"\b(?:grep|egrep|rg|cat|tail|head|awk|sed|less|more)\b", re.IGNORECASE
)

# Verdict line as it appears in a `grep` of the codex log: codex's REAL
# verdict is the LAST `VERDICT:` line (the early ones are the prompt echo),
# and `grep -n` prefixes it with a line number / filename (`29:` or
# `/tmp/codex_review.log:29:`). So allow leading `token:` prefixes and take
# the last match. Stricter `VERDICT_LINE_RE` (no prefix) stays for the MCP
# path, where the verdict is a clean final line. The caller already gates
# this to results whose command reads codex output, so the looser prefix
# can't be reached by arbitrary text.
CODEX_VERDICT_RE = re.compile(
    r"(?:^|\n)[ \t]*(?:[^\s:]+:[ \t]*)*VERDICT[ \t]*:[ \t]*(APPROVE|REJECT)\b",
    re.IGNORECASE,
)

# When an Agent is launched with run_in_background=True, its result
# does NOT come back as a `tool_result` block. Instead the harness
# injects a `<task-notification>` XML chunk into a subsequent user
# message. We parse it to recover the (tool_use_id, status, result)
# triple so async-agent verdicts are visible to the gate, not just
# synchronous ones. DOTALL so `<result>` content can span newlines.
TASK_NOTIFICATION_RE = re.compile(
    r"<task-notification>(?P<body>.*?)</task-notification>",
    re.DOTALL | re.IGNORECASE,
)
TASK_TOOL_USE_ID_RE = re.compile(r"<tool-use-id>\s*([^<\s]+)\s*</tool-use-id>", re.IGNORECASE)
TASK_STATUS_RE      = re.compile(r"<status>\s*([^<\s]+)\s*</status>", re.IGNORECASE)
TASK_RESULT_RE      = re.compile(r"<result>(.*?)</result>", re.DOTALL | re.IGNORECASE)


def _load_payload():
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


# ──────────────────────────────────────────────────────────────────
# Push-target classification
# ──────────────────────────────────────────────────────────────────

def _on_main_branch() -> bool:
    """Best-effort: is the working tree currently on `main`?
    Returns False on any error so we don't false-block when git
    isn't available or the cwd isn't a repo."""
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        return r.returncode == 0 and r.stdout.strip() == "main"
    except Exception:
        return False


def _command_pushes_to_main(cmd: str) -> bool:
    """Returns True iff the bash command-line attempts to push to
    main. Handles compound commands (`a && git push origin main`)
    and the four common idioms enumerated at module top."""
    if not cmd:
        return False
    # For each `git push <args>` segment in the compound command,
    # decide if its args reach main. We have to walk segment-by-
    # segment because `git push origin claude/foo && git push
    # origin main` should match.
    push_re = re.compile(r"\bgit\s+push\b((?:\s+[^\s;&|()]+)*)")
    for m in push_re.finditer(cmd):
        if _push_args_target_main(m.group(1)):
            return True
    return False


def _push_args_target_main(args_str: str) -> bool:
    """Inspect the args after `git push` and decide if they target
    main."""
    args = re.split(r"\s+", args_str.strip()) if args_str.strip() else []
    positional = [a for a in args if not a.startswith("-")]

    # Case 1: bare `git push` — uses upstream of current branch.
    if not positional:
        return _on_main_branch()

    # Case 2: only a remote name (`git push origin`) — same as bare.
    if len(positional) == 1:
        return _on_main_branch()

    # Case 3: explicit refspec(s).
    for arg in positional[1:]:
        # Strip force prefix.
        ref = arg.lstrip("+")
        # `local:remote` → take remote side. Bare `local` → push
        # local with same name.
        if ":" in ref:
            local_side, remote_side = ref.split(":", 1)
            target = remote_side
            local = local_side
        else:
            target = ref
            local = ref
        # Match exactly `main` or `refs/heads/main` on the target
        # side. Reject `main-2`, `feature/main`, etc.
        if target in ("main", "refs/heads/main"):
            return True
        # `HEAD` or `HEAD:main` — pushing HEAD when HEAD is main.
        if local == "HEAD" and (target == "HEAD" or target in ("main", "refs/heads/main")):
            if _on_main_branch():
                return True
    return False


# ──────────────────────────────────────────────────────────────────
# Transcript scanning for reviewer + verdict
# ──────────────────────────────────────────────────────────────────

def _is_reviewer_name(name: str) -> bool:
    """Is this tool_use name one of our accepted adversarial reviewers?

    Primary: an `ask-codex` MCP tool, exposed as `mcp__<connector-id>__ask-codex`.
    The connector-id segment can differ between sessions/installs, so we match
    on the `ask-codex` suffix rather than a fixed server id.

    Also accepted: the async codex-review wrapper (this repo), whose tool name
    ends `__codex_review_poll` (e.g. `mcp__codex-review__codex_review_poll`).
    That MCP splits a review into start→poll: `codex_review_start` returns only a
    job_id (no verdict), and the `VERDICT: APPROVE/REJECT` line surfaces in the
    `codex_review_poll` RESULT once the review is done. So the verdict-bearing
    call to recognize is the POLL, not the start. Matching on the
    `codex_review_poll` suffix (server-id-agnostic, like `ask-codex`) lets the
    existing "verdict in the reviewer's own tool_result" path pick it up.
    Intermediate "still running" polls carry no `VERDICT:` line, so they read
    as "completed reviewer with no verdict — consider older", and the final
    poll's APPROVE/REJECT is what counts.

    Fallback: a general-purpose `Agent` review. Kept so the gate stays
    satisfied if a review is run via subagent (e.g. Codex unavailable),
    making the accepted set a strict superset — it never weakens the
    gate, only avoids false-blocking a legitimate review.
    """
    if not name:
        return False
    if name == "Agent":
        return True
    if not name.startswith("mcp__"):
        return False
    return name.endswith("__ask-codex") or name.endswith("__codex_review_poll")


def _extract_blocks(rec):
    """Best-effort extraction of content blocks from a transcript
    record. The harness varies — sometimes blocks live under
    `message.content`, sometimes directly under `content`."""
    if not isinstance(rec, dict):
        return []
    msg = rec.get("message")
    if isinstance(msg, dict) and isinstance(msg.get("content"), list):
        return msg["content"]
    if isinstance(rec.get("content"), list):
        return rec["content"]
    return []


def _result_text(block) -> str:
    """Flatten a tool_result block's content to a string for regex search."""
    payload = block.get("content")
    if isinstance(payload, str):
        return payload
    if isinstance(payload, list):
        parts = []
        for inner in payload:
            if isinstance(inner, dict):
                parts.append(inner.get("text", "") or "")
            else:
                parts.append(str(inner))
        return "\n".join(parts)
    return ""


def _record_text(rec) -> str:
    """Concatenate every plain-text fragment in a record. Used to
    surface `<task-notification>` XML buried in user-message content,
    which doesn't appear as a `tool_result` block."""
    if not isinstance(rec, dict):
        return ""
    msg = rec.get("message") if isinstance(rec.get("message"), dict) else None
    content = (msg or {}).get("content") if msg else rec.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, str):
            parts.append(block)
        elif isinstance(block, dict):
            t = block.get("text")
            if isinstance(t, str):
                parts.append(t)
    return "\n".join(parts)


def _harvest_task_notifications(text: str, agent_results: dict) -> None:
    """Pull every completed `<task-notification>` out of `text` and
    register its `<result>` body keyed by `<tool-use-id>`. Mutates
    `agent_results` in place. Status filter (`completed`) ensures
    in-flight notifications don't masquerade as a verdict."""
    if not text or "<task-notification>" not in text.lower():
        return
    for m in TASK_NOTIFICATION_RE.finditer(text):
        body = m.group("body")
        tu_id_m = TASK_TOOL_USE_ID_RE.search(body)
        result_m = TASK_RESULT_RE.search(body)
        if not (tu_id_m and result_m):
            continue
        status_m = TASK_STATUS_RE.search(body)
        status = (status_m.group(1) if status_m else "completed").lower()
        if status != "completed":
            continue
        agent_results[tu_id_m.group(1)] = result_m.group(1)


def _bash_command(block) -> str:
    """The command string of a Bash tool_use transcript block."""
    inp = block.get("input")
    if isinstance(inp, dict):
        return inp.get("command", "") or ""
    return ""


def _verdict_token(text, regex):
    """Decision token (APPROVE/REJECT) of the LAST verdict line in `text` per
    `regex`, or None. Last wins: in a codex log the real verdict is the final
    line — the earlier ones are the echoed prompt."""
    matches = list(regex.finditer(text))
    return matches[-1].group(1).upper() if matches else None


def _review_events(transcript_path: str):
    """Scan the recent transcript ONCE and return ``(mcp_event, codex_event)``,
    each a ``(decision, position)`` where decision is "APPROVE" / "REJECT" /
    "PENDING" (newest review still in flight) or None (none of that kind in
    window), and position is the deciding block's index. main() picks the
    MOST RECENT event across both paths, so a stale APPROVE on one path can
    never override a newer REJECT / in-flight review on the other. Positions
    come from a SINGLE pass so the two paths are directly comparable.

      • MCP/Agent: newest `_is_reviewer_name` tool_use; verdict from its OWN
        tool_result (by tool_use_id) or an async `<task-notification>`.
      • codex-exec: requires an actual `codex exec` dispatch (CODEX_EXEC_RE)
        AND the verdict read out of codex's output by a read command
        (CODEX_READ_RE) — never a bare echo. Newest dispatch after the newest
        such verdict ⇒ in flight.
    """
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            records = [json.loads(line) for line in f if line.strip()]
    except Exception:
        return (None, -1), (None, -1)

    window = records[-RECENT_RECORD_WINDOW:]

    cmd_by_id = {}                  # Bash tool_use_id -> command
    result_by_id = {}               # tool_use_id -> (text, position)
    mcp_reviewers = []              # (tool_use_id, position) in order
    codex_dispatches = []  # (position, tool_use_id, [redirect log paths])
    pos = 0
    for rec in window:
        for block in _extract_blocks(rec):
            if isinstance(block, dict):
                btype = block.get("type")
                if btype == "tool_use":
                    name = block.get("name") or ""
                    if name == "Bash":
                        bid = block.get("id")
                        cmd = _bash_command(block)
                        if bid:
                            cmd_by_id[bid] = cmd
                        if CODEX_EXEC_RE.search(cmd):
                            # (position, dispatch tool_use_id, [log paths it redirected to])
                            codex_dispatches.append((pos, bid, _REDIRECT_RE.findall(cmd)))
                    elif _is_reviewer_name(name):
                        bid = block.get("id")
                        if bid:
                            mcp_reviewers.append((bid, pos))
                elif btype == "tool_result":
                    tu_id = block.get("tool_use_id")
                    if tu_id:
                        result_by_id[tu_id] = (_result_text(block), pos)
            pos += 1
        # Async-agent verdicts arrive as <task-notification> XML in user text.
        notif = {}
        _harvest_task_notifications(_record_text(rec), notif)
        for tu_id, txt in notif.items():
            result_by_id[tu_id] = (txt, pos)
        pos += 1

    # MCP / Agent event — inspect newest reviewer first.
    mcp_event = (None, -1)
    for tu_id, rpos in reversed(mcp_reviewers):
        if tu_id not in result_by_id:
            mcp_event = ("PENDING", rpos)        # newest reviewer in flight
            break
        text, respos = result_by_id[tu_id]
        v = _verdict_token(text, VERDICT_LINE_RE)
        if v:
            mcp_event = (v, respos)
            break
        # completed reviewer with no verdict line — not a review; consider older.

    # codex-exec event — bound to the NEWEST dispatch's OWN output.
    codex_event = (None, -1)
    if codex_dispatches:
        d_pos, d_id, d_logs = max(codex_dispatches, key=lambda d: d[0])
        best_v, best_pos = None, -1
        # (a) Foreground dispatch: the verdict is in the dispatch's own result.
        if d_id in result_by_id:
            text, respos = result_by_id[d_id]
            v = _verdict_token(text, CODEX_VERDICT_RE)
            if v:
                best_v, best_pos = v, respos
        # (b) Backgrounded dispatch: a read of THIS dispatch's own log file,
        # AFTER the dispatch. Requiring the read to reference the dispatch's
        # actual redirect target (not just any "codex"-ish string) defeats a
        # fake/stale log and a "codex" hidden in a comment.
        for tu_id, (text, respos) in result_by_id.items():
            if respos <= d_pos:
                continue
            rcmd = cmd_by_id.get(tu_id, "")
            if not _READ_VERB_RE.search(rcmd):
                continue
            if not any(lp and lp in rcmd for lp in d_logs):
                continue
            v = _verdict_token(text, CODEX_VERDICT_RE)
            if v and respos > best_pos:
                best_v, best_pos = v, respos
        codex_event = (best_v, best_pos) if best_v is not None else ("PENDING", d_pos)

    return mcp_event, codex_event


# ──────────────────────────────────────────────────────────────────
# Hook entry point
# ──────────────────────────────────────────────────────────────────

def main():
    payload = _load_payload()
    if payload.get("tool_name") != "Bash":
        sys.exit(0)

    cmd = (payload.get("tool_input") or {}).get("command", "") or ""
    if not _command_pushes_to_main(cmd):
        sys.exit(0)

    transcript_path = payload.get("transcript_path") or payload.get("transcriptPath")
    if not transcript_path:
        sys.stderr.write(
            "warning: self-review hook saw a `git push` reaching main but the "
            "harness did not expose `transcript_path` — gate cannot enforce, "
            "allowing push.\n"
        )
        sys.exit(0)

    # Take the MOST RECENT review across both paths (ask-codex MCP / Agent,
    # and direct `codex exec` Bash). Comparing by position means a stale
    # APPROVE on one path can't override a newer REJECT or in-flight review
    # on the other. Ties only at position -1 (no review of that kind), which
    # both resolve to "no review".
    mcp_event, codex_event = _review_events(transcript_path)
    decision, position = max(mcp_event, codex_event, key=lambda e: e[1])

    if position >= 0 and decision == "APPROVE":
        # NOTE: this is a transcript GATE only — it deliberately does NOT write a
        # commit receipt. A transcript APPROVE can't be soundly bound to the
        # current HEAD (you might amend/add commits after the review), so writing
        # a receipt here could certify unreviewed content. The coder-agnostic
        # receipt is written by `review-gate.sh`, which reviews exactly HEAD.
        sys.exit(0)

    if decision == "REJECT":
        sys.stderr.write(
            "❌ The most-recent adversarial review returned VERDICT: REJECT.\n"
            "   Address its blockers, run another review, and push only when\n"
            "   the NEWEST verdict is APPROVE.\n"
        )
        sys.exit(2)

    if decision == "PENDING":
        sys.stderr.write(
            "❌ A newer adversarial review is in flight (no verdict yet).\n"
            "   Wait for it; push only when the newest verdict is APPROVE.\n"
        )
        sys.exit(2)

    # decision is None (position -1) — no review in window.
    sys.stderr.write(
        "❌ Review missing: this `git push` reaches main but the recent\n"
        "   transcript shows no completed adversarial review.\n\n"
        "   Before pushing to main, run an adversarial review of the diff\n"
        "   (e.g. `git diff main...HEAD`) ending with, on its last line,\n"
        "   exactly one of:\n"
        "       VERDICT: APPROVE\n"
        "       VERDICT: REJECT — <one-line reason>\n"
        "   via either:\n"
        "     • the `ask-codex` / `codex_review_poll` MCP tool, OR\n"
        "     • `codex exec` on a shell — pipe the diff to stdin, e.g.\n"
        "         git diff main...HEAD | codex exec -s read-only \"<prompt>\"\n"
        "       then surface the VERDICT line (the hook reads it from the\n"
        "       codex log via your grep of it).\n"
        "   Push only when the verdict is APPROVE.\n"
    )
    sys.exit(2)


if __name__ == "__main__":
    main()

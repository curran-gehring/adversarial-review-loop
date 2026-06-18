// Core job logic for the codex-review MCP wrapper. No MCP/protocol code here
// so it can be unit-tested directly (see ../selftest.mjs).
import { spawn } from "node:child_process";
import {
  mkdirSync, openSync, closeSync, writeFileSync, readFileSync,
  existsSync, readdirSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const JOBS_DIR = process.env.CODEX_REVIEW_JOBS_DIR
  || join(homedir(), ".codex-review-mcp", "jobs");

mkdirSync(JOBS_DIR, { recursive: true });

const jobMetaPath = (id) => join(JOBS_DIR, `${id}.json`);
const jobLogPath = (id) => join(JOBS_DIR, `${id}.log`);

function newJobId() {
  return `rev_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function writeMeta(id, meta) {
  writeFileSync(jobMetaPath(id), JSON.stringify(meta, null, 2));
}
function readMeta(id) {
  return JSON.parse(readFileSync(jobMetaPath(id), "utf8"));
}

function isAlive(pid) {
  if (!pid) return false;
  try { process.kill(pid, 0); return true; }
  catch (e) { return e.code === "EPERM"; } // EPERM = alive but not ours
}

// codex's REAL verdict is the LAST `VERDICT:` line; the early ones are the
// echoed prompt. Tolerate a leading "N:" / path prefix from a grep, though we
// read the raw log here so there usually isn't one.
const VERDICT_RE = /^[^\S\r\n]*(?:[^\s:]+:[^\S\r\n]*)*VERDICT[^\S\r\n]*:[^\S\r\n]*(APPROVE|REJECT)\b/gim;

export function extractVerdict(text) {
  let m, last = null;
  while ((m = VERDICT_RE.exec(text)) !== null) last = m[1].toUpperCase();
  return last;
}

// codex prints its final message after a lone `codex` banner line and before a
// `tokens used` footer. Best-effort slice for a clean findings block.
export function extractFindings(text) {
  const lines = text.split(/\r?\n/);
  let start = -1;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim() === "codex") { start = i + 1; break; }
  }
  let body = start >= 0 ? lines.slice(start) : lines;
  const tokIdx = body.findIndex((l) => /^tokens used\b/i.test(l.trim()));
  if (tokIdx >= 0) body = body.slice(0, tokIdx);
  return body.join("\n").trim();
}

// Surface codex's REAL error instead of a misleading wrapper message. The
// ChatGPT-account model rejection is the classic one we want to see verbatim.
export function extractError(text) {
  const m = text.match(/ERROR:\s*(\{.*\}|.+)$/im);
  if (m) {
    try {
      const j = JSON.parse(m[1]);
      return j?.error?.message || j?.message || m[1];
    } catch { return m[1].trim(); }
  }
  if (/unexpected argument/i.test(text)) {
    return text.split(/\r?\n/).find((l) => /unexpected argument/i.test(l)) || "codex CLI argument error";
  }
  return null;
}

function tail(text, n = 60) {
  const lines = text.split(/\r?\n/);
  return lines.slice(Math.max(0, lines.length - n)).join("\n");
}

/**
 * Start a codex review in the background. Returns immediately (no timeout) so
 * the caller can poll — the whole reason this wrapper exists.
 *
 * opts: { prompt, diff?, diffPath?, cwd?, model? }
 *  - diff piped to codex stdin (codex `exec` appends stdin to the prompt arg).
 *  - model is OMITTED by default: Codex running on a ChatGPT subscription
 *    rejects `gpt-5-codex`; the account default works. Pass a model only if
 *    you authenticate with an API key that supports it.
 *  - read-only sandbox + --skip-git-repo-check; NEVER --ask-for-approval.
 */
export function startReview(opts = {}) {
  const { prompt, diff, diffPath, cwd, model } = opts;
  if (!prompt || typeof prompt !== "string") throw new Error("prompt is required");
  const id = newJobId();
  const logPath = jobLogPath(id);

  const args = ["exec", "-s", "read-only", "--skip-git-repo-check"];
  if (model) args.push("--model", model); // opt-in only; default = account model
  args.push(prompt);

  const fd = openSync(logPath, "w");
  const child = spawn("codex", args, {
    cwd: cwd || homedir(),
    stdio: ["pipe", fd, fd],
    detached: true,
    env: process.env,
  });

  const diffText = diff != null ? String(diff)
    : (diffPath && existsSync(diffPath) ? readFileSync(diffPath, "utf8") : "");
  if (diffText) child.stdin.write(diffText);
  child.stdin.end();
  child.unref();
  closeSync(fd);

  writeMeta(id, {
    id, pid: child.pid, logPath, cwd: cwd || homedir(),
    model: model || null, startedAtMs: Date.now(), status: "running",
  });
  return { job_id: id, pid: child.pid, log_path: logPath };
}

/** Poll a review. Returns status + (when done) verdict / findings / error. */
export function pollReview(id) {
  if (!existsSync(jobMetaPath(id))) throw new Error(`unknown job_id: ${id}`);
  const meta = readMeta(id);
  const log = existsSync(meta.logPath) ? readFileSync(meta.logPath, "utf8") : "";
  const verdict = extractVerdict(log);
  const alive = isAlive(meta.pid);

  // Done = process exited. (A verdict appearing while still "alive" is the
  // prompt echo, not codex's final word, so we wait for exit.)
  if (alive) {
    return { job_id: id, status: "running", elapsed_ms: Date.now() - meta.startedAtMs, tail: tail(log, 25) };
  }
  const error = verdict ? null : extractError(log);
  return {
    job_id: id,
    status: error ? "error" : "done",
    verdict: verdict || null,
    findings: error ? null : extractFindings(log),
    error,
    elapsed_ms: Date.now() - meta.startedAtMs,
    tail: tail(log, 60),
  };
}

/**
 * Ask codex a SHORT question and wait for the answer (synchronous). For quick
 * consults where the async review flow is overkill. Bounded by timeoutMs (well
 * under the MCP tool-call limit) — for anything long, use startReview/poll.
 * ChatGPT-account safe (no --model by default); surfaces codex's real error.
 *
 * opts: { prompt, context?, cwd?, model?, timeoutMs? }
 */
export function askCodex(opts = {}) {
  const { prompt, context, cwd, model, timeoutMs = 120000 } = opts;
  return new Promise((resolve) => {
    if (!prompt || typeof prompt !== "string") return resolve({ ok: false, error: "prompt is required" });
    const args = ["exec", "-s", "read-only", "--skip-git-repo-check"];
    if (model) args.push("--model", model);
    args.push(prompt);

    const child = spawn("codex", args, { cwd: cwd || homedir(), stdio: ["pipe", "pipe", "pipe"], env: process.env });
    let buf = "";
    child.stdout.on("data", (d) => (buf += d));
    child.stderr.on("data", (d) => (buf += d)); // codex prints its preamble to stderr
    if (context) child.stdin.write(String(context));
    child.stdin.end(); // EOF, else `codex exec` blocks reading stdin

    const timer = setTimeout(() => {
      try { child.kill("SIGKILL"); } catch {}
      resolve({ ok: false, timedOut: true,
        error: `codex_ask exceeded ${Math.round(timeoutMs / 1000)}s — use codex_review_start for long tasks`,
        partial: extractFindings(buf) || tail(buf, 30) });
    }, timeoutMs);

    child.on("error", (e) => { clearTimeout(timer); resolve({ ok: false, error: e.message }); });
    child.on("close", (code) => {
      clearTimeout(timer);
      const realErr = extractError(buf);
      if (code !== 0 || realErr) {
        return resolve({ ok: false, error: realErr || `codex exited ${code}`, raw: tail(buf, 40) });
      }
      resolve({ ok: true, answer: extractFindings(buf) || buf.trim() });
    });
  });
}

export function listJobs() {
  return readdirSync(JOBS_DIR)
    .filter((f) => f.endsWith(".json"))
    .map((f) => { try { return readMeta(f.replace(/\.json$/, "")); } catch { return null; } })
    .filter(Boolean)
    .sort((a, b) => b.startedAtMs - a.startedAtMs)
    .map((m) => ({ job_id: m.id, status: isAlive(m.pid) ? "running" : "finished", startedAtMs: m.startedAtMs }));
}

export const _internal = { JOBS_DIR, jobLogPath, jobMetaPath, isAlive };

// Unit tests for the pure parsing helpers (no codex needed).
import { extractVerdict, extractFindings, extractError } from "./lib/codex.mjs";

let pass = 0, fail = 0;
const eq = (name, got, exp) => {
  const ok = JSON.stringify(got) === JSON.stringify(exp);
  console.log(`  [${ok ? "OK " : "FAIL"}] ${name}: got=${JSON.stringify(got)} exp=${JSON.stringify(exp)}`);
  ok ? pass++ : fail++;
};

// Real verdict is the LAST one; the prompt-echo lines come first.
const finished = `...prompt instructions...
exactly one of:
VERDICT: APPROVE
VERDICT: REJECT -- <one-line reason>
... diff ...
codex
Finding: none material.
VERDICT: APPROVE
tokens used 18000`;
eq("verdict: last wins (approve)", extractVerdict(finished), "APPROVE");
eq("findings sliced after banner", extractFindings(finished), "Finding: none material.\nVERDICT: APPROVE");

const rejected = `codex
High: bug at Foo.swift.
VERDICT: REJECT -- real bug
tokens used 9000`;
eq("verdict reject", extractVerdict(rejected), "REJECT");

eq("verdict none while running", extractVerdict("...still thinking, no verdict yet..."), null);

// Honest error surfacing — the ChatGPT-account model rejection.
const modelErr = `OpenAI Codex v0.135.0
sandbox: read-only
ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account."}}`;
eq("error: real model message", extractError(modelErr),
  "The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.");

const argErr = `error: unexpected argument '--ask-for-approval' found`;
eq("error: unexpected argument", extractError(argErr),
  "unexpected argument '--ask-for-approval' found");

eq("error: none on clean log", extractError(finished), null);

console.log(`\n${fail === 0 ? "ALL PASS" : "FAILURES"} (${pass} pass, ${fail} fail)`);
process.exit(fail === 0 ? 0 : 1);

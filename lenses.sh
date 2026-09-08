#!/usr/bin/env bash
# Shared lens definitions for every fan-out backend (codex / claude / openrouter).
#
# Sourced, never executed. Keeping one copy means a wording change lands in all
# backends at once — three drifting copies of a safety gate's prompts is a way
# for the gate to quietly stop asking the same question of each reviewer.
#
# Exposes: ARL_LENS_CORRECTNESS, ARL_LENS_DATA, ARL_LENS_UI, ARL_LENS_RULES

ARL_LENS_CORRECTNESS="Review ONLY correctness & concurrency: logic/ordering bugs, off-by-one and boundary errors, race conditions, threading/async and isolation, object lifecycle, null/undefined/force-unwrap and crash paths, resource leaks and reference cycles, error handling."
ARL_LENS_DATA="Review ONLY data & persistence: SQL and schema, migrations, sync/record round-trips, serialization/parsing, units and coordinate math, and set/index/dedupe logic."
ARL_LENS_UI="Review ONLY UI/view-layer correctness & regressions: view/component state, list/key identity, framework/API validity for the target platform, reuse/duplication, and that unrelated surfaces are not regressed."
ARL_LENS_RULES="Read ONLY the files this diff touches; do NOT explore unrelated code. Be concise. The repo may not be compilable here, so do not rely on building it. End with a final line that is EXACTLY one of: 'VERDICT: APPROVE' or 'VERDICT: REJECT -- <one-line reason>'."

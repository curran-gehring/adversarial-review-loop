#!/usr/bin/env bash
# Coder-agnostic review runner.
#
# Reviews HEAD against <base> with the configured reviewer (the 3-lens Codex
# fan-out by default) and, on a unanimous APPROVE, records a per-commit receipt
# that the pre-push gate checks. Works no matter what authored the commits — an
# agent (Claude Code, Cursor, Aider, Codex-as-coder…) or a human. Run it, then
# `git push`.
#
# usage: review-gate.sh [base]            # base defaults to main
# env:
#   ARL_REVIEW_HOST   run the fan-out on this SSH host (default: local)
#   ARL_FANOUT        path to fanout-review.sh (default: next to this script)
#   ARL_CONTEXT       one-line context handed to the reviewer
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
base="${1:-main}"
fanout="${ARL_FANOUT:-$here/fanout-review.sh}"
[ -f "$fanout" ] || { echo "error: fan-out script not found: $fanout" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "error: not inside a git repository." >&2; exit 1; }
root="$(git rev-parse --show-toplevel)"
# Pin the exact commits ONCE. Everything downstream (the diff AND the receipt)
# uses these, so HEAD/base moving mid-run can't make the receipt certify a SHA
# whose content differs from what was actually reviewed.
sha="$(git rev-parse --verify HEAD)"
basesha="$(git rev-parse --verify "${base}^{commit}" 2>/dev/null || true)"
[ -n "$basesha" ] || { echo "error: base '$base' does not resolve to a commit." >&2; exit 1; }
context="${ARL_CONTEXT:-review of ${base}...${sha} ($sha)}"

host="${ARL_REVIEW_HOST:-}"
rdir=""
tmp=""
# Always clean the local scratch dir and (if made) the remote workspace. The
# lens LOGS are written outside $tmp (see $logdir) so they survive for the author
# to read after a REJECT.
trap '[ -n "$tmp" ] && rm -rf "$tmp"; [ -n "$rdir" ] && ssh "$host" "rm -rf \"$rdir\"" >/dev/null 2>&1 || true' EXIT
tmp="$(mktemp -d)"

receipts="$(git rev-parse --git-path adversarial-review)"
logdir="$receipts/last-review"
# The DECISION is aggregated from PER-RUN logs in $tmp (unique per invocation),
# so two concurrent review-gate runs in the same repo can never cross-wire each
# other's verdicts. The shared $logdir copy below is a human-readable convenience
# only; it is never read back to decide a receipt.
prefix="$tmp/fan"
# Start from EMPTY logs, so a crashed/failed lens reads as "no verdict" (not an
# approval) rather than leaving an absent file.
for L in correctness data ui; do : > "$prefix.$L.log"; done

diff="$tmp/review.diff"
git diff "${basesha}...${sha}" > "$diff"   # pinned commits, not the moving HEAD/base refs
if [ ! -s "$diff" ]; then
  echo "nothing to review (${base}...HEAD is empty) — no receipt written."
  exit 0
fi

if [ -n "$host" ]; then
  echo "• reviewing on $host …"
  # Unique per-run remote workspace so concurrent reviews on the same host can't
  # overwrite each other's diff/logs and cross-wire verdicts.
  rdir="$(ssh "$host" 'd=$(mktemp -d "${TMPDIR:-/tmp}/arl.XXXXXX") && printf %s "$d"')"
  [ -n "$rdir" ] || { echo "error: could not create a temp dir on $host" >&2; exit 1; }
  printf '%s' "$context" > "$tmp/context.txt"
  scp -q "$diff"            "$host:$rdir/review.diff"
  scp -q "$fanout"          "$host:$rdir/fanout.sh"
  scp -q "$tmp/context.txt" "$host:$rdir/context.txt"
  # $rdir is mktemp output (safe charset). Context is read from a file via
  # command substitution and passed quoted, so it is NEVER re-parsed by the
  # remote shell — no injection from ARL_CONTEXT. `|| true`: judge by the logs,
  # not the reviewer's exit code.
  #
  # NOTE: remote review is DIFF-SCOPED — only the unified diff is sent, not a repo
  # checkout, so the reviewer judges the (self-contained) diff. Use LOCAL mode if
  # you want the reviewer to open full source files for surrounding context.
  ssh "$host" "ctx=\$(cat \"$rdir/context.txt\"); chmod +x \"$rdir/fanout.sh\"; bash \"$rdir/fanout.sh\" \"$rdir/review.diff\" \"$rdir/fan\" \"\$ctx\" \"$rdir\"" >/dev/null 2>&1 || true
  # A missing lens log (lens crashed) must not abort under `set -e`; the log was
  # pre-truncated to empty above, so a failed copy reads as "no verdict".
  for L in correctness data ui; do
    scp -q "$host:$rdir/fan.$L.log" "$prefix.$L.log" 2>/dev/null || true
  done
else
  echo "• reviewing locally …"
  bash "$fanout" "$diff" "$prefix" "$context" "$root" >/dev/null 2>&1 || true
fi

# Convenience copy for the author to read after a REJECT (NOT the decision input).
mkdir -p "$logdir"
for L in correctness data ui; do cp -f "$prefix.$L.log" "$logdir/fan.$L.log" 2>/dev/null || true; done

# Aggregate: APPROVE iff ALL three lenses approve. Match the verdict TOKEN
# exactly — a rejecting line like "VERDICT: REJECT -- the prior APPROVE was
# stale" must NOT count as an approval just because it contains the word.
approve=0
for L in correctness data ui; do
  line="$(grep -hiE '^[[:space:]]*VERDICT[[:space:]]*:' "$prefix.$L.log" 2>/dev/null | tail -1 || true)"
  dec="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*VERDICT[[:space:]]*:[[:space:]]*([A-Za-z]+).*/\1/' | tr '[:lower:]' '[:upper:]')"
  echo "  ${L}: ${line:-<no verdict emitted>}"
  if [ "$dec" = "APPROVE" ]; then approve=$((approve + 1)); fi
done

mkdir -p "$receipts"
if [ "$approve" -eq 3 ]; then
  printf 'APPROVE\n%s\nbase=%s\nbasesha=%s\nvia=review-gate\n' "$sha" "$base" "$basesha" > "$receipts/$sha"
  echo "VERDICT: APPROVE"
  echo "✓ receipt recorded for $sha — you may push to $base."
  exit 0
fi
# Do NOT delete any existing receipt here: receipts are content-addressed (keyed
# by commit SHA), so a receipt for this SHA can only mean this exact content was
# approved at least once. Deleting on reject would race with a concurrent run
# that legitimately approved the same SHA. Amending/adding commits changes the
# SHA, which has no receipt — so there is nothing stale to clean up.
echo "VERDICT: REJECT -- only $approve/3 lenses approved."
echo "  lens logs: $logdir/fan.{correctness,data,ui}.log  — read the findings, fix, and re-run."
exit 1

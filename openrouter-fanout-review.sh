#!/usr/bin/env bash
# Parallel scoped adversarial review via OpenRouter.
# usage: openrouter-fanout-review.sh <diff_path> <out_prefix> ["extra context"] [repo_dir]
#
# Same contract as fanout-review.sh / claude-fanout-review.sh:
#   writes <out_prefix>.{correctness,data,ui}.log, each ending in a VERDICT line.
#   Aggregate APPROVE iff all three APPROVE.
#
# Why this backend exists: the codex and claude backends each run all three
# lenses on ONE model, so the three lenses share that model's blind spots. This
# one points the same lenses at any OpenRouter-hosted model, which is the whole
# reason to spend money here. It is a REVIEW backend only — reviews are short,
# single-shot, and carry no long cached prefix, so the prompt-caching economics
# that make metered billing untenable for a primary coding agent do not apply.
#
# Unlike the codex backend, an HTTP API cannot read the repo. To compensate, the
# current contents of every file the diff touches are inlined below the diff.
#
# env:
#   OPENROUTER_API_KEY      required. Never commit this; export it in your shell.
#   ARL_OPENROUTER_MODEL    required. Exact OpenRouter slug, e.g. "vendor/model-name".
#                           Deliberately has no default: a wrong hardcoded slug
#                           fails as a confusing 400 rather than a clear message.
#   ARL_OPENROUTER_TIMEOUT  per-lens seconds (default 600)
#   ARL_OPENROUTER_MAX_BYTES  cap on total inlined file bytes (default 400000)
#   ARL_OPENROUTER_BASE_URL base URL (default https://openrouter.ai/api/v1)
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lenses.sh
. "$here/lenses.sh"

DIFF="${1:?usage: openrouter-fanout-review.sh <diff_path> <out_prefix> [\"extra context\"] [repo_dir]}"
OUT="${2:?missing <out_prefix>}"
EXTRA="${3:-}"
REPO="${4:-$PWD}"

# Fail fast at the boundary: a missing credential or model must not surface as
# three REJECTs that look like the reviewer found real bugs.
[ -n "${OPENROUTER_API_KEY:-}" ] || {
  echo "openrouter-fanout: OPENROUTER_API_KEY is not set (export it; do not commit it)" >&2; exit 2; }
[ -n "${ARL_OPENROUTER_MODEL:-}" ] || {
  echo "openrouter-fanout: ARL_OPENROUTER_MODEL is not set (exact OpenRouter slug, e.g. vendor/model-name)" >&2; exit 2; }
[ -f "$DIFF" ] || { echo "openrouter-fanout: no such diff: $DIFF" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || {
  echo "openrouter-fanout: python3 is required (JSON encode/decode)" >&2; exit 2; }

cd "$REPO" || { echo "openrouter-fanout: cannot cd to repo: $REPO" >&2; exit 2; }

TIMEOUT="${ARL_OPENROUTER_TIMEOUT:-600}"
MAX_BYTES="${ARL_OPENROUTER_MAX_BYTES:-400000}"
BASE_URL="${ARL_OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

# Credentials go in a curl config file, not argv — argv is world-readable via ps.
cfg="$tmp/curl.cfg"
umask 077
cat > "$cfg" <<EOF
header = "Authorization: Bearer ${OPENROUTER_API_KEY}"
header = "Content-Type: application/json"
EOF

# --- context: the diff, plus current contents of the files it touches --------
ctx="$tmp/context.txt"
{
  printf 'Unified diff under review:\n\n'
  cat "$DIFF"

  budget="$MAX_BYTES"
  # Paths from the "+++ b/path" lines; /dev/null marks a deletion.
  awk '/^\+\+\+ /{p=$2; sub(/^b\//,"",p); if (p != "/dev/null") print p}' "$DIFF" \
    | sort -u | while IFS= read -r f; do
      [ -f "$f" ] || continue
      size=$(wc -c < "$f" | tr -d ' ')
      printf '\n\n--- current contents of %s ---\n' "$f"
      if [ "$size" -gt "$budget" ]; then
        head -c "$budget" "$f"
        printf '\n[TRUNCATED: %s is %s bytes; inline budget exhausted]\n' "$f" "$size"
        budget=0
      else
        cat "$f"
        budget=$((budget - size))
      fi
      [ "$budget" -le 0 ] && break
    done
} > "$ctx"

# --- one lens ---------------------------------------------------------------
run() {
  local name="$1" lens="$2"
  local log="${OUT}.${name}.log"
  local payload="$tmp/${name}.json" body="$tmp/${name}.body" http=""
  local rc=0

  ARL_LENS_NAME="$name" ARL_LENS_TEXT="$lens" ARL_EXTRA="$EXTRA" \
  ARL_RULES="$ARL_LENS_RULES" ARL_MODEL="$ARL_OPENROUTER_MODEL" ARL_CTX="$ctx" \
  python3 -c '
import json, os
prompt = "\n\n".join(x for x in [
    "You are the %s lens of a parallel adversarial code review." % os.environ["ARL_LENS_NAME"],
    os.environ["ARL_LENS_TEXT"],
    ("Extra context: " + os.environ["ARL_EXTRA"]) if os.environ.get("ARL_EXTRA") else "",
    os.environ["ARL_RULES"],
    open(os.environ["ARL_CTX"], encoding="utf-8", errors="replace").read(),
] if x)
json.dump({"model": os.environ["ARL_MODEL"],
           "messages": [{"role": "user", "content": prompt}]},
          open(os.environ["ARL_PAYLOAD"], "w", encoding="utf-8"))
' 2>>"$log" || { printf 'VERDICT: REJECT -- openrouter %s lens could not build its request\n' "$name" >> "$log"; return; }

  http="$(curl -sS -K "$cfg" -X POST \
            --max-time "$TIMEOUT" \
            --data-binary "@$payload" \
            -o "$body" -w '%{http_code}' \
            "$BASE_URL/chat/completions" 2>>"$log")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    printf 'VERDICT: REJECT -- openrouter %s lens transport failed (curl exit %s)\n' "$name" "$rc" >> "$log"
    return
  fi
  if [ "$http" != "200" ]; then
    printf 'openrouter HTTP %s\n' "$http" >> "$log"
    head -c 2000 "$body" >> "$log" 2>/dev/null
    printf '\nVERDICT: REJECT -- openrouter %s lens got HTTP %s\n' "$name" "$http" >> "$log"
    return
  fi

  ARL_BODY="$body" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["ARL_BODY"], encoding="utf-8"))
    sys.stdout.write(d["choices"][0]["message"]["content"] or "")
except Exception as e:
    sys.stderr.write("could not parse OpenRouter response: %s\n" % e)
    sys.exit(1)
' >> "$log" 2>>"$log" || {
    printf '\nVERDICT: REJECT -- openrouter %s lens returned an unparseable response\n' "$name" >> "$log"
    return
  }

  # Fail closed: a lens that emitted no verdict is a failed review, not a pass.
  grep -qE '^[[:space:]]*VERDICT[[:space:]]*:' "$log" 2>/dev/null \
    || printf '\nVERDICT: REJECT -- openrouter %s lens emitted no verdict\n' "$name" >> "$log"
}

: > "${OUT}.correctness.log"; : > "${OUT}.data.log"; : > "${OUT}.ui.log"
ARL_PAYLOAD="$tmp/correctness.json" run correctness "$ARL_LENS_CORRECTNESS" &
ARL_PAYLOAD="$tmp/data.json"        run data        "$ARL_LENS_DATA" &
ARL_PAYLOAD="$tmp/ui.json"          run ui          "$ARL_LENS_UI" &
wait

echo "FANOUT_DONE"

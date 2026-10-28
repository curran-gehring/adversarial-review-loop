#!/usr/bin/env bash
# Pins repository review rules: the sections of a repo's REVIEW-RULES.md whose
# `paths:` patterns match the files a diff touches are added to every lens
# prompt, on every backend.
#
# A lens that judges a diff against only its general knowledge passes changes
# that break rules the repository has already paid to learn (a read that must
# autocommit, a host tests must never load). The rules have to arrive in the
# prompt; a reviewer that cannot browse the repo will not go looking for them.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# shellcheck source=../lenses.sh
. "$here/../lenses.sh"

for fn in arl_changed_paths arl_with_repo_rules; do
  command -v "$fn" >/dev/null 2>&1 \
    && ok "lenses.sh exposes $fn" \
    || { bad "lenses.sh does not expose $fn"; echo; echo "repo-rules: $fails FAILURE(S)"; exit 1; }
done

# --- arl_changed_paths -----------------------------------------------------
# Header lines only. A removed SQL comment "-- a/x" is the hunk line "--- a/x";
# reading it as a file header would select rules for a file nobody touched.
cat > "$work/paths.diff" <<'DIFF'
diff --git a/backend/app/db.py b/backend/app/db.py
index 1111111..2222222 100644
--- a/backend/app/db.py
+++ b/backend/app/db.py
@@ -1,3 +1,3 @@
--- a/not/a/header.sql
-old
+new
diff --git a/old name.sql b/old name.sql
deleted file mode 100644
--- a/old name.sql
+++ /dev/null
@@ -1 +0,0 @@
-gone
diff --git a/frontend/new.vue b/frontend/new.vue
new file mode 100644
--- /dev/null
+++ b/frontend/new.vue
@@ -0,0 +1 @@
+<template/>
diff --git a/docs/a.md b/docs/b.md
similarity index 100%
rename from docs/a.md
rename to docs/b.md
diff --git a/img/logo.png b/img/logo.png
Binary files a/img/logo.png and b/img/logo.png differ
DIFF
printf '%s\n' 'backend/app/db.py' 'docs/a.md' 'docs/b.md' 'frontend/new.vue' 'img/logo.png' 'old name.sql' \
  | sort > "$work/paths.want"
arl_changed_paths "$work/paths.diff" > "$work/paths.got"
if diff -u "$work/paths.want" "$work/paths.got" >/dev/null; then
  ok "arl_changed_paths reads every header form and ignores hunk lines"
else
  bad "arl_changed_paths got: $(tr '\n' '|' < "$work/paths.got")"
fi

# A diff written on Windows can carry CRLF line endings.
sed 's/$/\r/' "$work/paths.diff" > "$work/crlf.diff"
arl_changed_paths "$work/crlf.diff" > "$work/crlf.got"
diff -u "$work/paths.want" "$work/crlf.got" >/dev/null \
  && ok "arl_changed_paths strips CR from a CRLF diff" \
  || bad "arl_changed_paths kept CRs: $(tr '\n\r' '|^' < "$work/crlf.got")"

# Git C-quotes a path with non-ASCII bytes or special characters. A binary
# change has no ---/+++ lines, so the diff --git line is its only header; a
# reader that cannot decode it yields no path and every rule, `paths: *`
# included, silently drops out of the review.
cat > "$work/quoted.diff" <<'DIFF'
diff --git "a/img/caf\303\251.png" "b/img/caf\303\251.png"
index 1111111..2222222 100644
Binary files "a/img/caf\303\251.png" and "b/img/caf\303\251.png" differ
diff --git a/plain.txt "b/say \"hi\".txt"
similarity index 100%
rename from plain.txt
rename to "say \"hi\".txt"
diff --git "a/tab\there.sql" "b/tab\there.sql"
--- "a/tab\there.sql"
+++ "b/tab\there.sql"
@@ -1 +1 @@
-old
+new
DIFF
{ printf 'img/caf\303\251.png\n'; printf 'plain.txt\n'; printf 'say "hi".txt\n'; printf 'tab\there.sql\n'; } \
  | sort > "$work/quoted.want"
arl_changed_paths "$work/quoted.diff" > "$work/quoted.got"
diff -u "$work/quoted.want" "$work/quoted.got" >/dev/null \
  && ok "arl_changed_paths decodes git-quoted paths, including binary-only headers" \
  || bad "arl_changed_paths got: $(tr '\n' '|' < "$work/quoted.got")"

# A file header that yields no path must stop the review, not drop the file.
cat > "$work/unreadable.diff" <<'DIFF'
diff --git a/one b/two
diff --git a/x b/x
--- a/x
+++ b/x
@@ -1 +1 @@
-old
+new
DIFF
arl_changed_paths "$work/unreadable.diff" >/dev/null 2>"$work/unreadable.err" \
  && bad "a file header with no readable path was accepted" \
  || { [ -s "$work/unreadable.err" ] && ok "a file header with no readable path fails with a message" \
       || bad "an unreadable file header failed silently"; }

# --- arl_with_repo_rules ----------------------------------------------------
repo="$work/repo"
mkdir -p "$repo"
# A file in the repo that the `*.sql` pattern would expand to if the patterns
# were word-split with globbing on.
: > "$repo/zzz.sql"
cat > "$repo/REVIEW-RULES.md" <<'RULES'
# Review rules

This preamble is for people and never reaches a reviewer. PREAMBLE_MARKER

## Postgres reads
paths: backend/*.py *.sql

- Every read connection runs in autocommit. RULE_PG_MARKER

## Vue pages
paths: frontend/pages/*

- Pages use the shared report header. RULE_VUE_MARKER

### Subheading stays inside its section
- SUBHEAD_MARKER
RULES

cat > "$work/py.diff" <<'DIFF'
diff --git a/backend/app/db.py b/backend/app/db.py
--- a/backend/app/db.py
+++ b/backend/app/db.py
@@ -1 +1 @@
-old
+new
DIFF

got="$(arl_with_repo_rules "ctx line" "$work/py.diff" "$repo")"; rc=$?
[ "$rc" -eq 0 ] && ok "a valid rules file is accepted" || bad "a valid rules file was rejected (rc=$rc)"
case "$got" in "ctx line"*) ok "the caller's context comes first" ;; *) bad "context lost or moved: $got" ;; esac
case "$got" in *RULE_PG_MARKER*) ok "a section whose pattern matches is included" ;; *) bad "matching section missing" ;; esac
case "$got" in *"Postgres reads"*) ok "the section title is kept" ;; *) bad "section title missing" ;; esac
case "$got" in *RULE_VUE_MARKER*|*SUBHEAD_MARKER*) bad "a non-matching section was included" ;; *) ok "a non-matching section is left out" ;; esac
case "$got" in *PREAMBLE_MARKER*) bad "the preamble reached the reviewer" ;; *) ok "the preamble is left out" ;; esac
case "$got" in *REJECT*) ok "the block tells the lens a broken rule is a defect" ;; *) bad "the block does not say how to treat a broken rule" ;; esac

cat > "$work/vue.diff" <<'DIFF'
diff --git a/frontend/pages/reports/x.vue b/frontend/pages/reports/x.vue
--- a/frontend/pages/reports/x.vue
+++ b/frontend/pages/reports/x.vue
@@ -1 +1 @@
-old
+new
DIFF
got="$(arl_with_repo_rules "" "$work/vue.diff" "$repo")"
case "$got" in *SUBHEAD_MARKER*) ok "* matches across directories and ### stays in its section" ;; *) bad "nested path or subheading lost" ;; esac

# Run from inside the repo, where `*.sql` would expand to the literal zzz.sql
# and stop matching db/migrate.sql if the patterns were globbed.
cat > "$work/sql.diff" <<'DIFF'
diff --git a/db/migrate.sql b/db/migrate.sql
--- a/db/migrate.sql
+++ b/db/migrate.sql
@@ -1 +1 @@
-old
+new
DIFF
got="$(cd "$repo" && arl_with_repo_rules "" "$work/sql.diff" "$repo")"
case "$got" in *RULE_PG_MARKER*) ok "patterns are not glob-expanded against the current directory" ;; *) bad "a pattern was expanded against the current directory" ;; esac

cat > "$work/other.diff" <<'DIFF'
diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-old
+new
DIFF
got="$(arl_with_repo_rules "ctx only" "$work/other.diff" "$repo")"
[ "$got" = "ctx only" ] && ok "no matching section leaves the context unchanged" || bad "context changed with no match: $got"

quotedrepo="$work/quotedrepo"; mkdir -p "$quotedrepo"
printf '## Images\npaths: img/*.png\n- IMG_RULE_MARKER\n' > "$quotedrepo/REVIEW-RULES.md"
got="$(arl_with_repo_rules "" "$work/quoted.diff" "$quotedrepo")"
case "$got" in *IMG_RULE_MARKER*) ok "a binary change to a non-ASCII path gets its rules" ;; *) bad "rules dropped for a git-quoted binary path" ;; esac
arl_with_repo_rules "" "$work/unreadable.diff" "$quotedrepo" >/dev/null 2>&1 \
  && bad "rules were selected from a diff with an unreadable file header" \
  || ok "an unreadable file header fails the rule selection"

norules="$work/norules"; mkdir -p "$norules"
got="$(arl_with_repo_rules "ctx only" "$work/py.diff" "$norules")"; rc=$?
[ "$rc" -eq 0 ] && [ "$got" = "ctx only" ] \
  && ok "a repo without REVIEW-RULES.md is reviewed as before" \
  || bad "a repo without rules changed the context or failed (rc=$rc)"

# CRLF rules file (core.autocrlf checkouts on Windows).
crlf="$work/crlf"; mkdir -p "$crlf"
sed 's/$/\r/' "$repo/REVIEW-RULES.md" > "$crlf/REVIEW-RULES.md"
got="$(arl_with_repo_rules "" "$work/py.diff" "$crlf")"
case "$got" in *RULE_PG_MARKER*) ok "a CRLF rules file still matches" ;; *) bad "a CRLF rules file selected nothing" ;; esac

# --- misconfiguration fails loud --------------------------------------------
# A rule that silently stops applying is the failure this whole feature exists
# to prevent, so a malformed file stops the review instead of being skipped.
expect_fail() {
  local label="$1" dir="$2" err
  err="$(arl_with_repo_rules "" "$work/py.diff" "$dir" 2>&1 >/dev/null)" \
    && { bad "$label was accepted"; return; }
  [ -n "$err" ] && ok "$label fails with a message" || bad "$label failed silently"
}

nopaths="$work/nopaths"; mkdir -p "$nopaths"
printf '## Section\n\n- a rule with no paths line\n' > "$nopaths/REVIEW-RULES.md"
expect_fail "a section without a paths: line" "$nopaths"

emptypaths="$work/emptypaths"; mkdir -p "$emptypaths"
printf '## Section\npaths:   \n- rule\n' > "$emptypaths/REVIEW-RULES.md"
expect_fail "an empty paths: line" "$emptypaths"

# Present but unusable is not absent: reviewing without the rules would pass
# exactly the changes they exist to stop.
dirrules="$work/dirrules"; mkdir -p "$dirrules/REVIEW-RULES.md"
expect_fail "a REVIEW-RULES.md that is a directory" "$dirrules"

unreadable="$work/unreadable"; mkdir -p "$unreadable"
printf '## S\npaths: *\n- rule\n' > "$unreadable/REVIEW-RULES.md"
chmod 000 "$unreadable/REVIEW-RULES.md"
if [ -r "$unreadable/REVIEW-RULES.md" ]; then
  ok "unreadable-file case skipped (chmod cannot revoke read here)"
else
  expect_fail "an unreadable REVIEW-RULES.md" "$unreadable"
fi
chmod 644 "$unreadable/REVIEW-RULES.md"

# A dangling symlink fails `-e` but is not an absent file.
linked="$work/linked"; mkdir -p "$linked"
ln -s "$work/no-such-target.md" "$linked/REVIEW-RULES.md" 2>/dev/null
if [ -L "$linked/REVIEW-RULES.md" ]; then
  expect_fail "a dangling REVIEW-RULES.md symlink" "$linked"
else
  ok "dangling-symlink case skipped (no symlinks here)"
fi

# The file can vanish or lose read permission between that check and the read;
# a read that fails must fail the selection too. A failing `cat` stands in.
err="$( cat() { return 1; }; arl_with_repo_rules "" "$work/py.diff" "$repo" 2>&1 >/dev/null )" \
  && bad "a failed read of REVIEW-RULES.md was accepted" \
  || { [ -n "$err" ] && ok "a failed read of REVIEW-RULES.md fails with a message" || bad "a failed read failed silently"; }

# A diff with hunks but no file headers passes arl_require_diff and names no
# file; with a rules file present, that must not read as "no rules apply".
printf '@@ -1 +1 @@\n-old\n+new\n' > "$work/hunk-only.diff"
expect_fail_diff() {
  arl_with_repo_rules "" "$1" "$repo" >/dev/null 2>"$work/ef.err" \
    && { bad "$2 was accepted"; return; }
  [ -s "$work/ef.err" ] && ok "$2 fails with a message" || bad "$2 failed silently"
}
expect_fail_diff "$work/hunk-only.diff" "a diff that names no file"

for limit in abc -5 0 00 99999999999999999999 ''; do
  ARL_RULES_MAX_BYTES="$limit" arl_with_repo_rules "" "$work/py.diff" "$repo" >/dev/null 2>&1 \
    && { [ -z "$limit" ] && ok "an empty ARL_RULES_MAX_BYTES uses the default" || bad "ARL_RULES_MAX_BYTES='$limit' was accepted"; } \
    || { [ -z "$limit" ] && bad "an empty ARL_RULES_MAX_BYTES failed" || ok "ARL_RULES_MAX_BYTES='$limit' fails"; }
done

big="$work/big"; mkdir -p "$big"
{ printf '## Huge\npaths: *\n'; head -c 3000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$big/REVIEW-RULES.md"
err="$(ARL_RULES_MAX_BYTES=1000 arl_with_repo_rules "" "$work/py.diff" "$big" 2>&1 >/dev/null)" \
  && bad "selected rules over ARL_RULES_MAX_BYTES were accepted" \
  || { case "$err" in *ARL_RULES_MAX_BYTES*) ok "oversized rules fail and name the limit" ;; *) bad "oversized rules failed without naming the limit: $err" ;; esac; }

# --- ARL_RULES_FILE ---------------------------------------------------------
# review-gate.sh reviews a working tree at HEAD, so it points this at the copy
# from the base commit: a diff must not be judged by rules it rewrites itself.
got="$(ARL_RULES_FILE="$repo/REVIEW-RULES.md" arl_with_repo_rules "" "$work/py.diff" "$norules")"
case "$got" in *RULE_PG_MARKER*) ok "ARL_RULES_FILE overrides the repo's own file" ;; *) bad "ARL_RULES_FILE was ignored" ;; esac
ARL_RULES_FILE="$work/missing.md" arl_with_repo_rules "" "$work/py.diff" "$repo" >/dev/null 2>&1 \
  && bad "a missing ARL_RULES_FILE was accepted" \
  || ok "a missing ARL_RULES_FILE fails"

# --- every backend delivers the rules to its model --------------------------
# Parity, end to end: each backend gets a stub model CLI that records all of its
# input. The fix that reaches one backend has historically missed the others.
stubdir="$work/stubs"; mkdir -p "$stubdir"
for cli in codex claude agy curl; do
  cat > "$stubdir/$cli" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; [ -t 0 ] || cat; } >> "$ARL_TEST_CAPTURE" 2>/dev/null
for a in "$@"; do case "$a" in --data-binary) d=1 ;; *) [ -n "${d:-}" ] && { cat "${a#@}" >> "$ARL_TEST_CAPTURE"; d=; } ;; esac; done
printf 'VERDICT: APPROVE\n'
STUB
  chmod +x "$stubdir/$cli"
done

for b in fanout-review.sh claude-fanout-review.sh gemini-fanout-review.sh openrouter-fanout-review.sh; do
  cap="$work/$b.capture"; : > "$cap"
  ( cd "$work" && env -u ARL_PREFIX_LOCK_HELD -u ARL_RULES_FILE -u ARL_FANOUT_BACKEND \
      PATH="$stubdir:$PATH" ARL_TEST_CAPTURE="$cap" ARL_LENSES=data \
      ARL_FORCE_CODEX_FANOUT=1 ARL_PRIMARY_MODEL=claude OPENROUTER_API_KEY=test-key ARL_OPENROUTER_MODEL=test/model \
      "$here/../$b" "$work/py.diff" "$work/$b.out" "ctx" "$repo" >/dev/null 2>&1 ) || true
  grep -q RULE_PG_MARKER "$cap" \
    && ok "$b sends the matching rules to the reviewer" \
    || bad "$b did not send the matching rules to the reviewer"
done

echo
if [ "$fails" -eq 0 ]; then echo "repo-rules: all passed"; else echo "repo-rules: $fails FAILURE(S)"; exit 1; fi

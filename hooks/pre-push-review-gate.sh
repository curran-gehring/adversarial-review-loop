#!/bin/sh
# pre-push hook: require a recorded APPROVE review for the commit being pushed to
# the protected branch. CODER-AGNOSTIC — it checks a per-commit receipt, so it
# enforces the review loop no matter which tool, agent, or human authored the
# commits (it does not read any authoring harness's transcript).
#
# A receipt is produced by `review-gate.sh` (any coder) or by the Claude Code
# adapter `require-review.py` (auto, from the transcript). Both write:
#     $GIT_DIR/adversarial-review/<sha>   with a first line of `APPROVE`.
#
# Config / escape hatches:
#   ARL_PROTECTED_BRANCH   branch to guard (default: main)
#   ARL_SKIP_REVIEW=1      bypass this gate (use sparingly, and say why)
remote="$1"
protected="${ARL_PROTECTED_BRANCH:-main}"

[ "${ARL_SKIP_REVIEW:-0}" = "1" ] && exit 0

receipts="$(git rev-parse --git-path adversarial-review 2>/dev/null)" || exit 0
zero=0000000000000000000000000000000000000000

while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
    case "$remote_ref" in
        refs/heads/"$protected")
            [ "$local_sha" = "$zero" ] && continue   # branch deletion — nothing to review
            r="$receipts/$local_sha"
            if [ -f "$r" ]; then
                # line 1 is the verdict; `basesha=<commit>` is the base the review
                # diffed against. Require an APPROVE AND that the reviewed base is
                # an ancestor of the tip this push updates ($remote_sha) — so the
                # review covered at least the diff being introduced to $protected.
                # (The descendant guard ensures the pushed commit descends
                # $remote_sha, which together with this makes the coverage sound.)
                # A first push that creates the branch ($remote_sha all-zero) has
                # no base to be stale against, so APPROVE alone suffices there.
                IFS= read -r first < "$r"
                recbasesha="$(sed -n 's/^basesha=//p' "$r" | head -n1)"
                if [ "$first" = "APPROVE" ]; then
                    if [ "$remote_sha" = "$zero" ]; then
                        continue
                    fi
                    if [ -n "$recbasesha" ] && git merge-base --is-ancestor "$recbasesha" "$remote_sha" 2>/dev/null; then
                        continue
                    fi
                    echo "ERROR: push to '$protected' blocked — the APPROVE receipt for ${local_sha} was reviewed against a base that is not on the current '$protected' history (the branch moved, or it was reviewed against a different base)." >&2
                    echo "Re-review against the up-to-date branch:  git fetch && review-gate.sh $protected" >&2
                    exit 1
                fi
            fi
            echo "ERROR: push to '$protected' blocked — no APPROVE review on record for ${local_sha}." >&2
            echo "Run an adversarial review and record the verdict, then push:" >&2
            echo "    review-gate.sh $protected" >&2
            echo "(If a different model authored the change, this still applies — the gate is coder-agnostic.)" >&2
            echo "(Bypass with ARL_SKIP_REVIEW=1 only if you truly know what you're doing.)" >&2
            exit 1
            ;;
    esac
done

exit 0

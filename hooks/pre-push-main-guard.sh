#!/bin/sh
# pre-push hook: reject pushes to main that aren't descendants of origin/main.
# Lets you push from any branch; only intercepts refs/heads/main.

remote="$1"
protected="main"

while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
    case "$remote_ref" in
        refs/heads/main)
            git fetch --quiet "$remote" "$protected" 2>/dev/null
            remote_main=$(git rev-parse --quiet --verify "refs/remotes/$remote/$protected" 2>/dev/null)
            if [ -z "$remote_main" ]; then
                continue
            fi
            if [ "$local_sha" = "0000000000000000000000000000000000000000" ]; then
                continue
            fi
            if ! git merge-base --is-ancestor "$remote_main" "$local_sha"; then
                echo "ERROR: push to '$protected' rejected — local HEAD is not a descendant of $remote/$protected." >&2
                echo "Fix: git fetch $remote $protected && git rebase $remote/$protected" >&2
                exit 1
            fi
            ;;
    esac
done

exit 0

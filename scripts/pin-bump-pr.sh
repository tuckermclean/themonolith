#!/bin/sh
# The git and GitHub steps of .github/workflows/pin-bump.yml's bump job:
#   pin-bump-pr.sh labels   create the labels the PR uses (idempotent)
#   pin-bump-pr.sh branch   switch to pins/bump-<old12>-<new12>
#   pin-bump-pr.sh commit   stage the tree pin and versions.lock, commit and push the branch
#   pin-bump-pr.sh pr       open the PR against main with the full-ci label
# Environment: OLD_COMMIT, NEW_COMMIT (40 hex digits); GH_TOKEN for labels, commit (the push) and pr;
# LOCK_OUTCOME (the update-versions step's outcome) for pr.
set -eu

: "${OLD_COMMIT:?pin-bump-pr: OLD_COMMIT is not set}"
: "${NEW_COMMIT:?pin-bump-pr: NEW_COMMIT is not set}"
old12=$(printf %.12s "$OLD_COMMIT")
new12=$(printf %.12s "$NEW_COMMIT")
BRANCH="pins/bump-$old12-$new12"
OUT=output/pin-bump
TITLE="chore(pins): bump TREE_COMMIT $old12 -> $new12"

case ${1:-} in
labels)
    gh label create "pin-bump" --color "0e8a16" \
        --description "Automated tree pin bump" --force
    gh label create "full-ci" --color "1d76db" \
        --description "Run the full build on this pull request" --force
    gh label create "needs-fixup" --color "d93f0b" \
        --description "Automated pin bump failed validation and needs a fix" --force
    gh label create "validated" --color "0e8a16" \
        --description "Automated pin bump passed full build+CVE+boot validation" --force
    ;;
branch)
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git switch -c "$BRANCH"
    ;;
commit)
    mkdir -p "$OUT"
    git add Makefile configs/portage/versions.lock
    git diff --cached --stat -- Makefile configs/portage/versions.lock > "$OUT/diffstat.txt"
    git diff --cached -- configs/portage/versions.lock | head -n 200 > "$OUT/versions.diff"
    git diff --cached -- Makefile > "$OUT/pins.diff"
    git commit -m "chore(pins): bump TREE_COMMIT $old12 -> $new12

Automated by .github/workflows/pin-bump.yml.
- Makefile: TREE_COMMIT, TREE_DIGEST, SOURCE_DATE_EPOCH, TREE_FILES
- configs/portage/versions.lock: regenerated against the new tree"
    # actions/checkout keeps its credentials in an include file under RUNNER_TEMP, which the toolbox does not
    # mount; authenticate this one push with the App token through a throwaway helper that reads $GH_TOKEN
    # (nothing is written to .git/config, and the token is not on any command line).
    : "${GH_TOKEN:?pin-bump-pr: GH_TOKEN is not set}"
    git -c credential.helper= \
        -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' \
        push -u origin "$BRANCH"
    ;;
pr)
    {
        echo "## Tree pin"
        echo '```diff'
        cat "$OUT/pins.diff"
        echo '```'
        echo ""
        echo "## Lock diff summary"
        echo '```'
        cat "$OUT/diffstat.txt"
        echo '```'
        echo ""
        echo "<details><summary>configs/portage/versions.lock diff (first 200 lines)</summary>"
        echo ""
        echo '```diff'
        cat "$OUT/versions.diff"
        echo '```'
        echo "</details>"
        echo ""
        echo "## Validation"
        if [ "${LOCK_OUTCOME:-success}" != "success" ]; then
            echo "**BLOCKED** - \`make update-versions\` failed against the new tree. versions.lock was not"
            echo "regenerated. Fix forward on this branch (docs/version-pinning.md)."
            echo ""
        fi
        echo "The \`full-ci\` label starts \`build.yml\` on this PR: build, attestation (SBOM, licence and CVE gates)"
        echo "and the boot tests. Merge only when that run is green."
        echo ""
        echo "---"
        echo "This PR was opened automatically by \`.github/workflows/pin-bump.yml\`. It is never merged"
        echo "automatically; a human reviews and merges it, per \`docs/version-pinning.md\`."
    } > "$OUT/pr-body.md"
    labels="pin-bump,full-ci"
    [ "${LOCK_OUTCOME:-success}" = "success" ] || labels="$labels,needs-fixup"
    gh pr create \
        --title "$TITLE" \
        --body-file "$OUT/pr-body.md" \
        --base main \
        --head "$BRANCH" \
        --label "$labels"
    ;;
*)
    echo "usage: pin-bump-pr.sh labels|branch|commit|pr" >&2
    exit 2
    ;;
esac

#!/bin/bash
# The steps of .github/workflows/toolchain-bump.yml that are not Make or the pin script. Run on the host.
#   toolchain-bump.sh inputs       check the dispatch inputs
#   toolchain-bump.sh labels       create the labels the PR uses (idempotent)
#   toolchain-bump.sh epoch        write old (the current TOOLCHAIN_EPOCH) and target (the epoch to bump to) to $GITHUB_OUTPUT
#   toolchain-bump.sh epoch-check  stop when TOOLCHAIN_EPOCH did not change, unless this is a first rebuild
#   toolchain-bump.sh branch       switch to toolchain/bump-<old>-<new>-<commit12>
#   toolchain-bump.sh branch-name  print the branch name
#   toolchain-bump.sh digest       write the pushed builder image's digest to BUILDER_DIGEST
#   toolchain-bump.sh commit       stage the pins, commit and push the branch
#   toolchain-bump.sh dispatch     find the build.yml run the Makefile dispatched (make toolchain-dispatch); writes found, run_id and run_url to $GITHUB_OUTPUT
#   toolchain-bump.sh wait         wait for that run; writes conclusion to $GITHUB_OUTPUT
#   toolchain-bump.sh pr           open the PR against main. Nothing here merges.
# Environment: NEW_COMMIT (tree_commit, 40 hex digits), TARGET_EPOCH (YYYYMMDD or empty), FIRST_REBUILD (true|false),
# OLD_EPOCH, REGISTRY, GH_TOKEN, DISPATCHED_AFTER (UTC time before the dispatch), and the step results BUILD_OUTCOME, RUN_FOUND, RUN_ID, RUN_URL, CONCLUSION.
# A first rebuild rebuilds at the current TOOLCHAIN_EPOCH (M03 rebuilds rc1's image at its epoch).
set -euo pipefail

OUT=output/toolchain-bump
cur_epoch() { grep '^ARG TOOLCHAIN_EPOCH=' Dockerfile | cut -d= -f2; }
out() { echo "$1" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }
branch() {
    : "${NEW_COMMIT:?toolchain-bump: NEW_COMMIT is not set}"
    : "${OLD_EPOCH:?toolchain-bump: OLD_EPOCH is not set}"
    echo "toolchain/bump-${OLD_EPOCH}-$(cur_epoch)-$(printf %.12s "${NEW_COMMIT}")"
}

case ${1:-} in
inputs)
    if ! [[ "${NEW_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "::error::tree_commit must be 40 hex digits, got: ${NEW_COMMIT:-}"
        exit 1
    fi
    if [[ -n "${TARGET_EPOCH:-}" ]] && ! [[ "${TARGET_EPOCH}" =~ ^[0-9]{8}$ ]]; then
        echo "::error::target_epoch must be YYYYMMDD, got: ${TARGET_EPOCH}"
        exit 1
    fi
    if [[ "${FIRST_REBUILD:-false}" == "true" && -n "${TARGET_EPOCH:-}" ]]; then
        echo "::error::first_rebuild rebuilds at the current epoch; leave target_epoch empty"
        exit 1
    fi
    ;;
labels)
    gh label create "toolchain-bump" --color "5319e7" \
        --description "Automated TOOLCHAIN_EPOCH pin bump (human-gated)" --force
    gh label create "needs-fixup" --color "d93f0b" \
        --description "Automated pin bump failed or could not complete validation" --force
    gh label create "validated" --color "0e8a16" \
        --description "Automated pin bump passed full build+CVE+boot validation" --force
    ;;
epoch)
    old=$(cur_epoch)
    target="${TARGET_EPOCH:-}"
    if [[ "${FIRST_REBUILD:-false}" == "true" ]]; then target="${old}"; fi
    out "old=${old}"
    out "target=${target}"
    ;;
epoch-check)
    : "${OLD_EPOCH:?toolchain-bump: OLD_EPOCH is not set}"
    now=$(cur_epoch)
    if [[ "${now}" == "${OLD_EPOCH}" && "${FIRST_REBUILD:-false}" != "true" ]]; then
        echo "::error::TOOLCHAIN_EPOCH is still ${now} — no update available (or forced value equals current); nothing to bump. Dispatch with first_rebuild to rebuild at the current epoch."
        exit 1
    fi
    ;;
branch)
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git switch -c "$(branch)"
    ;;
branch-name)
    branch
    ;;
digest)
    : "${REGISTRY:?toolchain-bump: REGISTRY is not set}"
    image="${REGISTRY}/builder"
    tag=$(make -s print-registry-tag)
    digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${image}:${tag}" \
        | sed -n "s|^${image}@||p" | head -n 1)
    if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "::error::no repo digest for ${image}:${tag} after the push (got '${digest}')"
        exit 1
    fi
    scripts/update-build-pins.sh set-builder "${digest}"
    ;;
commit)
    : "${OLD_EPOCH:?toolchain-bump: OLD_EPOCH is not set}"
    new=$(cur_epoch)
    mkdir -p "${OUT}"
    git add Dockerfile Makefile configs/portage/crossdev.lock
    git diff --cached --stat > "${OUT}/diffstat.txt"
    git diff --cached -- configs/portage/crossdev.lock > "${OUT}/crossdev.diff"
    git diff --cached -- Makefile > "${OUT}/pins.diff"
    if [[ "${BUILD_OUTCOME:-}" == "success" ]]; then built=yes; else built='FAILED - see PR body'; fi
    git commit -m "chore(pins): toolchain ${OLD_EPOCH} -> ${new}, tree $(printf %.12s "${NEW_COMMIT}")

Automated by .github/workflows/toolchain-bump.yml (human-gated, never merged by it).
- Dockerfile: TOOLCHAIN_EPOCH
- Makefile: TREE_COMMIT_TOOLCHAIN, TREE_DIGEST_TOOLCHAIN, BUILDER_DIGEST
- configs/portage/crossdev.lock: regenerated from the pre-bump image
- builder image: rebuilt and pushed (${built})"
    git push -u origin "$(branch)"
    ;;
dispatch)
    : "${DISPATCHED_AFTER:?toolchain-bump: DISPATCHED_AFTER is not set}"
    br=$(branch)
    before=${DISPATCHED_AFTER}
    echo "==> Waiting for the dispatched run to register..."
    run_id=""
    for _ in $(seq 1 30); do
        run_id=$(gh run list --workflow=build.yml --branch "${br}" \
            --json databaseId,createdAt,event \
            --jq "[.[] | select(.event==\"workflow_dispatch\" and .createdAt>=\"${before}\")] | sort_by(.createdAt) | last | .databaseId // empty")
        [[ -n "${run_id}" ]] && break
        sleep 10
    done
    if [[ -z "${run_id}" ]]; then
        echo "::warning::Could not find the dispatched build.yml run — check the Actions tab manually."
        out "found=false"
    else
        out "found=true"
        out "run_id=${run_id}"
        out "run_url=https://github.com/${GITHUB_REPOSITORY}/actions/runs/${run_id}"
    fi
    ;;
wait)
    : "${RUN_ID:?toolchain-bump: RUN_ID is not set}"
    mkdir -p "${OUT}"
    deadline=$(( $(date +%s) + 240*60 ))
    status=in_progress
    conclusion=""
    while [[ "$(date +%s)" -lt "${deadline}" ]]; do
        status=$(gh run view "${RUN_ID}" --json status --jq .status)
        if [[ "${status}" == "completed" ]]; then
            conclusion=$(gh run view "${RUN_ID}" --json conclusion --jq .conclusion)
            break
        fi
        sleep 60
    done
    if [[ "${status}" != "completed" ]]; then
        out "conclusion=timed_out"
    else
        out "conclusion=${conclusion}"
    fi
    gh run view "${RUN_ID}" --json jobs \
        --jq '.jobs[] | "- " + .name + ": " + .conclusion' \
        > "${OUT}/job-results.txt" || echo "(job list unavailable)" > "${OUT}/job-results.txt"
    ;;
pr)
    old="${OLD_EPOCH:?toolchain-bump: OLD_EPOCH is not set}"
    new=$(cur_epoch)
    c12=$(printf %.12s "${NEW_COMMIT:?toolchain-bump: NEW_COMMIT is not set}")
    mkdir -p "${OUT}"
    {
        echo "## Toolchain bump"
        echo "TOOLCHAIN_EPOCH \`${old}\` -> \`${new}\`; tree \`${c12}\`; first rebuild: ${FIRST_REBUILD:-false}"
        echo ""
        echo "## Pin diff"
        echo '```diff'
        cat "${OUT}/pins.diff" 2>/dev/null || echo "(no diff captured)"
        echo '```'
        echo ""
        echo "<details><summary>configs/portage/crossdev.lock diff</summary>"
        echo ""
        echo '```diff'
        cat "${OUT}/crossdev.diff" 2>/dev/null || true
        echo '```'
        echo "</details>"
        echo ""
        echo "## Validation"
        if [[ "${BUILD_OUTCOME:-}" != "success" ]]; then
            echo "**BLOCKED** — \`make push-image\` (build-image + push) failed at the new epoch."
            echo "crossdev.lock was regenerated from the PRE-bump image but the new image did not build."
            echo "Full build+CVE+boot validation was NOT run. BUILDER_DIGEST is unchanged."
        elif [[ "${RUN_FOUND:-}" != "true" ]]; then
            echo "**UNKNOWN** — image rebuilt and pushed, but the validation run (\`build.yml\`"
            echo "dispatched on this branch) could not be located. Check the Actions tab manually."
        else
            echo "Full pipeline (build + attestation, which includes the CVE gate) dispatched at: ${RUN_URL:-}"
            echo ""
            echo "Result: **${CONCLUSION:-}**"
            echo ""
            echo "Per-job results:"
            cat "${OUT}/job-results.txt" 2>/dev/null || echo "(unavailable)"
            if [[ "${CONCLUSION:-}" == "timed_out" ]]; then
                echo ""
                echo "The run did not complete within this workflow's wait budget. It may still be running."
            fi
        fi
        echo ""
        echo "---"
        echo "Opened by \`.github/workflows/toolchain-bump.yml\`. **Never merged by it**: a human reviews and merges,"
        echo "since a toolchain bump changes the compiler and libc every target package is built with."
    } > "${OUT}/pr-body.md"
    if [[ "${BUILD_OUTCOME:-}" == "success" && "${RUN_FOUND:-}" == "true" && "${CONCLUSION:-}" == "success" ]]; then
        labels="toolchain-bump,validated"
    else
        labels="toolchain-bump,needs-fixup"
    fi
    gh pr create \
        --title "chore(pins): toolchain ${old} -> ${new}, tree ${c12}" \
        --body-file "${OUT}/pr-body.md" \
        --base main \
        --head "$(branch)" \
        --label full-ci \
        --label "${labels}"
    ;;
*)
    sed -n '2,16p' "$0" >&2
    exit 1
    ;;
esac

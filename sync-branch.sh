#!/bin/bash
#
# sync-branch.sh: Sync commits from facebook/main to a fork's branch using the GitHub API, which when done via GitHub
# Actions, ensures that the commits are signed by GitHub.
#
# Must be run in the directory of the repostiory fork.

set -u
set -o pipefail


main() {
    local sync_branch="${1-}"

    if [[ -z "$sync_branch" ]]; then
        usage
    fi

    if ! git ls-remote --exit-code facebook >/dev/null; then
        git remote add facebook https://github.com/facebook/chef-cookbooks.git
    fi

    echo " • Fetching facebook/main"

    git fetch --quiet facebook main || panic "could not fetch facebook/main"

    if git ls-remote --exit-code --heads origin "$sync_branch"; then
        echo " • Fetching origin/$sync_branch"

        git fetch --quiet origin "$sync_branch" || panic "could not fetch origin/$sync_branch"
    fi

    log " • Syncing commits from facebook/main to origin/$sync_branch"

    sync_commits "$sync_branch"
}

usage() {
    echo "Usage: $0 <sync-branch>"
    exit 1
}

log() {
    echo "$@" >&2
}

panic() {
    log "ERROR:" "$@" && exit 1
}

sync_commits() {
    local sync_branch=$1

    for commit_id in $(git rev-list --topo-order --reverse --first-parent facebook/main); do
        if [[ -n $(find_sync_commit "$sync_branch" "$commit_id") ]]; then
           log " • Found $commit_id, continuing"
           continue
        fi

        sync_commit "$sync_branch" "$commit_id"

        log " • Sleeping for 6 seconds"
        sleep 6
    done
}

sync_commit() {
    local sync_branch=$1
    local commit_id=$2

    echo " • Syncing $commit_id"

    local tree

    if ! tree=$(git rev-parse "$commit_id^{tree}"); then
        panic "could not get commit tree for SHA: $commit_id"
    fi

    local new_parent

    if ! new_parent=$(get_new_parent_for_commit "$sync_branch" "$commit_id"); then
        panic "could not get new parent for SHA: $commit_id"
    fi

    log "   • Creating commit via GitHub API with tree: $tree, new parent commit: $new_parent"

    local api_response

    if ! api_response=$(create_github_commit "$commit_id" "$new_parent" "$tree"); then
        panic "could not create commit via GitHub: $api_response"
    fi

    local new_commit_id

    if ! new_commit_id=$(jq --raw-output '.sha' <<<"$api_response"); then
        panic "could not read SHA from GitHub API response: $api_response"
    fi

    log "   • Updating branch via GitHub API: $new_commit_id"

    if ! api_response=$(update_github_branch "$sync_branch" "$new_commit_id"); then
        panic "could not update destination branch: $sync_branch"
    fi

    log "   • Fetching $sync_branch"

    git fetch --quiet origin "$sync_branch" || panic "could not fetch $sync_branch"
}

find_sync_commit() {
    local sync_branch=$1
    local commit_id=$2

    local sync_commit

    if ! sync_commit=$(git rev-list --ignore-missing --grep="^facebook_commit_id: $commit_id" "origin/$sync_branch" --); then
        panic "could not execute \`git rev-list\`"
    fi

    echo "$sync_commit"

    [[ -n "$sync_commit" ]]
}

get_new_parent_for_commit() {
    local sync_branch=$1
    local commit_id=$2

    local first_parent

    if ! first_parent=$(git rev-list --ignore-missing --max-count 1 "$commit_id^"); then
        panic "could not get first parent commit for SHA: $commit_id"
    fi

    if [[ -z $first_parent ]]; then
        # this is the root commit
        return
    fi

    if ! new_parent=$(find_sync_commit "$sync_branch" "$first_parent"); then
        panic "could not find sync commit for parent SHA: $first_parent"
    fi

    echo "$new_parent"
}

create_github_commit() {
    local commit_id=$1
    local new_parent=$2
    local tree=$3

    local parents="[]"

    if [[ -n $new_parent ]]; then
        parents="[\"$new_parent\"]"
    fi

    cat << EOF | gh api  --input - "/repos/{owner}/{repo}/git/commits"
    {
        "message": "Sync of $commit_id\n\nfacebook_commit_id: $commit_id",
        "parents": $parents,
        "tree":    "$tree"
    }
EOF
}

update_github_branch() {
    local sync_branch=$1
    local sha=$2

    local url

    if git show-ref --verify --quiet "refs/remotes/origin/$sync_branch"; then
        # if the ref exists locally, we've fetched it at least once, which means it
        # exists remotely and can update it directly.
        url="/repos/{owner}/{repo}/git/refs/heads/$sync_branch"
    else
        url="/repos/{owner}/{repo}/git/refs"
    fi

    cat <<EOF | gh api --input - "$url"
    {
        "ref": "refs/heads/$sync_branch",
        "sha": "$sha"
    }
EOF
}

main "$@"

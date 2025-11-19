#!/usr/bin/env bash
set -euo pipefail

# --- Decide which user should perform git actions ---
set_user_to_run() {
    if [[ -n "${RUN_USER:-}" ]]; then
        USER_TO_RUN="$RUN_USER"
    elif id immich &>/dev/null; then
        USER_TO_RUN="immich"
    else
        USER_TO_RUN="$(id -un)"
    fi
    export USER_TO_RUN
}

# --- Core clone/update logic (no privilege switching) ---
git_checkout_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local ref="${3:-main}"

    mkdir -p "$(dirname "$target_dir")"

    if [[ -d "$target_dir/.git" ]]; then
        echo "🔁 Updating repo at $target_dir..."
        git -C "$target_dir" fetch --tags origin
        git -C "$target_dir" checkout "$ref" || {
            echo "Fetching missing ref '$ref'..."
            git -C "$target_dir" fetch origin "refs/tags/$ref:refs/tags/$ref"
            git -C "$target_dir" checkout -f "$ref"
        }
    else
        echo "🧱 Cloning $repo_url → $target_dir (ref: $ref)..."
        git clone --depth 1 --branch "$ref" "$repo_url" "$target_dir" 2>/dev/null \
            || git clone "$repo_url" "$target_dir"
    fi

    git config --global --add safe.directory "$target_dir"
    echo "✅ Repository ready at $target_dir (user: $(id -un))"
}

# --- Safe wrapper: run as USER_TO_RUN if different from current user ---
safe_git_checkout() {
    set_user_to_run
    local repo_url="$1"
    local target_dir="$2"
    local ref="${3:-main}"

    # If we're already the target user, just run directly
    if [[ "$(id -un)" == "$USER_TO_RUN" ]]; then
        git_checkout_repo "$repo_url" "$target_dir" "$ref"
        return
    fi

    # If we're NOT root, and can't switch user, fail gracefully
    if [[ "$(id -un)" != "root" ]]; then
        echo "❌ Cannot switch to $USER_TO_RUN (not root)."
        echo "Run this as $USER_TO_RUN or root."
        exit 1
    fi

    # Run as the target non-root user
    echo "Switching to $USER_TO_RUN for git operations..."
    su "$USER_TO_RUN" bash -c "
        source '$BASH_SOURCE'
        git_checkout_repo '$repo_url' '$target_dir' '$ref'
    "
}

#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Detect whether systemd is actually running as PID 1. Some environments
# (WSL2, many container runtimes, minimal images) ship the `systemctl`
# binary but have no running systemd, which makes `systemctl restart` fail
# with:
#     System has not been booted with systemd as init system (PID 1)
# -------------------------
has_systemd() {
  [[ -d /run/systemd/system ]] && [[ "$(cat /proc/1/comm 2>/dev/null)" == systemd ]]
}

# -------------------------
# Restart a service in a way that works with or without systemd.
# Usage: service_restart <service-name>
# Order of attempts:
#   1. systemctl (when systemd is PID 1)
#   2. Postgres-specific fallback via pg_ctlcluster (covers WSL where
#      /etc/init.d/postgresql does nothing useful on first boot).
#   3. service(8)  — generic sysvinit/WSL-friendly fallback
# -------------------------
service_action() {
  local action="$1"   # start | restart
  local svc="$2"

  if has_systemd; then
    systemctl "$action" "$svc"
    return
  fi

  echo "⚠️  No systemd detected. Using fallback for '$svc' ($action)."

  # Strip a trailing .service for non-systemd tools.
  local short="${svc%.service}"

  # PostgreSQL-specific fallback via pg_ctlcluster — works on Debian/Ubuntu
  # even without systemd, as long as postgresql-common is installed.
  if [[ "$short" == postgresql* ]] && command -v pg_lsclusters >/dev/null 2>&1; then
    local line ver name status failed=0 found=false
    while read -r line; do
      ver=$(awk '{print $1}' <<<"$line")
      name=$(awk '{print $2}' <<<"$line")
      status=$(awk '{print $4}' <<<"$line")
      [[ -z "$ver" || "$ver" == "Ver" ]] && continue
      found=true
      echo "PostgreSQL cluster $ver/$name: $action via pg_ctlcluster..."
      case "$action" in
        start)
          if [[ "$status" == online ]]; then
            echo "PostgreSQL cluster $ver/$name is already running."
          elif ! pg_ctlcluster "$ver" "$name" start; then
            failed=1
          fi
          ;;
        restart)
          pg_ctlcluster "$ver" "$name" restart \
            || pg_ctlcluster "$ver" "$name" start \
            || failed=1
          ;;
      esac
    done < <(pg_lsclusters --no-header 2>/dev/null || pg_lsclusters)
    if [[ "$found" == true ]]; then
      return "$failed"
    fi
  fi

  # Generic fallback via service(8).
  if command -v service >/dev/null 2>&1; then
    service "$short" "$action" && return 0
  fi

  echo "❌ service_action: no working mechanism to $action '$svc'." >&2
  return 1
}

service_start()   { service_action start   "$1"; }
service_restart() { service_action restart "$1"; }

# -------------------------
# Environment-file helpers
# -------------------------
shell_env_escape() {
  local value="$1"
  local escaped="" char i
  local LC_ALL=C

  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
    echo "❌ Environment values cannot contain newlines." >&2
    return 1
  }

  # Backslash-escape every byte. This representation is understood identically
  # by Bash assignments and systemd's EnvironmentFile parser, including spaces,
  # quotes, dollar signs, backticks, and backslashes.
  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    escaped+="\\$char"
  done
  printf '%s' "$escaped"
}

replace_key_value_line() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp replaced=false line

  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      printf '%s=%s\n' "$key" "$value" >> "$tmp"
      replaced=true
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  if [[ "$replaced" == false ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi

  chmod --reference="$file" "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
}

# -------------------------
# Choose user for git ops
# -------------------------
# Honors $RUN_USER when set and resolvable as a Linux user — callers
# (pre-install.sh) export RUN_USER=immich after creating the account so git
# checkouts land in a tree immich actually owns. Falls back to the current
# user otherwise. safe_git_checkout is responsible for performing the
# privilege drop via `su` when the chosen user differs from the caller.
choose_user() {
  local u="${RUN_USER:-}"
  if [[ -n "$u" ]] && id -u "$u" >/dev/null 2>&1; then
    echo "$u"
  else
    id -un
  fi
}

# -------------------------
# Core git logic (DESTROYS local state)
# -------------------------
git_force_checkout() {
  local repo="$1"
  local dir="$2"
  local ref="${3:-main}"
  local with_submodules="${4:-false}"

  mkdir -p "$(dirname "$dir")"

  # If $dir exists but is not a git repo (stale/partial from an earlier run),
  # wipe it so the clone below starts fresh. Without this, the fetch below
  # would fail with "not a git repository" and leave the tree empty.
  if [[ -d "$dir" && ! -d "$dir/.git" ]]; then
    echo "⚠️  $dir exists but is not a git repo — removing so we can clone fresh."
    rm -rf "$dir"
  fi

  if [[ ! -d "$dir/.git" ]]; then
    git clone "$repo" "$dir"
  fi

  cd "$dir"

  # Make workspace disposable
  git fetch --all --tags
  git reset --hard HEAD
  git clean -fdx

  if git rev-parse --verify "$ref^{commit}" >/dev/null 2>&1; then
    git checkout -f --detach "$ref"
  else
    git checkout -B "$ref" "origin/$ref"
    git reset --hard "origin/$ref"
  fi

  git clean -fdx
  git config --global --add safe.directory "$dir"

  if [[ "$with_submodules" == "true" ]]; then
    git submodule sync --recursive
    git submodule update --init --recursive --depth 1 --recommend-shallow --force
  fi

  echo "✅ Ready: $dir ($(id -un))"
}

# -------------------------
# Public entrypoint
# -------------------------
safe_git_checkout() {
  local repo="$1"
  local dir="$2"
  local ref="${3:-main}"
  local with_submodules="${4:-false}"

  local user
  user="$(choose_user)"

  if [[ "$(id -un)" == "$user" ]]; then
    git_force_checkout "$repo" "$dir" "$ref" "$with_submodules"
    return
  fi

  [[ "$(id -un)" == "root" ]] || {
    echo "❌ Must be root to switch user"
    exit 1
  }

  # `set -euo pipefail` is crucial inside the su'd shell: without it, a
  # failed `git clone` or `cd` prints an error and the shell continues on,
  # the final `echo "✅ Ready"` returns 0, and the parent script proceeds
  # as if the checkout succeeded.
  su "$user" -s /bin/bash -c \
    "set -euo pipefail; $(declare -f git_force_checkout); git_force_checkout '$repo' '$dir' '$ref' '$with_submodules'"
}

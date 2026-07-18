#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
runtime_env="${2:-}"
resolved_runtime_env="$(readlink -f -- "$runtime_env" 2>/dev/null || true)"

if [[ -z "$resolved_runtime_env" || ! -f "$resolved_runtime_env" ]]; then
    echo "Immich runtime environment not found: $runtime_env" >&2
    exit 1
fi

# install.sh creates the stable runtime-env symlink with its target directly
# under INSTALL_DIR. Recover the application location from that target so this
# launcher never depends on the installer checkout or its .env file.
INSTALL_DIR="$(dirname -- "$resolved_runtime_env")"
set -a
# shellcheck disable=SC1090
. "$resolved_runtime_env"
set +a

case "$mode" in
    ml)
        exec /bin/bash "$INSTALL_DIR/app/machine-learning/start.sh"
        ;;
    web)
        exec /bin/bash "$INSTALL_DIR/app/start.sh"
        ;;
    *)
        echo "Usage: $0 {ml|web} runtime-env" >&2
        exit 2
        ;;
esac

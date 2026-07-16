#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-/workspace}"
SNAPSHOT_DIR=/opt/immich-in-lxc-test-source
TEST_BRANCH=container-integration
RUN_USER=immich
RUN_USER_HOME="/home/$RUN_USER"
USER_PASSWORD=container-user-password
DB_PASSWORD=container-db-password
# Optional: validate a specific Immich release without changing example.env.
TEST_REPO_TAG="${TEST_REPO_TAG:-}"

if [[ "$(cat /proc/1/comm)" != systemd ]]; then
    echo "The full installation test requires systemd as PID 1." >&2
    exit 1
fi

# Named cache volumes are mounted before this disposable guest has an immich
# account, so Docker initially creates their paths as root. Create the test
# account early and hand only the cache paths to it; pre-install.sh remains
# responsible for all normal account configuration and credentials.
if [[ "${TEST_PERSISTENT_CACHE:-0}" == 1 ]]; then
    if ! id "$RUN_USER" >/dev/null 2>&1; then
        adduser --shell /bin/bash --disabled-password --gecos "Immich Mich" "$RUN_USER"
    fi
    install -d -o "$RUN_USER" -g "$RUN_USER" \
        "$RUN_USER_HOME/build" \
        "$RUN_USER_HOME/.cache" \
        "$RUN_USER_HOME/.local/share/pnpm/store" \
        "$RUN_USER_HOME/.nvm/.cache"
    chown -R "$RUN_USER:$RUN_USER" \
        "$RUN_USER_HOME/build" \
        "$RUN_USER_HOME/.cache" \
        "$RUN_USER_HOME/.local/share/pnpm/store" \
        "$RUN_USER_HOME/.nvm/.cache"
fi

# Turn the mounted, possibly dirty workspace into a local committed remote so
# pre-install.sh clones the exact code under test rather than the public branch.
rm -rf "$SNAPSHOT_DIR"
cp -a "$REPO_DIR" "$SNAPSHOT_DIR"
rm -rf "$SNAPSHOT_DIR/.git"
chown -R root:root "$SNAPSHOT_DIR"
git -C "$SNAPSHOT_DIR" init -b "$TEST_BRANCH"
git -C "$SNAPSHOT_DIR" config user.name "Installer Smoke Test"
git -C "$SNAPSHOT_DIR" config user.email "installer-smoke@example.invalid"
git -C "$SNAPSHOT_DIR" add -A
git -C "$SNAPSHOT_DIR" add -f runtime.env
git -C "$SNAPSHOT_DIR" commit -m "container integration snapshot"
# The service user clones this local root-owned test remote. Trust only this
# ephemeral snapshot (and its Git directory) system-wide inside the container.
git config --system --add safe.directory "$SNAPSHOT_DIR"
git config --system --add safe.directory "$SNAPSHOT_DIR/.git"

cd "$SNAPSHOT_DIR"
export RUN_USER USER_PASSWORD DB_PASSWORD
export THIS_REPO_URL="file://$SNAPSHOT_DIR"
export THIS_REPO_REF="$TEST_BRANCH"
./pre-install.sh

# install.sh deliberately asks before replacing app/. Feed only that explicit
# confirmation and otherwise run exactly as the service account would.
RUN_USER_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
if [[ "${TEST_CUDA:-0}" == 1 ]]; then
    nvidia-smi >/dev/null
    "$SNAPSHOT_DIR/scripts/install-cuda-runtime.sh"
    sed -i 's/^isCUDA=.*/isCUDA=true/' "$RUN_USER_HOME/immich-in-lxc/.env"
fi
if [[ -n "$TEST_REPO_TAG" ]]; then
    sed -i "s/^REPO_TAG=.*/REPO_TAG=$TEST_REPO_TAG/" "$RUN_USER_HOME/immich-in-lxc/.env"
fi
runuser -l "$RUN_USER" -c \
    "cd '$RUN_USER_HOME/immich-in-lxc' && printf 'Y\\n' | ./install.sh"

if [[ "${TEST_CUDA:-0}" == 1 ]]; then
    runuser -u "$RUN_USER" -- \
        "$RUN_USER_HOME/app/machine-learning/venv/bin/python" \
        "$SNAPSHOT_DIR/tests/verify-cuda.py"
fi

systemctl daemon-reload
systemctl start immich-ml.service immich-web.service

echo "Verifying the native libvips/libraw media stack used by Sharp..."
dng_coder=$(find /usr/local/lib -path '*/ImageMagick-*/modules-*/coders/dng.so' -print -quit)
test -n "$dng_coder"
ldd "$dng_coder" | grep -q '/usr/local/lib/libraw_r.so'

sharp_addon=$(find "$RUN_USER_HOME/app/node_modules" \
    -path '*sharp*/src/build/Release/sharp-linux-x64.node' -print -quit)
test -n "$sharp_addon"
ldd "$sharp_addon" | grep -q '/usr/local/lib/libvips-cpp.so'
ldd "$sharp_addon" | grep -q '/usr/local/lib/libraw_r.so'

runuser -u "$RUN_USER" -- bash -s -- "$RUN_USER_HOME" "$SNAPSHOT_DIR" <<'USER'
set -euo pipefail
run_user_home="$1"
snapshot_dir="$2"
export NVM_DIR="$run_user_home/.nvm"
. "$NVM_DIR/nvm.sh"
cd "$run_user_home/app"
IMMICH_APP_DIR="$run_user_home/app" node "$snapshot_dir/tests/verify-native-media.js"
USER

for _ in $(seq 1 120); do
    if curl --fail --silent http://127.0.0.1:2283/api/server/ping >/dev/null; then
        systemctl is-active --quiet immich-ml.service
        systemctl is-active --quiet immich-web.service
        echo "Full Immich installation smoke test passed."
        exit 0
    fi
    sleep 2
done

systemctl status --no-pager immich-ml.service immich-web.service || true
journalctl --no-pager -u immich-ml.service -u immich-web.service -n 200 || true
echo "Immich web did not answer /api/server/ping within 240 seconds." >&2
exit 1

#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-/workspace}"
SNAPSHOT_DIR=/opt/immich-in-lxc-test-source
TEST_BRANCH=container-integration
RUN_USER=immich
USER_PASSWORD=container-user-password
DB_PASSWORD=container-db-password

if [[ "$(cat /proc/1/comm)" != systemd ]]; then
    echo "The full installation test requires systemd as PID 1." >&2
    exit 1
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
runuser -l "$RUN_USER" -c \
    "cd '$RUN_USER_HOME/immich-in-lxc' && printf 'Y\\n' | ./install.sh"

if [[ "${TEST_CUDA:-0}" == 1 ]]; then
    runuser -u "$RUN_USER" -- \
        "$RUN_USER_HOME/app/machine-learning/venv/bin/python" \
        "$SNAPSHOT_DIR/tests/verify-cuda.py"
fi

systemctl daemon-reload
systemctl start immich-ml.service immich-web.service

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

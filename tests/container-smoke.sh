#!/usr/bin/env bash
set -euo pipefail

MODE="${1:?usage: container-smoke.sh portable|non-systemd|systemd}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"

cd "$REPO_DIR"

bash -n helpers.sh pre-install.sh install.sh service-launch.sh

# The execution guards make the installer functions testable without running
# package installation or touching the host.
# shellcheck disable=SC1091
. "$REPO_DIR/helpers.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/pre-install.sh"

RUN_USER=root
set_common_variables
[[ "$RUN_USER_HOME" == /root ]]

# shellcheck disable=SC1091
. "$REPO_DIR/install.sh"

for key in REPO_TAG INSTALL_DIR UPLOAD_DIR isCUDA PROXY_NPM PROXY_NPM_DIST PROXY_POETRY; do
    grep -q "^${key}=" example.env
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Verify that special characters round-trip through the generated shell env
# and that the resulting credential-bearing file is private.
password="dollar\$ bang! quote' slash\\ end"
mkdir -p "$tmp_dir/home/.config/immich-in-lxc" "$tmp_dir/install"
printf '%s\n' "$password" > "$tmp_dir/home/.config/immich-in-lxc/db-password"
chmod 0600 "$tmp_dir/home/.config/immich-in-lxc/db-password"

SCRIPT_DIR="$REPO_DIR"
INSTALL_DIR="$tmp_dir/install"
DB_PASSWORD_FILE="$tmp_dir/home/.config/immich-in-lxc/db-password"
HOME="$tmp_dir/home"
create_runtime_env_file

[[ "$(stat -c '%a' "$INSTALL_DIR/runtime.env")" == 600 ]]
[[ "$(readlink "$HOME/.config/immich-in-lxc/runtime.env")" == "$INSTALL_DIR/runtime.env" ]]
actual_password="$(bash -c 'set -a; . "$1"; printf %s "$DB_PASSWORD"' _ "$INSTALL_DIR/runtime.env")"
[[ "$actual_password" == "$password" ]]
grep -q "^MACHINE_LEARNING_CACHE_FOLDER=$INSTALL_DIR/ml-models$" "$INSTALL_DIR/runtime.env"

rotated_password="rotated'pass"
printf '%s\n' "$rotated_password" > "$DB_PASSWORD_FILE"
printf '%s\n' 'PRESERVE_ME=yes' >> "$INSTALL_DIR/runtime.env"
create_runtime_env_file
actual_password="$(bash -c 'set -a; . "$1"; printf %s "$DB_PASSWORD"' _ "$INSTALL_DIR/runtime.env")"
[[ "$actual_password" == "$rotated_password" ]]
grep -q '^PRESERVE_ME=yes$' "$INSTALL_DIR/runtime.env"

# Verify custom INSTALL_DIR dispatch independently of systemd. The launcher
# locates it through the installed runtime.env, not through the repo checkout.
launcher_dir="$tmp_dir/libexec"
custom_install="$tmp_dir/custom-install"
stable_runtime_env="$tmp_dir/stable-runtime.env"
mkdir -p "$launcher_dir" "$custom_install/app/machine-learning"
cp "$REPO_DIR/service-launch.sh" "$launcher_dir/service-launch.sh"
chmod +x "$launcher_dir/service-launch.sh"
printf 'IMMICH_ENV=production\n' > "$custom_install/runtime.env"
ln -s "$custom_install/runtime.env" "$stable_runtime_env"
printf '#!/usr/bin/env bash\nprintf ml > %q\n' "$tmp_dir/launched" > "$custom_install/app/machine-learning/start.sh"
printf '#!/usr/bin/env bash\nprintf web > %q\n' "$tmp_dir/launched" > "$custom_install/app/start.sh"
chmod +x "$custom_install/app/machine-learning/start.sh" "$custom_install/app/start.sh"
"$launcher_dir/service-launch.sh" ml "$stable_runtime_env"
[[ "$(<"$tmp_dir/launched")" == ml ]]
"$launcher_dir/service-launch.sh" web "$stable_runtime_env"
[[ "$(<"$tmp_dir/launched")" == web ]]

# Unit generation must target the root-installed launcher, never the repo.
mkdir -p "$tmp_dir/units"
RUN_USER=photos
RUN_GROUP=media
RUN_USER_HOME="$tmp_dir/service-home"
SYSTEMD_UNIT_DIR="$tmp_dir/units"
SERVICE_LAUNCH_DIR="$launcher_dir"
copy_service_files
grep -q "User=photos" "$tmp_dir/units/immich-ml.service"
grep -q "Group=media" "$tmp_dir/units/immich-ml.service"
grep -q "EnvironmentFile=$RUN_USER_HOME/.config/immich-in-lxc/runtime.env" "$tmp_dir/units/immich-ml.service"
grep -q "$launcher_dir/service-launch.sh ml $RUN_USER_HOME/.config/immich-in-lxc/runtime.env" "$tmp_dir/units/immich-ml.service"
grep -q "$launcher_dir/service-launch.sh web $RUN_USER_HOME/.config/immich-in-lxc/runtime.env" "$tmp_dir/units/immich-web.service"
if grep -RqsF "$RUN_USER_HOME/immich-in-lxc" "$tmp_dir/units"; then
    echo "A systemd unit still depends on the installer checkout." >&2
    exit 1
fi

case "$MODE" in
    portable)
        ;;
    non-systemd)
        if has_systemd; then
            echo "Expected a container without systemd as PID 1" >&2
            exit 1
        fi

        mock_bin="$tmp_dir/mock-bin"
        mkdir -p "$mock_bin"
        cat > "$mock_bin/pg_lsclusters" <<'EOF'
#!/usr/bin/env bash
printf '17 main 5432 online postgres /var/lib/postgresql/17/main /var/log/postgresql/postgresql-17-main.log\n'
EOF
        cat > "$mock_bin/pg_ctlcluster" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$tmp_dir/pg-actions'
EOF
        chmod +x "$mock_bin/pg_lsclusters" "$mock_bin/pg_ctlcluster"
        PATH="$mock_bin:$PATH" service_restart postgresql.service
        grep -q '^17 main restart$' "$tmp_dir/pg-actions"
        printf '#!/usr/bin/env bash\nexit 1\n' > "$mock_bin/pg_ctlcluster"
        chmod +x "$mock_bin/pg_ctlcluster"
        if PATH="$mock_bin:$PATH" service_restart postgresql.service >/dev/null 2>&1; then
            echo "PostgreSQL fallback unexpectedly hid a restart failure" >&2
            exit 1
        fi
        ;;
    systemd)
        has_systemd
        [[ "$(cat /proc/1/comm)" == systemd ]]

        # Generate and start the real ML unit against a disposable custom
        # INSTALL_DIR. This catches unit-path and launcher regressions.
        mkdir -p "$RUN_USER_HOME/.config/immich-in-lxc"
        systemd_password="systemd dollar\$ quote' slash\\ value"
        printf 'IMMICH_ENV=production\nDB_PASSWORD=%s\n' \
            "$(shell_env_escape "$systemd_password")" \
            > "$custom_install/runtime.env"
        ln -sfn "$custom_install/runtime.env" "$RUN_USER_HOME/.config/immich-in-lxc/runtime.env"
        printf '#!/usr/bin/env bash\nprintf %%s "$DB_PASSWORD" > %q\nexec sleep 30\n' \
            "$tmp_dir/systemd-password" \
            > "$custom_install/app/machine-learning/start.sh"
        chmod +x "$custom_install/app/machine-learning/start.sh"
        mkdir -p /var/log/immich
        RUN_USER=root
        RUN_GROUP=root
        RUN_USER_HOME="$tmp_dir/service-home"
        SYSTEMD_UNIT_DIR=/etc/systemd/system
        SERVICE_LAUNCH_DIR="$launcher_dir"
        copy_service_files
        systemctl daemon-reload
        systemctl start immich-ml.service
        systemctl is-active --quiet immich-ml.service
        for _ in $(seq 1 50); do
            [[ -f "$tmp_dir/systemd-password" ]] && break
            sleep 0.1
        done
        [[ "$(<"$tmp_dir/systemd-password")" == "$systemd_password" ]]
        systemctl stop immich-ml.service

        cat > /etc/systemd/system/immich-container-smoke.service <<'EOF'
[Unit]
Description=Immich container smoke test

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
EOF
        systemctl daemon-reload
        service_start immich-container-smoke.service
        systemctl is-active --quiet immich-container-smoke.service
        ;;
    *)
        echo "Unknown mode: $MODE" >&2
        exit 2
        ;;
esac

echo "Container smoke test passed ($MODE)."

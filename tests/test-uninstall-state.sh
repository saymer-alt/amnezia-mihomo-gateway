#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_BIN="$TMP_DIR/bin"
SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
exit 0
EOF

cat > "$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "-4 addr show docker0")
    cat <<'OUT'
6: docker0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
OUT
    ;;
  "rule show")
    echo "0: from all lookup local"
    echo "32766: from all lookup main"
    echo "32767: from all lookup default"
    ;;
  "route show table 100")
    ;;
  *)
    echo "unexpected ip invocation: $*" >&2
    exit 2
    ;;
esac
EOF

cat > "$MOCK_BIN/mihomo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "-t -d "* ]]; then
  exit 0
fi
echo "unexpected mihomo invocation: $*" >&2
exit 2
EOF

chmod +x "$MOCK_BIN/systemctl" "$MOCK_BIN/ip" "$MOCK_BIN/mihomo"

run_uninstall() {
  local case_dir="$1"
  SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  PATH="$MOCK_BIN:$PATH" \
  AMG_STATE_DIR="$case_dir/state" \
  AMG_DOCKER_DAEMON_FILE="$case_dir/etc/docker/daemon.json" \
  AMG_RT_TABLES_FILE="$case_dir/etc/iproute2/rt_tables" \
  AMG_SYSTEMD_DIR="$case_dir/systemd" \
  AMG_SBIN_DIR="$case_dir/sbin" \
  AMG_SYSCTL_FILE="$case_dir/sysctl/99-amnezia-mihomo.conf" \
  bash "$ROOT_DIR/uninstall.sh" >/dev/null
}

prepare_case() {
  local case_dir="$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/etc/docker" "$case_dir/etc/iproute2" \
           "$case_dir/systemd" "$case_dir/sbin" "$case_dir/sysctl" "$case_dir/state"
  : > "$SYSTEMCTL_LOG"
  printf '255 local\n254 main\n253 default\n100 mihomo\n' > "$case_dir/etc/iproute2/rt_tables"
  : > "$case_dir/state/rt_table_added"
}

# Legacy installs had no state markers. Exact installer-generated daemon.json
# must be removed and Docker restarted.
CASE="$TMP_DIR/legacy"
prepare_case "$CASE"
printf '{\n  "dns": ["172.17.0.1"]\n}\n' > "$CASE/etc/docker/daemon.json"
run_uninstall "$CASE"
test ! -e "$CASE/etc/docker/daemon.json"
! grep -Eq '^[[:space:]]*100[[:space:]]+mihomo[[:space:]]*$' "$CASE/etc/iproute2/rt_tables"
grep -Fxq 'restart docker' "$SYSTEMCTL_LOG"
echo "PASS: legacy installer Docker DNS override removed"

# New installs record ownership plus a checksum. If the file still matches,
# uninstall owns it and removes it.
CASE="$TMP_DIR/tracked"
prepare_case "$CASE"
printf '{\n  "dns": ["172.17.0.1"]\n}\n' > "$CASE/etc/docker/daemon.json"
: > "$CASE/state/docker_daemon_created"
sha256sum "$CASE/etc/docker/daemon.json" | awk '{print $1}' > "$CASE/state/docker_daemon_sha256"
run_uninstall "$CASE"
test ! -e "$CASE/etc/docker/daemon.json"
grep -Fxq 'restart docker' "$SYSTEMCTL_LOG"
echo "PASS: tracked installer-owned daemon.json removed"

# If an administrator changed daemon.json after installation, checksum mismatch
# means it is no longer safe for the project to delete it.
CASE="$TMP_DIR/modified"
prepare_case "$CASE"
printf '{\n  "dns": ["172.17.0.1"]\n}\n' > "$CASE/etc/docker/daemon.json"
: > "$CASE/state/docker_daemon_created"
sha256sum "$CASE/etc/docker/daemon.json" | awk '{print $1}' > "$CASE/state/docker_daemon_sha256"
printf '{\n  "dns": ["9.9.9.9"]\n}\n' > "$CASE/etc/docker/daemon.json"
run_uninstall "$CASE"
test -e "$CASE/etc/docker/daemon.json"
grep -Fq '9.9.9.9' "$CASE/etc/docker/daemon.json"
if grep -Fxq 'restart docker' "$SYSTEMCTL_LOG"; then
  echo "FAIL: Docker restarted for a preserved custom daemon.json" >&2
  exit 1
fi
echo "PASS: modified/custom daemon.json preserved"

# An unchanged installer-patched Mihomo config is safe to replace with the exact
# pre-install snapshot.
CASE="$TMP_DIR/mihomo-restore"
prepare_case "$CASE"
printf 'original: true\nprofile:\n  store-selected: true\n' > "$CASE/state/mihomo_config_original.yaml"
printf '%s\n' "$CASE/mihomo-config.yaml" > "$CASE/state/mihomo_config_path"
printf 'patched: true\nprofile:\n  store-selected: false\n' > "$CASE/mihomo-config.yaml"
sha256sum "$CASE/mihomo-config.yaml" | awk '{print $1}' > "$CASE/state/mihomo_patched_sha256"
run_uninstall "$CASE"
grep -Fq 'original: true' "$CASE/mihomo-config.yaml"
grep -Fq 'store-selected: true' "$CASE/mihomo-config.yaml"
test ! -e "$CASE/state/mihomo_config_original.yaml"
echo "PASS: unchanged Mihomo config restored from exact pre-install snapshot"

# If the administrator edited Mihomo after install, uninstall must preserve the
# live config and keep the original snapshot for manual rollback.
CASE="$TMP_DIR/mihomo-modified"
prepare_case "$CASE"
printf 'original: true\n' > "$CASE/state/mihomo_config_original.yaml"
printf '%s\n' "$CASE/mihomo-config.yaml" > "$CASE/state/mihomo_config_path"
printf 'patched: true\n' > "$CASE/mihomo-config.yaml"
printf '%s\n' 'deadbeef' > "$CASE/state/mihomo_patched_sha256"
printf 'admin-change: keep-me\n' > "$CASE/mihomo-config.yaml"
run_uninstall "$CASE"
grep -Fq 'admin-change: keep-me' "$CASE/mihomo-config.yaml"
test -e "$CASE/state/mihomo_config_original.yaml"
echo "PASS: administrator-modified Mihomo config preserved"

# A legacy/untracked rt_tables entry is not safe to delete automatically:
# another administrator could have created the same named table.
CASE="$TMP_DIR/legacy-rt-table"
prepare_case "$CASE"
rm -f "$CASE/state/rt_table_added"
run_uninstall "$CASE"
grep -Eq '^[[:space:]]*100[[:space:]]+mihomo[[:space:]]*$' "$CASE/etc/iproute2/rt_tables"
echo "PASS: untracked legacy rt_tables entry preserved"

echo "All uninstall state regression tests passed."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MOCK_BIN="$TMP_DIR/bin"
SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
MOCK_SYSCTL_DIR="$TMP_DIR/sysctl-live"
mkdir -p "$MOCK_BIN" "$MOCK_SYSCTL_DIR"

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
if [[ "$*" == "is-active --quiet systemd-resolved" ]]; then
  exit 3
fi
if [[ "$*" == "list-unit-files" ]]; then
  echo "mihomo.service enabled"
fi
exit 0
EOF

cat > "$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
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
[[ "${1:-}" == "-t" && "${2:-}" == "-f" && -f "${3:-}" ]]
EOF

cat > "$MOCK_BIN/chattr" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MOCK_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir="${MOCK_SYSCTL_DIR:?}"
key_to_file() { printf '%s/%s\n' "$dir" "${1//\//_}"; }
if [[ "${1:-}" == "-n" ]]; then
  file="$(key_to_file "$2")"
  [[ -f "$file" ]] && cat "$file"
  exit 0
fi
if [[ "${1:-}" == "-w" ]]; then
  kv="$2"
  key="${kv%%=*}"
  value="${kv#*=}"
  printf '%s\n' "$value" > "$(key_to_file "$key")"
  printf '%s = %s\n' "$key" "$value"
  exit 0
fi
echo "unexpected sysctl invocation: $*" >&2
exit 2
EOF

chmod +x "$MOCK_BIN/"*

set_live_sysctl() {
  local key="$1" value="$2"
  printf '%s\n' "$value" > "$MOCK_SYSCTL_DIR/${key//\//_}"
}

get_live_sysctl() {
  local key="$1"
  cat "$MOCK_SYSCTL_DIR/${key//\//_}"
}

prepare_case() {
  local case_dir="$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/state" "$case_dir/etc/docker" "$case_dir/etc/iproute2"            "$case_dir/systemd" "$case_dir/sbin" "$case_dir/sysctl" "$case_dir/proc/all"            "$case_dir/proc/default" "$case_dir/proc/eth0"
  : > "$SYSTEMCTL_LOG"
  printf '255 local\n254 main\n253 default\n100 mihomo\n' > "$case_dir/etc/iproute2/rt_tables"
}

run_uninstall() {
  local case_dir="$1"
  SYSTEMCTL_LOG="$SYSTEMCTL_LOG"   MOCK_SYSCTL_DIR="$MOCK_SYSCTL_DIR"   PATH="$MOCK_BIN:$PATH"   AMG_STATE_DIR="$case_dir/state"   AMG_DOCKER_DAEMON_FILE="$case_dir/etc/docker/daemon.json"   AMG_RT_TABLES_FILE="$case_dir/etc/iproute2/rt_tables"   AMG_SYSTEMD_DIR="$case_dir/systemd"   AMG_SBIN_DIR="$case_dir/sbin"   AMG_SYSCTL_FILE="$case_dir/sysctl/99-amnezia-mihomo.conf"   AMG_RESOLV_CONF="$case_dir/resolv.conf"   AMG_PROC_CONF_DIR="$case_dir/proc"   bash "$ROOT_DIR/uninstall.sh" >/dev/null
}

# 1. Frozen Saymer3-like state after rc.1 uninstall:
# pre-existing rt_tables + daemon.json stay untouched; tracked Mihomo rolls back; state-dir disappears.
CASE="$TMP_DIR/saymer3-post-rc"
prepare_case "$CASE"
printf '{"dns":["9.9.9.9"]}\n' > "$CASE/etc/docker/daemon.json"
DAEMON_BEFORE=$(sha256sum "$CASE/etc/docker/daemon.json" | awk '{print $1}')
RT_BEFORE=$(sha256sum "$CASE/etc/iproute2/rt_tables" | awk '{print $1}')
printf 'original: true\nprofile:\n  store-selected: true\n' > "$CASE/state/mihomo_config_original.yaml"
printf '%s\n' "$CASE/mihomo-config.yaml" > "$CASE/state/mihomo_config_path"
printf 'patched: true\nprofile:\n  store-selected: false\n' > "$CASE/mihomo-config.yaml"
sha256sum "$CASE/mihomo-config.yaml" | awk '{print $1}' > "$CASE/state/mihomo_patched_sha256"
run_uninstall "$CASE"
grep -Fq 'original: true' "$CASE/mihomo-config.yaml"
[[ "$(sha256sum "$CASE/etc/docker/daemon.json" | awk '{print $1}')" == "$DAEMON_BEFORE" ]]
[[ "$(sha256sum "$CASE/etc/iproute2/rt_tables" | awk '{print $1}')" == "$RT_BEFORE" ]]
[[ ! -e "$CASE/state" ]]
echo "PASS: Saymer3-like post-RC rollback restores Mihomo and preserves pre-existing state"

# 2. Admin-modified Mihomo must be preserved and state-dir retained.
CASE="$TMP_DIR/mihomo-diverged"
prepare_case "$CASE"
printf 'original: true\n' > "$CASE/state/mihomo_config_original.yaml"
printf '%s\n' "$CASE/mihomo-config.yaml" > "$CASE/state/mihomo_config_path"
printf 'patched: expected\n' > "$CASE/state/mihomo_patched_sha256"
printf 'admin-change: keep-me\n' > "$CASE/mihomo-config.yaml"
if run_uninstall "$CASE"; then
  echo "FAIL: diverged rollback unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq 'admin-change: keep-me' "$CASE/mihomo-config.yaml"
[[ -d "$CASE/state" ]]
echo "PASS: administrator-modified Mihomo is preserved and rollback evidence retained"

# 3. Full tracked install rollback: owned Docker/rt_tables removed, DNS + live sysctl restored.
CASE="$TMP_DIR/full-tracked"
prepare_case "$CASE"

printf '{\n  "dns": ["172.17.0.1"]\n}\n' > "$CASE/etc/docker/daemon.json"
: > "$CASE/state/docker_daemon_created"
sha256sum "$CASE/etc/docker/daemon.json" | awk '{print $1}' > "$CASE/state/docker_daemon_sha256"
: > "$CASE/state/rt_table_added"

printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:3\n' > "$CASE/resolv.conf"
: > "$CASE/state/dns_state_recorded"
: > "$CASE/state/resolved_was_active"
: > "$CASE/state/resolved_was_enabled"
printf 'nameserver 127.0.0.53\n' > "$CASE/state/resolv.conf.original"
sha256sum "$CASE/resolv.conf" | awk '{print $1}' > "$CASE/state/resolv_managed_sha256"

printf '# installer managed\nnet.ipv4.conf.all.rp_filter = 0\n' > "$CASE/sysctl/99-amnezia-mihomo.conf"
: > "$CASE/state/sysctl_state_recorded"
: > "$CASE/state/sysctl_file_existed"
printf '# original admin sysctl file\n' > "$CASE/state/sysctl_file_original"
sha256sum "$CASE/sysctl/99-amnezia-mihomo.conf" | awk '{print $1}' > "$CASE/state/sysctl_file_managed_sha256"
printf 'pfifo_fast\n' > "$CASE/state/sysctl_original_default_qdisc"
printf 'cubic\n' > "$CASE/state/sysctl_original_tcp_congestion_control"
printf '0\n' > "$CASE/state/sysctl_original_ip_forward"
: > "$CASE/state/sysctl_changed_default_qdisc"
: > "$CASE/state/sysctl_changed_tcp_congestion_control"
: > "$CASE/state/sysctl_changed_ip_forward"
printf 'all\t1\ndefault\t1\neth0\t2\n' > "$CASE/state/sysctl_original_rp_filter"
printf '0\n' > "$CASE/proc/all/rp_filter"
printf '0\n' > "$CASE/proc/default/rp_filter"
printf '0\n' > "$CASE/proc/eth0/rp_filter"

set_live_sysctl net.core.default_qdisc fq
set_live_sysctl net.ipv4.tcp_congestion_control bbr
set_live_sysctl net.ipv4.ip_forward 1

run_uninstall "$CASE"
[[ ! -e "$CASE/etc/docker/daemon.json" ]]
! grep -Eq '^[[:space:]]*100[[:space:]]+mihomo[[:space:]]*$' "$CASE/etc/iproute2/rt_tables"
grep -Fq 'nameserver 127.0.0.53' "$CASE/resolv.conf"
grep -Fq '# original admin sysctl file' "$CASE/sysctl/99-amnezia-mihomo.conf"
[[ "$(get_live_sysctl net.core.default_qdisc)" == "pfifo_fast" ]]
[[ "$(get_live_sysctl net.ipv4.tcp_congestion_control)" == "cubic" ]]
[[ "$(get_live_sysctl net.ipv4.ip_forward)" == "0" ]]
[[ "$(cat "$CASE/proc/all/rp_filter")" == "1" ]]
[[ "$(cat "$CASE/proc/default/rp_filter")" == "1" ]]
[[ "$(cat "$CASE/proc/eth0/rp_filter")" == "2" ]]
grep -Fxq 'restart docker' "$SYSTEMCTL_LOG"
grep -Fxq 'enable systemd-resolved' "$SYSTEMCTL_LOG"
grep -Fxq 'start systemd-resolved' "$SYSTEMCTL_LOG"
[[ ! -e "$CASE/state" ]]
echo "PASS: full tracked ownership rollback restores DNS/sysctl and removes owned resources"

echo "All ownership rollback regression tests passed."

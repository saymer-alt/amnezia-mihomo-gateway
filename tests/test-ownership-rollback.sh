#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNINSTALL_SOURCE="${AMG_TEST_UNINSTALL_SOURCE:-$ROOT_DIR/uninstall.sh}"
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
if [[ "$*" == "${MOCK_SYSTEMCTL_FAIL:-}" ]]; then exit 1; fi
if [[ "$*" == "${MOCK_SYSTEMCTL_NOOP:-}" ]]; then exit 0; fi
state="$(dirname "$SYSTEMCTL_LOG")"
case "$*" in
  'is-active --quiet systemd-resolved')
    [[ "$(cat "$state/resolved.active" 2>/dev/null || echo inactive)" == active ]] && exit 0
    exit 3 ;;
  'is-enabled systemd-resolved')
    value="$(cat "$state/resolved.enabled" 2>/dev/null || echo disabled)"
    echo "$value"; [[ "$value" == enabled ]]; exit ;;
  'show systemd-resolved --property=ActiveState --value') cat "$state/resolved.active"; exit ;;
  'is-enabled --quiet systemd-resolved') [[ "$(cat "$state/resolved.enabled")" == enabled ]]; exit ;;
  'disable --now systemd-resolved') echo disabled > "$state/resolved.enabled"; echo inactive > "$state/resolved.active" ;;
  'enable systemd-resolved') echo enabled > "$state/resolved.enabled" ;;
  'disable systemd-resolved') echo disabled > "$state/resolved.enabled" ;;
  'start systemd-resolved') echo active > "$state/resolved.active" ;;
  'stop systemd-resolved') echo inactive > "$state/resolved.active" ;;
esac
if [[ "$*" == "list-unit-files" ]]; then
  echo "mihomo.service enabled"
fi
exit 0
EOF

cat > "$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  '-4 addr show docker0') echo '    inet 172.17.0.1/16 scope global docker0' ;;
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
if [[ "$1" == "${MOCK_CHATTR_FAIL:-}" ]]; then exit 1; fi
state="$(dirname "$SYSTEMCTL_LOG")"
case "$1" in -i) echo '----------------------' > "$state/resolv.attrs";; +i) echo '----i-----------------' > "$state/resolv.attrs";; esac
exit 0
EOF

cat > "$MOCK_BIN/lsattr" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_LSATTR_FAIL:-0}" == 1 ]]; then exit 1; fi
printf '%s %s\n' "$(cat "$(dirname "$SYSTEMCTL_LOG")/resolv.attrs")" "$2"
EOF

cat > "$MOCK_BIN/cp" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_CP_FAIL:-0}" == 1 && "$*" == *--remove-destination* ]]; then exit 1; fi
if [[ "${MOCK_CP_ADMIN_EDIT:-0}" == 1 && "$*" == *--remove-destination* ]]; then
  printf 'nameserver 8.8.4.4\n' > "${AMG_RESOLV_CONF:?}"
fi
exec /bin/cp "$@"
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
  echo inactive > "$TMP_DIR/resolved.active"
  echo disabled > "$TMP_DIR/resolved.enabled"
  echo '----i-----------------' > "$TMP_DIR/resolv.attrs"
  unset MOCK_SYSTEMCTL_FAIL MOCK_SYSTEMCTL_NOOP MOCK_CHATTR_FAIL MOCK_LSATTR_FAIL MOCK_CP_FAIL MOCK_CP_ADMIN_EDIT
  printf '255 local\n254 main\n253 default\n100 mihomo\n' > "$case_dir/etc/iproute2/rt_tables"
}

run_uninstall() {
  local case_dir="$1"
  SYSTEMCTL_LOG="$SYSTEMCTL_LOG"   MOCK_SYSCTL_DIR="$MOCK_SYSCTL_DIR"   PATH="$MOCK_BIN:$PATH"   AMG_STATE_DIR="$case_dir/state"   AMG_DOCKER_DAEMON_FILE="$case_dir/etc/docker/daemon.json"   AMG_RT_TABLES_FILE="$case_dir/etc/iproute2/rt_tables"   AMG_SYSTEMD_DIR="$case_dir/systemd"   AMG_SBIN_DIR="$case_dir/sbin"   AMG_SYSCTL_FILE="$case_dir/sysctl/99-amnezia-mihomo.conf"   AMG_RESOLV_CONF="$case_dir/resolv.conf"   AMG_PROC_CONF_DIR="$case_dir/proc"   bash "$UNINSTALL_SOURCE" >/dev/null
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

# #21: fixture helpers model only files and explicit service/attribute states.
prepare_dns() {
  prepare_case "$1"
  printf 'nameserver 1.1.1.1\n' > "$1/resolv.conf"
  printf 'nameserver 9.9.9.9\n' > "$1/state/resolv.conf.original"
  sha256sum "$1/resolv.conf" | awk '{print $1}' > "$1/state/resolv_managed_sha256"
  touch "$1/state/dns_state_recorded" "$1/state/resolved_was_active" "$1/state/resolved_was_enabled"
}
expect_incomplete() {
  if run_uninstall "$1"; then echo 'FAIL: unsafe/incomplete DNS rollback accepted' >&2; exit 1
  else [[ "$?" == 2 ]] || { echo 'FAIL: missing incomplete status' >&2; exit 1; }; fi
  [[ -d "$1/state" ]]
}
assert_no_dns_mutation() {
  ! grep -Eq '^(enable|disable|start|stop) systemd-resolved$' "$SYSTEMCTL_LOG"
}

CASE="$TMP_DIR/missing-original"
prepare_dns "$CASE"; rm "$CASE/state/resolv.conf.original"
expect_incomplete "$CASE"
[[ -f "$CASE/resolv.conf" ]] || { echo 'FAIL: incomplete original snapshot deleted the managed resolver' >&2; exit 1; }
grep -Fq 'nameserver 1.1.1.1' "$CASE/resolv.conf"
assert_no_dns_mutation
echo 'PASS: incomplete original DNS snapshot preserves managed resolver before mutation'

for kind in symlink hardlink; do
  CASE="$TMP_DIR/docker-$kind"; prepare_case "$CASE"
  printf '{"dns":["172.17.0.1"]}\n' > "$CASE/external.json"
  if [[ "$kind" == symlink ]]; then ln -s "$CASE/external.json" "$CASE/etc/docker/daemon.json"
  else ln "$CASE/external.json" "$CASE/etc/docker/daemon.json"; fi
  touch "$CASE/state/docker_daemon_created"
  sha256sum "$CASE/external.json" | awk '{print $1}' > "$CASE/state/docker_daemon_sha256"
  expect_incomplete "$CASE"
  [[ -e "$CASE/etc/docker/daemon.json" && -f "$CASE/external.json" ]]
  ! grep -Fq 'restart docker' "$SYSTEMCTL_LOG"
done
echo 'PASS: same-byte Docker symlink/hardlink divergence is preserved'

for divergence in content enabled active attributes unknown-attributes original-directory contradictory; do
  CASE="$TMP_DIR/dns-$divergence"; prepare_dns "$CASE"
  case "$divergence" in
    content) printf 'nameserver 8.8.4.4\n' > "$CASE/resolv.conf" ;;
    enabled) echo enabled > "$TMP_DIR/resolved.enabled" ;;
    active) echo active > "$TMP_DIR/resolved.active" ;;
    attributes) echo '----------------------' > "$TMP_DIR/resolv.attrs" ;;
    unknown-attributes) export MOCK_LSATTR_FAIL=1 ;;
    original-directory) rm "$CASE/state/resolv.conf.original"; mkdir "$CASE/state/resolv.conf.original" ;;
    contradictory) touch "$CASE/state/resolv_original_missing" ;;
  esac
  before=$(sha256sum "$CASE/resolv.conf")
  expect_incomplete "$CASE"
  [[ "$(sha256sum "$CASE/resolv.conf")" == "$before" ]]
  assert_no_dns_mutation
done
echo 'PASS: admin content/service/attribute divergence and invalid snapshots preserved'

for original in symlink missing immutable; do
  CASE="$TMP_DIR/original-$original"; prepare_dns "$CASE"
  case "$original" in
    symlink) rm "$CASE/state/resolv.conf.original"; printf 'target: untouched\n' > "$CASE/resolver-target"; ln -s resolver-target "$CASE/state/resolv.conf.original" ;;
    missing) rm "$CASE/state/resolv.conf.original"; touch "$CASE/state/resolv_original_missing" ;;
    immutable) touch "$CASE/state/resolv_original_immutable" ;;
  esac
  run_uninstall "$CASE"
  [[ ! -e "$CASE/state" ]]
  case "$original" in
    symlink) [[ -L "$CASE/resolv.conf" && "$(readlink "$CASE/resolv.conf")" == resolver-target ]]; grep -Fq untouched "$CASE/resolver-target" ;;
    missing) [[ ! -e "$CASE/resolv.conf" && ! -L "$CASE/resolv.conf" ]] ;;
    immutable) grep -q i "$TMP_DIR/resolv.attrs"; grep -Fq 'nameserver 9.9.9.9' "$CASE/resolv.conf" ;;
  esac
done
echo 'PASS: original symlink/missing/immutable forms and service states restored'

for fault in clear-immutable set-immutable copy enable start enable-noop start-noop; do
  CASE="$TMP_DIR/fault-$fault"; prepare_dns "$CASE"
  case "$fault" in
    clear-immutable) export MOCK_CHATTR_FAIL=-i ;;
    set-immutable) touch "$CASE/state/resolv_original_immutable"; export MOCK_CHATTR_FAIL=+i ;;
    copy) export MOCK_CP_FAIL=1 ;;
    enable) export MOCK_SYSTEMCTL_FAIL='enable systemd-resolved' ;;
    start) export MOCK_SYSTEMCTL_FAIL='start systemd-resolved' ;;
    enable-noop) export MOCK_SYSTEMCTL_NOOP='enable systemd-resolved' ;;
    start-noop) export MOCK_SYSTEMCTL_NOOP='start systemd-resolved' ;;
  esac
  expect_incomplete "$CASE"
  [[ -f "$CASE/resolv.conf" && -f "$CASE/state/resolv.conf.original" ]]
  if [[ "$fault" == copy || "$fault" == clear-immutable ]]; then
    grep -Fq 'nameserver 1.1.1.1' "$CASE/resolv.conf"
    assert_no_dns_mutation
  fi
done
echo 'PASS: copy/immutable/service failure and false-success readback retain evidence/status 2'
CASE="$TMP_DIR/edit-during-staging"; prepare_dns "$CASE"
export MOCK_CP_ADMIN_EDIT=1
expect_incomplete "$CASE"
grep -Fq 'nameserver 8.8.4.4' "$CASE/resolv.conf"
assert_no_dns_mutation
echo 'PASS: administrator edit during snapshot staging is preserved'

# Execute only the real DNS admission block, with its TWO constant path
# assignments redirected to fixture paths; never invoke the full installer.
DNS_FRAGMENT="$TMP_DIR/install-dns.sh"
printf 'set -e\nSTATE_DIR="$AMG_TEST_STATE"\n' > "$DNS_FRAGMENT"
awk '/^# 2.6 DNS:/ { capture=1 } /^# 2.7 / { capture=0 } capture { print }' "$ROOT_DIR/install.sh" |
  sed -e 's@^RESOLV_CONF="/etc/resolv.conf"$@RESOLV_CONF="${AMG_TEST_RESOLV:?}"@' \
      -e 's@^DOCKER_DAEMON_FILE="/etc/docker/daemon.json"$@DOCKER_DAEMON_FILE="${AMG_TEST_DOCKER:?}"@' >> "$DNS_FRAGMENT"
grep -Fq 'RESOLV_CONF="${AMG_TEST_RESOLV:?}"' "$DNS_FRAGMENT"
grep -Fq 'DOCKER_DAEMON_FILE="${AMG_TEST_DOCKER:?}"' "$DNS_FRAGMENT"
! grep -Fq '"/etc/resolv.conf"' "$DNS_FRAGMENT"
! grep -Fq '"/etc/docker/daemon.json"' "$DNS_FRAGMENT"
run_dns_admission() {
  SYSTEMCTL_LOG="$SYSTEMCTL_LOG" PATH="$MOCK_BIN:$PATH" \
    AMG_TEST_STATE="$1/state" AMG_TEST_RESOLV="$1/resolv.conf" \
    AMG_TEST_DOCKER="$1/etc/docker/daemon.json" bash "$DNS_FRAGMENT" >/dev/null
}
CASE="$TMP_DIR/dangling-create"; prepare_case "$CASE"
ln -s "$CASE/foreign.json" "$CASE/etc/docker/daemon.json"
run_dns_admission "$CASE"
[[ -L "$CASE/etc/docker/daemon.json" && ! -e "$CASE/foreign.json" ]]
[[ ! -e "$CASE/state/docker_daemon_created" ]]

CASE="$TMP_DIR/reinstall-reactivated"; prepare_dns "$CASE"
echo active > "$TMP_DIR/resolved.active"
if run_dns_admission "$CASE"; then echo 'FAIL: reactivated admin DNS overwritten'; exit 1; fi
grep -Fq 'nameserver 1.1.1.1' "$CASE/resolv.conf"
! grep -Fq 'disable --now systemd-resolved' "$SYSTEMCTL_LOG"

for fault in disable unknown-attributes partial-state; do
  CASE="$TMP_DIR/admission-$fault"; prepare_case "$CASE"
  printf 'nameserver 9.9.9.9\n' > "$CASE/resolv.conf"
  echo active > "$TMP_DIR/resolved.active"; echo enabled > "$TMP_DIR/resolved.enabled"
  case "$fault" in
    disable) export MOCK_SYSTEMCTL_FAIL='disable --now systemd-resolved' ;;
    unknown-attributes) export MOCK_LSATTR_FAIL=1 ;;
    partial-state) touch "$CASE/state/resolved_was_active" ;;
  esac
  if run_dns_admission "$CASE"; then echo 'FAIL: uncertain DNS admission accepted'; exit 1; fi
  grep -Fq 'nameserver 9.9.9.9' "$CASE/resolv.conf"
  [[ ! -e "$CASE/state/resolv_managed_sha256" ]]
done
echo 'PASS: installer dangling symlink, reactivated DNS, failed disable and unknown/partial admission'
echo "All ownership rollback regression tests passed."

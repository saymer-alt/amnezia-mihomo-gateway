#!/usr/bin/env bash
# AMG-01: the actual installer sysctl block must survive reinstall + a simulated reboot.
# Entire suite uses temp files and mocked sysctl; it never touches host /etc or /proc.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

# Extract the *product* block, replacing only the hardcoded paths for the fixture.
awk '
  /^# 2\. SYSCTL:/ { capture=1 }
  /^# 2\.5 / { capture=0 }
  capture { print }
' "$ROOT_DIR/install.sh" |
  sed -e 's@^SYSCTL_FILE="/etc/sysctl.d/99-amnezia-mihomo.conf"$@SYSCTL_FILE="$AMG_TEST_FILE"@' \
      -e 's@/proc/sys/net/ipv4/conf/\*/rp_filter@"$AMG_TEST_PROC"/*/rp_filter@g' \
  > "$TMP_DIR/installer-sysctl.sh"
grep -Fq 'sysctl_file_managed_sha256' "$TMP_DIR/installer-sysctl.sh" ||
  { echo "FAIL: sysctl installer section could not be extracted" >&2; exit 1; }

cat > "$TMP_DIR/bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -n)
    [[ -f "$AMG_TEST_LIVE/${2:?}" ]] || exit 1
    cat "$AMG_TEST_LIVE/$2"
    ;;
  -p)
    [[ -f "${2:-}" ]] || exit 1
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9._]+)[[:space:]]*=[[:space:]]*([a-zA-Z0-9._]+)[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}" > "$AMG_TEST_LIVE/${BASH_REMATCH[1]}"
      fi
    done < "$2"
    ;;
  *)
    echo "unexpected sysctl invocation: $*" >&2
    exit 2
    ;;
esac
MOCK
chmod +x "$TMP_DIR/bin/sysctl"

fail() { echo "FAIL: $*" >&2; exit 1; }

prepare() {
  CASE="$TMP_DIR/$1"
  STATE_DIR="$CASE/state"
  AMG_TEST_LIVE="$CASE/live"
  AMG_TEST_FILE="$CASE/99-amnezia-mihomo.conf"
  AMG_TEST_PROC="$CASE/proc"
  mkdir -p "$STATE_DIR" "$AMG_TEST_LIVE" "$AMG_TEST_PROC/all" "$AMG_TEST_PROC/default"
  printf '1\n' > "$AMG_TEST_PROC/all/rp_filter"
  printf '1\n' > "$AMG_TEST_PROC/default/rp_filter"
  export STATE_DIR AMG_TEST_LIVE AMG_TEST_FILE AMG_TEST_PROC
}

live() { printf '%s\n' "$2" > "$AMG_TEST_LIVE/$1"; }
assert_live() {
  [[ "$(cat "$AMG_TEST_LIVE/$1")" == "$2" ]] ||
    fail "$1: expected $2, got $(cat "$AMG_TEST_LIVE/$1")"
}
assert_directive() {
  [[ "$(grep -Fc "$1" "$AMG_TEST_FILE" || true)" == "$2" ]] ||
    fail "expected $2 occurrences of $1 in $AMG_TEST_FILE"
}
run_block() {
  PATH="$TMP_DIR/bin:$PATH" YELLOW="" CYAN="" NC="" \
    bash -e "$TMP_DIR/installer-sysctl.sh" >/dev/null
}
reboot_from_defaults() {
  live net.core.default_qdisc pfifo_fast
  live net.ipv4.tcp_congestion_control cubic
  live net.ipv4.ip_forward 0
  PATH="$TMP_DIR/bin:$PATH" sysctl -p "$AMG_TEST_FILE" >/dev/null
}

# Installer owns all three sysctls. Reinstall MUST preserve all three directives
# even though the live kernel already contains the desired values.
prepare owned
printf '# previously existing administrator file\n' > "$AMG_TEST_FILE"
live net.core.default_qdisc pfifo_fast
live net.ipv4.tcp_congestion_control cubic
live net.ipv4.ip_forward 0
run_block
for marker in sysctl_changed_default_qdisc sysctl_changed_tcp_congestion_control sysctl_changed_ip_forward; do
  [[ -f "$STATE_DIR/$marker" ]] || fail "missing ownership marker: $marker"
done
assert_directive 'net.core.default_qdisc = fq' 1
assert_directive 'net.ipv4.tcp_congestion_control = bbr' 1
assert_directive 'net.ipv4.ip_forward = 1' 1
cp "$AMG_TEST_FILE" "$CASE/first-install.conf"
run_block
cmp "$CASE/first-install.conf" "$AMG_TEST_FILE" || fail "reinstall changed owned directives"
grep -Fq '# previously existing administrator file' "$STATE_DIR/sysctl_file_original" ||
  fail "first pre-install snapshot lost"
reboot_from_defaults
assert_live net.core.default_qdisc fq
assert_live net.ipv4.tcp_congestion_control bbr
assert_live net.ipv4.ip_forward 1
echo 'PASS: owned BBR/fq/ip_forward survive reinstall and simulated reboot'

# No ownership should be acquired for externally configured BBR and forwarding.
prepare external
live net.core.default_qdisc fq
live net.ipv4.tcp_congestion_control bbr
live net.ipv4.ip_forward 1
run_block
run_block
assert_directive 'net.core.default_qdisc = fq' 0
assert_directive 'net.ipv4.tcp_congestion_control = bbr' 0
assert_directive 'net.ipv4.ip_forward = 1' 0
for marker in sysctl_changed_default_qdisc sysctl_changed_tcp_congestion_control sysctl_changed_ip_forward; do
  [[ ! -e "$STATE_DIR/$marker" ]] || fail "external settings wrongly claimed: $marker"
done
echo 'PASS: external sysctls are not claimed or persisted by the installer'

# The installer may own forwarding while BBR belongs to another component.
prepare mixed
live net.core.default_qdisc fq
live net.ipv4.tcp_congestion_control bbr
live net.ipv4.ip_forward 0
run_block
run_block
assert_directive 'net.core.default_qdisc = fq' 0
assert_directive 'net.ipv4.tcp_congestion_control = bbr' 0
assert_directive 'net.ipv4.ip_forward = 1' 1
[[ -f "$STATE_DIR/sysctl_changed_ip_forward" ]] ||
  fail 'forwarding ownership marker missing'
[[ ! -e "$STATE_DIR/sysctl_changed_tcp_congestion_control" ]] ||
  fail 'external BBR wrongly claimed on mixed host'
echo 'PASS: mixed ownership remains scoped'

# A drifted live value does not erase previously captured pre-install ownership.
prepare drift
live net.core.default_qdisc pfifo_fast
live net.ipv4.tcp_congestion_control cubic
live net.ipv4.ip_forward 0
run_block
live net.core.default_qdisc pfifo_fast
live net.ipv4.tcp_congestion_control cubic
live net.ipv4.ip_forward 0
run_block
reboot_from_defaults
assert_live net.core.default_qdisc fq
assert_live net.ipv4.tcp_congestion_control bbr
assert_live net.ipv4.ip_forward 1
[[ "$(cat "$STATE_DIR/sysctl_original_tcp_congestion_control")" == cubic ]] ||
  fail 'original congestion control was overwritten'
echo 'PASS: drift does not replace first-install baseline'

for owned in default_qdisc tcp_congestion_control; do
    prepare "partial-$owned"
    live net.core.default_qdisc fq
    live net.ipv4.tcp_congestion_control bbr
    live net.ipv4.ip_forward 1
    : > "$STATE_DIR/sysctl_changed_$owned"
    run_block
    if [[ "$owned" == default_qdisc ]]; then
        assert_directive 'net.core.default_qdisc = fq' 1
        assert_directive 'net.ipv4.tcp_congestion_control = bbr' 0
    else
        assert_directive 'net.core.default_qdisc = fq' 0
        assert_directive 'net.ipv4.tcp_congestion_control = bbr' 1
    fi
done
echo 'PASS: a single ownership marker never admits its external companion'
echo 'All AMG-01 sysctl persistence regression tests passed.'

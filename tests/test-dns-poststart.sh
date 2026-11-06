#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Extract the exact production function, not a duplicate test implementation.
awk '
  /^# BEGIN AMG_DNS53_POSTSTART$/ { capture=1; next }
  /^# END AMG_DNS53_POSTSTART$/ { capture=0 }
  capture { print }
' "$ROOT_DIR/install.sh" > "$TMP_DIR/dns-check.sh"
[[ -s "$TMP_DIR/dns-check.sh" ]] || { echo "FAIL: DNS check not present in installer"; exit 1; }
# shellcheck source=/dev/null
source "$TMP_DIR/dns-check.sh"

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet systemd-resolved")
    [[ "$MOCK_RESOLVED_ACTIVE" == 1 ]] ;;
  "is-active --quiet mihomo.service")
    [[ "$MOCK_MIHOMO_ACTIVE" == 1 ]] ;;
  *) echo "unexpected systemctl call: $*" >&2; exit 2 ;;
esac
EOF
cat > "$TMP_DIR/bin/ss" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *-lntp*)
    [[ "$MOCK_TCP_OWNER" == none ]] || printf 'LISTEN 0 4096 *:53 *:* users:(("%s",pid=1234,fd=7))\n' "$MOCK_TCP_OWNER"
    ;;
  *-lnup*)
    [[ "$MOCK_UDP_OWNER" == none ]] || printf 'UNCONN 0 0 *:53 *:* users:(("%s",pid=1234,fd=9))\n' "$MOCK_UDP_OWNER"
    ;;
  *) echo "unexpected ss call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/"*
export PATH="$TMP_DIR/bin:$PATH"
export MOCK_RESOLVED_ACTIVE=0 MOCK_MIHOMO_ACTIVE=1
export MOCK_TCP_OWNER=mihomo MOCK_UDP_OWNER=mihomo

cat > "$TMP_DIR/default.yaml" <<'EOF'
mode: rule
tun:
  enable: true
dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
EOF
cat > "$TMP_DIR/custom.yaml" <<'EOF'
dns:
  enable: true
  listen: 127.0.0.1:5353
EOF
cat > "$TMP_DIR/disabled.yaml" <<'EOF'
dns:
  enable: false
  listen: 0.0.0.0:53
EOF

expect_ok() {
  if ! amg_check_documented_dns53 "$1" > "$TMP_DIR/out" 2>&1; then
    echo "FAIL: expected PASS in $2" >&2
    cat "$TMP_DIR/out" >&2
    exit 1
  fi
}
expect_fail() {
  if amg_check_documented_dns53 "$1" > "$TMP_DIR/out" 2>&1; then
    echo "FAIL: expected error in $2" >&2
    exit 1
  fi
}

expect_ok "$TMP_DIR/default.yaml" "healthy TCP+UDP listeners"
MOCK_RESOLVED_ACTIVE=1
expect_fail "$TMP_DIR/default.yaml" "resolved reactivated"
MOCK_RESOLVED_ACTIVE=0
MOCK_TCP_OWNER=systemd-resolve
expect_fail "$TMP_DIR/default.yaml" "foreign TCP listener"
MOCK_TCP_OWNER=mihomo MOCK_UDP_OWNER=none
expect_fail "$TMP_DIR/default.yaml" "missing UDP listener"
MOCK_UDP_OWNER=mihomo MOCK_MIHOMO_ACTIVE=0
expect_fail "$TMP_DIR/default.yaml" "mihomo service inactive"
MOCK_MIHOMO_ACTIVE=1

expect_ok "$TMP_DIR/custom.yaml" "non-default listen is not constrained to port 53"
grep -Fq 'SKIP' "$TMP_DIR/out" || { echo "FAIL: missing custom-profile SKIP"; exit 1; }
expect_ok "$TMP_DIR/disabled.yaml" "disabled DNS is not constrained to port 53"
expect_fail "$TMP_DIR/missing.yaml" "missing config must fail"

echo "PASS: installer DNS post-start ownership guard (TCP/UDP, resolved, custom, missing)."

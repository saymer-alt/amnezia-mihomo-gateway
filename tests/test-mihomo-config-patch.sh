#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FRAGMENT="$TMP_DIR/patch-config.sh"
MOCK_BIN="$TMP_DIR/bin"
CALL_LOG="$TMP_DIR/mihomo.calls"
mkdir -p "$MOCK_BIN"

awk '
  /# BEGIN MIHOMO_CONFIG_PATCH/ { capture=1 }
  capture { print }
  /# END MIHOMO_CONFIG_PATCH/ { exit }
' "$ROOT_DIR/install.sh" > "$FRAGMENT"

if ! grep -q '^    patch_mihomo_config()' "$FRAGMENT"; then
  echo "FAIL: scoped Mihomo patcher was not found in install.sh" >&2
  exit 1
fi

if grep -Fq '/tmp/mihomo_config.yaml' "$ROOT_DIR/install.sh"; then
  echo "FAIL: fixed /tmp/mihomo_config.yaml staging path still exists" >&2
  exit 1
fi

if grep -Fq 'store-selected: false, store-fake-ip: false' "$ROOT_DIR/install.sh"; then
  echo "FAIL: installer summary still claims unconditional store-fake-ip: false (DDP contract preserves the generator value)" >&2
  exit 1
fi

cat > "$MOCK_BIN/mihomo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MIHOMO_CALL_LOG:?}"
if [[ "${MIHOMO_TEST_FAIL:-0}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$MOCK_BIN/mihomo"

export FAKE_IP_RANGE="198.18.0.0/16"
export MIHOMO_CALL_LOG="$CALL_LOG"

run_patcher() {
  local config="$1"
  PATH="$MOCK_BIN:$PATH" MIHOMO_CONFIG="$config" bash "$FRAGMENT"
}

assert_line() {
  local config="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$config"; then
    echo "FAIL: $message" >&2
    cat "$config" >&2
    exit 1
  fi
}

assert_absent() {
  local config="$1"
  local pattern="$2"
  local message="$3"
  if grep -Eq "$pattern" "$config"; then
    echo "FAIL: $message" >&2
    cat "$config" >&2
    exit 1
  fi
}

assert_unchanged_on_failure() {
  local config="$1"
  local before="$2"
  local label="$3"
  local after
  after="$(sha256sum "$config" | awk '{print $1}')"
  if [[ "$after" != "$before" ]]; then
    echo "FAIL: $label modified the source file on failure" >&2
    exit 1
  fi
}

CONFIG="$TMP_DIR/config.yaml"
cat > "$CONFIG" <<'EOF'
mixed-port: 7890
dns:
  enable: true
  fake-ip-range: 240.0.0.1/4
tun:
  enable: true
  # auto-route: true
  stack: system
  inet4-address:
    - 10.255.255.1/30
  mtu: 1300
  gso: false
listeners:
  - name: mihomo-tun-1
    type: tun
    device: mitun0
    inet4-address:
      - 198.19.0.1/30
    stack: system
    auto-route: true
    mtu: 1280
proxies:
  - name: WARP
    type: wireguard
    mtu: 1280
profile:
  store-selected: true
  store-fake-ip: true
endpoint-independent-nat: true
EOF

chmod 600 "$CONFIG"
MODE_BEFORE="$(stat -c '%a' "$CONFIG")"
OWNER_BEFORE="$(stat -c '%u:%g' "$CONFIG")"
: > "$CALL_LOG"

run_patcher "$CONFIG"

MODE_AFTER="$(stat -c '%a' "$CONFIG")"
OWNER_AFTER="$(stat -c '%u:%g' "$CONFIG")"
[[ "$MODE_AFTER" == "$MODE_BEFORE" ]] || { echo "FAIL: mode changed $MODE_BEFORE -> $MODE_AFTER" >&2; exit 1; }
[[ "$OWNER_AFTER" == "$OWNER_BEFORE" ]] || { echo "FAIL: owner/group changed $OWNER_BEFORE -> $OWNER_AFTER" >&2; exit 1; }

assert_line "$CONFIG" '^[[:space:]]+fake-ip-range:[[:space:]]+198\.18\.0\.0/16$' 'dns.fake-ip-range was not normalized'
# Domain Detection: generator-owned store-fake-ip value must survive the patcher
assert_line "$CONFIG" '^[[:space:]]+store-fake-ip:[[:space:]]+true$' 'profile.store-fake-ip: true was overwritten by the patcher'
assert_line "$CONFIG" '^find-process-mode:[[:space:]]+off$' 'top-level find-process-mode was not added'
assert_line "$CONFIG" '^[[:space:]]+disable-icmp-forwarding:[[:space:]]+true$' 'tun.disable-icmp-forwarding was not enabled'
assert_line "$CONFIG" '^[[:space:]]+auto-detect-interface:[[:space:]]+true$' 'tun.auto-detect-interface was not inserted'
assert_absent "$CONFIG" '^endpoint-independent-nat:' 'top-level endpoint-independent-nat was not removed'

TOP_TUN="$TMP_DIR/top-tun.txt"
awk '
  /^tun:[[:space:]]*$/ { in_tun=1; next }
  in_tun && /^[^#[:space:]]/ { exit }
  in_tun { print }
' "$CONFIG" > "$TOP_TUN"

grep -Eq '^  stack:[[:space:]]+gvisor$' "$TOP_TUN" || { echo "FAIL: top-level tun.stack not normalized" >&2; exit 1; }
grep -Eq '^  auto-route:[[:space:]]+false$' "$TOP_TUN" || { echo "FAIL: commented auto-route incorrectly satisfied the required key" >&2; exit 1; }
grep -Eq '^  mtu:[[:space:]]+1420$' "$TOP_TUN" || { echo "FAIL: top-level tun.mtu not normalized" >&2; exit 1; }
grep -Eq '^  gso:[[:space:]]+true$' "$TOP_TUN" || { echo "FAIL: top-level tun.gso not normalized" >&2; exit 1; }
if grep -Eq '^  inet4-address:' "$TOP_TUN"; then
  echo "FAIL: legacy top-level tun.inet4-address survived" >&2
  exit 1
fi

assert_line "$CONFIG" '^[[:space:]]{4}stack:[[:space:]]+system$' 'listener stack was unexpectedly rewritten'
assert_line "$CONFIG" '^[[:space:]]{4}auto-route:[[:space:]]+true$' 'listener auto-route was unexpectedly rewritten'
if [[ "$(grep -Ec '^[[:space:]]{4}mtu:[[:space:]]+1280$' "$CONFIG")" -ne 2 ]]; then
  echo "FAIL: listener/proxy MTU values were unexpectedly rewritten" >&2
  cat "$CONFIG" >&2
  exit 1
fi
assert_line "$CONFIG" '^[[:space:]]+inet4-address:$' 'per-proxy listener inet4-address was removed'
assert_line "$CONFIG" '^[[:space:]]+-[[:space:]]+198\.19\.0\.1/30$' 'per-proxy listener inet4-address value was removed'

if ! grep -Eq '^-t -f .*/\.config\.yaml\.amg\.[[:alnum:]]+$' "$CALL_LOG"; then
  echo "FAIL: mihomo -t was not run against a same-directory staged config" >&2
  cat "$CALL_LOG" >&2
  exit 1
fi

SHA_ONCE="$(sha256sum "$CONFIG" | awk '{print $1}')"
run_patcher "$CONFIG"
SHA_TWICE="$(sha256sum "$CONFIG" | awk '{print $1}')"
[[ "$SHA_ONCE" == "$SHA_TWICE" ]] || { echo "FAIL: patcher is not idempotent" >&2; exit 1; }

if find "$TMP_DIR" -maxdepth 1 -name '.config.yaml.amg.*' -print -quit | grep -q .; then
  echo "FAIL: patcher left staging files behind" >&2
  find "$TMP_DIR" -maxdepth 1 -name '.config.yaml.amg.*' -print >&2
  exit 1
fi

NO_PROFILE="$TMP_DIR/no-profile.yaml"
cat > "$NO_PROFILE" <<'EOF'
dns:
  enable: true
tun:
  enable: true
EOF
chmod 640 "$NO_PROFILE"
run_patcher "$NO_PROFILE"
assert_line "$NO_PROFILE" '^profile:$' 'missing profile section was not created'
assert_line "$NO_PROFILE" '^  store-selected:[[:space:]]+false$' 'profile.store-selected was not created'
assert_line "$NO_PROFILE" '^  store-fake-ip:[[:space:]]+false$' 'profile.store-fake-ip was not created'
[[ "$(stat -c '%a' "$NO_PROFILE")" == "640" ]] || { echo "FAIL: 0640 mode was not preserved" >&2; exit 1; }

BAD_VALIDATE="$TMP_DIR/validation-failure.yaml"
cat > "$BAD_VALIDATE" <<'EOF'
dns:
  enable: true
tun:
  enable: true
EOF
BAD_SHA="$(sha256sum "$BAD_VALIDATE" | awk '{print $1}')"
if PATH="$MOCK_BIN:$PATH" MIHOMO_CONFIG="$BAD_VALIDATE" MIHOMO_TEST_FAIL=1 bash "$FRAGMENT"; then
  echo "FAIL: patcher accepted a config rejected by mihomo -t" >&2
  exit 1
fi
assert_unchanged_on_failure "$BAD_VALIDATE" "$BAD_SHA" "mihomo validation failure"

MISSING_TUN="$TMP_DIR/missing-tun.yaml"
cat > "$MISSING_TUN" <<'EOF'
dns:
  enable: true
EOF
MISS_SHA="$(sha256sum "$MISSING_TUN" | awk '{print $1}')"
if run_patcher "$MISSING_TUN"; then
  echo "FAIL: patcher accepted config without top-level tun" >&2
  exit 1
fi
assert_unchanged_on_failure "$MISSING_TUN" "$MISS_SHA" "missing tun"

INLINE_TUN="$TMP_DIR/inline-tun.yaml"
cat > "$INLINE_TUN" <<'EOF'
dns:
  enable: true
tun: { enable: true, auto-route: true }
EOF
INLINE_SHA="$(sha256sum "$INLINE_TUN" | awk '{print $1}')"
if run_patcher "$INLINE_TUN"; then
  echo "FAIL: patcher accepted inline tun mapping" >&2
  exit 1
fi
assert_unchanged_on_failure "$INLINE_TUN" "$INLINE_SHA" "inline tun"

FOUR_SPACE="$TMP_DIR/four-space.yaml"
cat > "$FOUR_SPACE" <<'EOF'
dns:
    enable: true
tun:
    enable: true
EOF
FOUR_SHA="$(sha256sum "$FOUR_SPACE" | awk '{print $1}')"
if run_patcher "$FOUR_SPACE"; then
  echo "FAIL: patcher accepted unsupported direct-child indentation" >&2
  exit 1
fi
assert_unchanged_on_failure "$FOUR_SPACE" "$FOUR_SHA" "unsupported indentation"

REAL="$TMP_DIR/real.yaml"
LINK="$TMP_DIR/link.yaml"
cat > "$REAL" <<'EOF'
dns:
  enable: true
tun:
  enable: true
EOF
ln -s "$REAL" "$LINK"
REAL_SHA="$(sha256sum "$REAL" | awk '{print $1}')"
if run_patcher "$LINK"; then
  echo "FAIL: patcher accepted a symlink config path" >&2
  exit 1
fi
assert_unchanged_on_failure "$REAL" "$REAL_SHA" "symlink refusal"

# Domain Detection compatibility: the link-generators VPS profile emits
# tun.dns-hijack and a top-level sniffer section; the patcher must preserve
# unknown keys verbatim and keep store-fake-ip: true.
DDP="$TMP_DIR/ddp.yaml"
cat > "$DDP" <<'EOF'
mixed-port: 7890
sniffer:
  enable: true
  parse-pure-ip: true
  force-dns-mapping: true
  override-destination: false
  sniff:
    TLS:
      ports:
        - 443
        - 8443
    QUIC:
      ports:
        - 443
        - 8443
    HTTP:
      ports:
        - 80
        - 8080-8880
dns:
  enable: true
tun:
  enable: true
  dns-hijack:
    - any:53
    - tcp://any:53
profile:
  store-selected: false
  store-fake-ip: true
EOF
run_patcher "$DDP"
assert_line "$DDP" '^  store-fake-ip:[[:space:]]+true$' 'Domain Detection store-fake-ip: true was not preserved'
assert_line "$DDP" '^    - any:53$' 'tun.dns-hijack entry was not preserved'
assert_line "$DDP" '^    - tcp://any:53$' 'tun.dns-hijack tcp entry was not preserved'
assert_line "$DDP" '^  override-destination:[[:space:]]+false$' 'sniffer.override-destination was not preserved'
assert_line "$DDP" '^    QUIC:$' 'sniffer QUIC block was not preserved'
grep -Eq '^  fake-ip-range:[[:space:]]+198\.18\.0\.0/16$' "$DDP" || { echo "FAIL: ddp fake-ip-range not normalized" >&2; exit 1; }

# #32: new insertion and an already misplaced managed key must precede the
# trailing next-section comment. Reinstall must preserve every comment/byte.
for existing in missing misplaced; do
  COMMENTS="$TMP_DIR/comments-$existing.yaml"
  cat > "$COMMENTS" <<'EOF'
mixed-port: 7890
tun:
  enable: true
  # Internal TUN comment
  mtu: 1420

# --- DNS SECTION ---
EOF
  if [ "$existing" = misplaced ]; then
    printf '  disable-icmp-forwarding: true\n' >> "$COMMENTS"
  fi
  cat >> "$COMMENTS" <<'EOF'
dns:
  enable: true
EOF
  run_patcher "$COMMENTS"
  awk '
    /^  disable-icmp-forwarding: true$/ { key=NR; count++ }
    /^# --- DNS SECTION ---$/ { comment=NR }
    END { exit !(count == 1 && key < comment) }
  ' "$COMMENTS" || { echo "FAIL: #32 $existing key placement" >&2; exit 1; }
  assert_line "$COMMENTS" '^  # Internal TUN comment$' 'internal TUN comment lost'
  cp "$COMMENTS" "$COMMENTS.first"
  run_patcher "$COMMENTS"
  cmp "$COMMENTS" "$COMMENTS.first" || { echo 'FAIL: comment fixture reinstall drift' >&2; exit 1; }
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 - "$COMMENTS" <<'PY'
import sys, yaml
with open(sys.argv[1]) as stream:
    data = yaml.safe_load(stream)
assert data['tun']['disable-icmp-forwarding'] is True
assert 'disable-icmp-forwarding' not in data['dns']
PY
  fi
done

SCALAR="$TMP_DIR/comments-scalar.yaml"
cat > "$SCALAR" <<'EOF'
tun:
  enable: true
  note: |+
    # This is scalar data, not a YAML comment

# --- DNS SECTION ---
dns:
  enable: true
EOF
cp "$SCALAR" "$SCALAR.original"
run_patcher "$SCALAR"
cp "$SCALAR" "$SCALAR.first"
run_patcher "$SCALAR"
cmp "$SCALAR" "$SCALAR.first"
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$SCALAR.original" "$SCALAR" <<'PY'
import sys, yaml
with open(sys.argv[1]) as stream:
    old = yaml.safe_load(stream)
with open(sys.argv[2]) as stream:
    new = yaml.safe_load(stream)
assert old['tun']['note'] == new['tun']['note']
PY
fi

echo "All scoped Mihomo config patch regression tests passed."

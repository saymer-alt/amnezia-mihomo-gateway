#!/usr/bin/env bash
# test-kit.sh — fixture tests for the live acceptance kit itself.
#
# No VPS, no root, no network: every destructive entry point must REFUSE by
# default, every guard/parser/classifier must behave on fixtures. Runs in CI
# and locally (Git Bash / Linux bash).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/amg-kittest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

expect_refusal() { # $1=label; remaining args = command to run (must exit non-zero)
  local label="$1"
  shift
  local out
  if out=$("$@" 2>&1); then
    fail "$label — unexpectedly succeeded"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
  elif printf '%s' "$out" | grep -qi 'refus'; then
    pass "$label"
  else
    fail "$label — exited non-zero but refusal message missing"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
}

# Non-zero exit is the invariant; the refusal text depends on host capabilities
# (root/docker availability), so this variant accepts any clean abort.
expect_failure() { # $1=label; remaining args = command (must exit non-zero)
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$label — unexpectedly succeeded"
  else
    pass "$label"
  fi
}

# --- syntax of every kit script ------------------------------------------------
for s in "$KIT_DIR"/*.sh; do
  if bash -n "$s" 2>"$TMP/syn.err"; then
    pass "bash -n $(basename "$s")"
  else
    fail "bash -n $(basename "$s")"
    cat "$TMP/syn.err" >&2
  fi
done

# Pins must identify the product blobs shipped with this acceptance kit.
# This reads local files only; it never invokes either installer.
for product in install uninstall; do
  expected="$(bash -c '. "$1/lib.sh"; case "$2" in install) printf "%s" "$EXPECTED_INSTALL_SHA256";; uninstall) printf "%s" "$EXPECTED_UNINSTALL_SHA256";; esac' _ "$KIT_DIR" "$product")"
  actual="$(sha256sum "$KIT_DIR/../../$product.sh")"
  actual="${actual%% *}"
  if [ "$actual" = "$expected" ]; then
    pass "$product acceptance pin matches product blob"
  else
    fail "$product acceptance pin differs from product blob"
  fi
done

# --- §18: no opt-in -> refusal (before any root/docker requirement) -------------
expect_refusal "run-pre-reboot refuses without AMG_DISPOSABLE_TEST_HOST" \
  env -u AMG_DISPOSABLE_TEST_HOST bash "$KIT_DIR/run-pre-reboot.sh" --confirm-disposable

expect_refusal "run-pre-reboot refuses with env but without --confirm-disposable" \
  env AMG_DISPOSABLE_TEST_HOST=YES bash "$KIT_DIR/run-pre-reboot.sh"

expect_refusal "run-post-reboot refuses without opt-in" \
  env -u AMG_DISPOSABLE_TEST_HOST bash "$KIT_DIR/run-post-reboot.sh" --run-dir "$TMP/nonexistent" --confirm-disposable

# --- §18: prior gateway state -> refusal (sandboxed via path overrides) ---------
mkdir -p "$TMP/state" "$TMP/sbin" "$TMP/systemd"
: > "$TMP/state/mihomo_config_path"
expect_refusal "run-pre-reboot refuses on prior ownership state-dir" \
  env AMG_DISPOSABLE_TEST_HOST=YES \
      AMG_STATE_DIR="$TMP/state" AMG_SBIN_DIR="$TMP/sbin" \
      AMG_SYSTEMD_DIR="$TMP/systemd" AMG_RT_TABLES_FILE="$TMP/rt_tables-absent" \
  bash "$KIT_DIR/run-pre-reboot.sh" --confirm-disposable

mkdir -p "$TMP/state-clean"
expect_failure "run-pre-reboot aborts on clean sandbox (root/docker not met here)" \
  env AMG_DISPOSABLE_TEST_HOST=YES \
      AMG_STATE_DIR="$TMP/state-clean" AMG_SBIN_DIR="$TMP/sbin-clean" \
      AMG_SYSTEMD_DIR="$TMP/systemd-clean" AMG_RT_TABLES_FILE="$TMP/rt_tables-clean" \
  bash "$KIT_DIR/run-pre-reboot.sh" --confirm-disposable

# --- §18: wrong stage / wrong run-id / wrong host -> refusal ---------------------
mkdir -p "$TMP/run"
checkpoint_fixture() { # $1=stage $2=machine-id
  printf 'STAGE=%s\nHOSTNAME=fixture\nMACHINE_ID=%s\nCREATED=fixture\n' "$1" "$2" > "$TMP/run/CHECKPOINT"
}
kit_machine="$(bash -c '. "$0/lib.sh"; machine_id' "$KIT_DIR" 2>/dev/null || printf no-machine-id)"

checkpoint_fixture "BASELINE-OK" "$kit_machine"
expect_refusal "run-post-reboot refuses on wrong stage" \
  env AMG_DISPOSABLE_TEST_HOST=YES bash "$KIT_DIR/run-post-reboot.sh" --run-dir "$TMP/run" --confirm-disposable

checkpoint_fixture "READY-FOR-REBOOT" "mismatched-machine-id-fixture"
expect_refusal "run-post-reboot refuses on machine-id mismatch (different host)" \
  env AMG_DISPOSABLE_TEST_HOST=YES bash "$KIT_DIR/run-post-reboot.sh" --run-dir "$TMP/run" --confirm-disposable

checkpoint_fixture "READY-FOR-REBOOT" "$kit_machine"
expect_refusal "run-post-reboot refuses without opt-in even with valid checkpoint" \
  env -u AMG_DISPOSABLE_TEST_HOST bash "$KIT_DIR/run-post-reboot.sh" --run-dir "$TMP/run" --confirm-disposable

# --- §18: secret redaction --------------------------------------------------------
SECRET_YAML="$TMP/secret.yaml"
cat > "$SECRET_YAML" <<'EOF'
proxies:
  - name: w1
    type: wireguard
    private-key: SUPER-SECRET-PRIVATE-KEY-VALUE
    public-key: SOME-PUBLIC-KEY-VALUE
    server: 203.0.113.7
    password: hunter2
    psk: another-secret
  - name: h2
    type: http
    server: 198.51.100.9
    port: 8080
    username: user
sniffer:
  enable: true
  parse-pure-ip: true
EOF
# trojan-style URL userinfo redaction
url_out="$(printf 'endpoint: trojan://alice:secretPW@example.com:443\n' | (. "$KIT_DIR/lib.sh"; redact_yaml_stream))"
redacted_out="$(. "$KIT_DIR/lib.sh"; redact_yaml_stream < "$SECRET_YAML")"
case "$redacted_out" in
  *SUPER-SECRET-PRIVATE-KEY-VALUE*|*hunter2*|*another-secret*|*203.0.113.7*)
    fail "redaction: secret material leaked into redacted output" ;;
  *"[REDACTED]"*)
    pass "redaction: credential values replaced with [REDACTED]" ;;
  *)
    fail "redaction: unexpected output shape" ;;
esac
printf '%s\n' "$redacted_out" | grep -q 'private-key:' && pass "redaction: key names survive" ||
  fail "redaction: key names should survive (value-only redaction)"

# trojan-style URL userinfo redaction
url_out="$(printf 'endpoint: trojan://alice:secretPW@example.com:443\n' | (. "$KIT_DIR/lib.sh"; redact_yaml_stream))"
case "$url_out" in
  *secretPW*) fail "redaction: URL userinfo leaked" ;;
  *"[REDACTED]"*) pass "redaction: URL userinfo replaced" ;;
  *) fail "redaction: URL case unexpected output" ;;
esac

# --- §18: parsers tolerate named/numeric renderings and reject breakage -----------
if bash "$KIT_DIR/verify-gateway.sh" --self-test > "$TMP/gwtest.log" 2>&1; then
  pass "verify-gateway self-test (named + numeric + broken-fixture refusal)"
else
  fail "verify-gateway self-test"
  tail -20 "$TMP/gwtest.log" >&2
fi

# --- §18: DDP key extraction on the shipped fixture ------------------------------
FIXTURE="$KIT_DIR/fixtures/ddp-config-skeleton.yaml"
ddp_out="$(. "$KIT_DIR/lib.sh"; extract_ddp_keys "$FIXTURE")"
ddp_missing=0
for want in '  store-fake-ip: true' '  fake-ip-range: 198.18.0.0/16' '  device: tun-mihomo' \
            '  dns-hijack:' '    - any:53' '    - tcp://any:53' '  override-destination: false'; do
  if printf '%s\n' "$ddp_out" | grep -Fqx "$want"; then
    :
  else
    fail "extract_ddp_keys missing line: $want"
    ddp_missing=1
  fi
done
if [ "$ddp_missing" -eq 0 ]; then
  pass "extract_ddp_keys covers shipped fixture (all required lines present)"
fi

# --- §18: comparator classification on synthetic pairs ----------------------------
cls() { (. "$KIT_DIR/lib.sh"; classify_pair "$@"); }
B="$TMP/b.txt"; P="$TMP/p.txt"
printf 'a\nb\nc\n' > "$B"; printf 'a\nb\nc\n' > "$P"
case "$(cls pair "$B" "$P")" in
  *"EXACT MATCH"*) pass "comparator: EXACT MATCH" ;;
  *) fail "comparator: EXACT MATCH got: $(cls pair "$B" "$P")" ;;
esac
printf 'a\nb\nc\nconfig.yaml.bak.1727000000\n' > "$P"
case "$(cls pair "$B" "$P")" in
  *"EXPECTED DIFFERENCE"*) pass "comparator: bak residue = EXPECTED" ;;
  *) fail "comparator: bak residue got: $(cls pair "$B" "$P")" ;;
esac
printf 'a\nX\nc\n' > "$P"
case "$(cls pair "$B" "$P")" in
  *"UNEXPECTED DIFFERENCE"*) pass "comparator: changed line = UNEXPECTED" ;;
  *) fail "comparator: changed line got: $(cls pair "$B" "$P")" ;;
esac
printf 'a\nb\n' > "$P"
case "$(cls pair "$B" "$P")" in
  *"UNEXPECTED DIFFERENCE"*) pass "comparator: vanished line = UNEXPECTED" ;;
  *) fail "comparator: vanished line got: $(cls pair "$B" "$P")" ;;
esac

# --- §18: collect/verify end-to-end on a sandboxed fixture slot --------------------
# Feed verify-gateway a directory built from the collector file names to prove
# the artifact contract (names + shapes) is what the verifier expects.
mkdir -p "$TMP/slot"
. "$KIT_DIR/lib.sh"
cat > "$TMP/slot/ip-rule.txt" <<'EOF'
0:	from all lookup local
40:	from all fwmark 0x88 lookup main
100:	from 172.29.172.0/24 lookup mihomo
EOF
printf 'default dev tun-mihomo scope link metric 10\nunreachable default metric 42760\n' > "$TMP/slot/ip-route-table100.txt"
printf '198.18.0.0/16 dev tun-mihomo scope link\n' > "$TMP/slot/ip-route-fakeip.txt"
printf '*filter\n-A FORWARD -s 172.29.172.0/24 -j AMG_FAILSECURE\n-A FORWARD -d 172.29.172.0/24 -j ACCEPT\n-A AMG_FAILSECURE -s 172.29.172.0/24 -o tun-mihomo -j ACCEPT\n-A AMG_FAILSECURE -s 172.29.172.0/24 -m mark --mark 0x88 -o ens3 -j ACCEPT\n-A AMG_FAILSECURE -s 172.29.172.0/24 -j REJECT --reject-with icmp-admin-prohibited\nCOMMIT\n*mangle\n-A PREROUTING -s 172.29.172.0/24 -p udp -m udp --sport 39551 -j MARK --set-xmark 0x88/0xffffffff\n-A FORWARD -s 172.29.172.0/24 -o tun-mihomo -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n*nat\n-A POSTROUTING -o tun-mihomo -j MASQUERADE\nCOMMIT\n' > "$TMP/slot/iptables-save.txt"
printf '5: tun-mihomo: <POINTOPOINT,UP,LOWER_UP> mtu 1420 state UNKNOWN\n    inet 198.18.0.1/30 scope global tun-mihomo\n' > "$TMP/slot/tun-link.txt"
printf 'warp-docker-routing.service enabled=enabled active=active\ncheck-warp-routing.timer enabled=enabled active=active\nNRestarts=0\n' > "$TMP/slot/units.txt"
printf 'mihomo.kind=service\nmihomo.active=active\nmihomo.config.path=/etc/mihomo/config.yaml\n' > "$TMP/slot/mihomo.txt"
if bash "$KIT_DIR/verify-gateway.sh" "$TMP/slot" > "$TMP/slot-verify.log" 2>&1; then
  pass "verify-gateway accepts a collector-shaped slot"
else
  fail "verify-gateway rejects a collector-shaped slot"
  cat "$TMP/slot-verify.log" >&2
fi

echo "----"
if [ "$FAILS" -eq 0 ]; then
  echo "All live-kit fixture tests passed."
else
  echo "$FAILS live-kit fixture test(s) FAILED." >&2
fi
exit "$FAILS"

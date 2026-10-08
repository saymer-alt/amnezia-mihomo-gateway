#!/usr/bin/env bash
# verify-gateway.sh — invariant checks over a collected evidence slot.
#
# Usage: verify-gateway.sh <slot-dir> | --self-test
#
# The slot dir must come from collect-baseline.sh. All checks are pure text
# parsing of collected artifacts (named AND numeric table renderings accepted,
# per the watchdog contract). Exit non-zero on any FAIL.
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SRC_DIR/lib.sh"

FAILURES=0
check() { # $1=description, then a command whose success = pass
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$desc"
  else
    err "FAIL: $desc"
    FAILURES=$((FAILURES + 1))
  fi
}
check_absent() { # $1=description, then a command whose success = FORBIDDEN pattern found
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    err "FAIL: $desc (forbidden pattern present)"
    FAILURES=$((FAILURES + 1))
  else
    ok "$desc"
  fi
}

gw_verify_slot() { # $1 = slot dir
  local d="$1" subnet host_if wg_port
  local f_rule="$d/ip-rule.txt" f_t100="$d/ip-route-table100.txt" \
        f_fake="$d/ip-route-fakeip.txt" \
        f_fw="$d/iptables-save.txt" f_tun="$d/tun-link.txt" \
        f_units="$d/units.txt" f_mihomo="$d/mihomo.txt"

  local f
  for f in "$f_rule" "$f_t100" "$f_fake" "$f_fw" "$f_tun" "$f_units" "$f_mihomo"; do
    [ -f "$f" ] || die "missing artifact: $f (run collect-baseline.sh first)"
  done

  # Detect live topology values from the artifacts themselves (self-consistent).
  subnet="$(grep -Eo 'from [0-9.]+/[0-9]+ lookup (100|mihomo)' "$f_rule" | awk '{print $2}' | head -n1)"
  host_if="$(grep -Eo -- "-m mark --mark $FWMARK -o [^ ]+" "$f_fw" | awk '{print $NF}' | head -n1)"
  wg_port="$(grep -Eo -- "--sport [0-9]+" "$f_fw" | awk '{print $2}' | head -n1)"

  echo "--- gateway invariants ($d) ---"
  printf 'detected: subnet=%s host_if=%s wg_port=%s\n' "${subnet:-none}" "${host_if:-none}" "${wg_port:-none}"

  check "TUN $TUN_IF exists and is UP" grep -Eq "$TUN_IF.*(state UP|<[^>]*UP[^>]*>)" "$f_tun"
  check "TUN carries the derived fake-ip IPv4 (/30 of fake-ip-range)" \
    grep -Eq "inet 198\.18\.0\.[0-9]+/30" "$f_tun"

  check "source policy rule -> table 100/mihomo" \
    grep -Eq "from ${subnet:-__none__} lookup (${TABLE_ID}|${TABLE_NAME})( |$)" "$f_rule"
  check "outer-AWG fwmark bypass rule (prio 40 -> main)" \
    grep -Eq "from all fwmark $FWMARK lookup main" "$f_rule"

  check "preferred TUN default (metric 10) in table 100" \
    grep -Eq "default dev $TUN_IF .*metric 10" "$f_t100"
  check "terminal unreachable default metric $FAILSAFE_METRIC in table 100" \
    grep -Eq "unreachable default metric $FAILSAFE_METRIC" "$f_t100"

  check "fake-IP route via TUN" grep -Eq "^198\.18\.0\.0/16 dev $TUN_IF" "$f_fake"

  check "$GUARD_CHAIN hook on FORWARD" \
    grep -Eq -- "-A FORWARD -s ${subnet:-__none__} -j $GUARD_CHAIN" "$f_fw"
  check "$GUARD_CHAIN rule: allow via $TUN_IF" \
    grep -Eq -- "-A $GUARD_CHAIN -s ${subnet:-__none__} -o $TUN_IF -j ACCEPT" "$f_fw"
  check "$GUARD_CHAIN rule: allow marked outer AWG via host interface" \
    grep -Eq -- "-A $GUARD_CHAIN -s ${subnet:-__none__} -m mark --mark $FWMARK -o ${host_if:-__none__} -j ACCEPT" "$f_fw"
  check "$GUARD_CHAIN rule: REJECT other AWG-subnet forwarding" \
    grep -Eq -- "-A $GUARD_CHAIN -s ${subnet:-__none__} -j REJECT --reject-with icmp-admin-prohibited" "$f_fw"
  check_absent "legacy broad source ACCEPT is ABSENT" \
    grep -Eq -- "-A FORWARD -s ${subnet:-__none__} -j ACCEPT( |$)" "$f_fw"

  check "TCPMSS clamp present" grep -Fq -- "--clamp-mss-to-pmtu" "$f_fw"
  check "MASQUERADE via $TUN_IF present" \
    grep -Eq -- "-A POSTROUTING -o $TUN_IF -j MASQUERADE" "$f_fw"
  check "outer-AWG MARK rule (mangle, sport wg_port)" \
    grep -Eq -- "-A PREROUTING -s ${subnet:-__none__} .* --sport ${wg_port:-__none__} .* $FWMARK" "$f_fw"
  check "reverse FORWARD allowance to AWG subnet" \
    grep -Eq -- "-A FORWARD -d ${subnet:-__none__} -j ACCEPT" "$f_fw"

  check "warp-docker-routing.service enabled+active" \
    grep -Eq "^warp-docker-routing\.service enabled=[a-z]+ active=active" "$f_units"
  check "check-warp-routing.timer enabled+active" \
    grep -Eq "^check-warp-routing\.timer enabled=[a-z]+ active=active" "$f_units"

  check "mihomo running (service or container)" \
    grep -Eq "^mihomo\.active=active$|^mihomo\.kind=container-running$" "$f_mihomo"
  check "mihomo config path recorded" grep -Eq "^mihomo\.config\.path=/.+" "$f_mihomo"

  echo "---"
  if [ "$FAILURES" -eq 0 ]; then
    ok "gateway invariants: ALL PASS"
  else
    err "gateway invariants: $FAILURES FAIL"
  fi
  return "$FAILURES"
}

gw_self_test() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/amg-gwtest.XXXXXX")"
  cat > "$tmp/ip-rule.txt" <<'EOF'
0:	from all lookup local
40:	from all fwmark 0x88 lookup main
100:	from 172.29.172.0/24 lookup mihomo
EOF
  cat > "$tmp/ip-route-table100.txt" <<'EOF'
default dev tun-mihomo scope link metric 10
unreachable default metric 42760
EOF
  cat > "$tmp/ip-route-fakeip.txt" <<'EOF'
198.18.0.0/16 dev tun-mihomo scope link
EOF
  cat > "$tmp/iptables-save.txt" <<'EOF'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:AMG_FAILSECURE - [0:0]
-A FORWARD -s 172.29.172.0/24 -j AMG_FAILSECURE
-A FORWARD -d 172.29.172.0/24 -j ACCEPT
-A AMG_FAILSECURE -s 172.29.172.0/24 -o tun-mihomo -j ACCEPT
-A AMG_FAILSECURE -s 172.29.172.0/24 -m mark --mark 0x88 -o ens3 -j ACCEPT
-A AMG_FAILSECURE -s 172.29.172.0/24 -j REJECT --reject-with icmp-admin-prohibited
COMMIT
*mangle
-A PREROUTING -s 172.29.172.0/24 -p udp -m udp --sport 39551 -j MARK --set-xmark 0x88/0xffffffff
-A FORWARD -s 172.29.172.0/24 -o tun-mihomo -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT
*nat
-A POSTROUTING -o tun-mihomo -j MASQUERADE
COMMIT
EOF
  cat > "$tmp/tun-link.txt" <<'EOF'
5: tun-mihomo: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1420 qdisc fq_codel state UNKNOWN mode DEFAULT group default qlen 500
    inet 198.18.0.1/30 scope global tun-mihomo
EOF
  cat > "$tmp/units.txt" <<'EOF'
warp-docker-routing.service enabled=enabled active=active
check-warp-routing.service enabled=static active=inactive
check-warp-routing.timer enabled=enabled active=active
NRestarts=0
EOF
  cat > "$tmp/mihomo.txt" <<'EOF'
mihomo.kind=service
mihomo.active=active
mihomo.config.path=/etc/mihomo/config.yaml
EOF
  echo "== self-test: healthy fixture (named rendering) must PASS =="
  if gw_verify_slot "$tmp"; then :; else echo "SELFTEST FAIL: healthy fixture rejected"; rm -rf "$tmp"; return 1; fi

  echo "== self-test: numeric rendering must PASS =="
  sed -i 's/lookup mihomo/lookup 100/' "$tmp/ip-rule.txt"
  if gw_verify_slot "$tmp"; then :; else echo "SELFTEST FAIL: numeric fixture rejected"; rm -rf "$tmp"; return 1; fi

  echo "== self-test: missing terminal route must FAIL =="
  grep -v 'unreachable default metric 42760' "$tmp/ip-route-table100.txt" > "$tmp/ip-route-table100.txt.new"
  mv "$tmp/ip-route-table100.txt.new" "$tmp/ip-route-table100.txt"
  if gw_verify_slot "$tmp" 2>/dev/null; then
    echo "SELFTEST FAIL: broken fixture accepted"; rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  echo "== self-test: broken fixture correctly FAILED =="
}

case "${1:-}" in
  --self-test) gw_self_test ;;
  "")          die "usage: verify-gateway.sh <slot-dir> | --self-test" ;;
  *)           gw_verify_slot "$1" ;;
esac

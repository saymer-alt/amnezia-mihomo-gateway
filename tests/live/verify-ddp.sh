#!/usr/bin/env bash
# verify-ddp.sh — DDP (Domain Detection) store-fake-ip contract proof.
#
# Usage: verify-ddp.sh <run-dir> <stage-a> <stage-b> [stage-c]...
#   stages are collect slots: baseline | post1 | post2 | postreboot | postuninstall
#
# Compares the whitelisted (non-secret) DDP key set across stages and asserts
# the current contract:
#   existing true  -> true    (generator-owned value survives every install)
#   existing false -> false
#   absent         -> false appended (legacy)
# plus verbatim preservation of tun.dns-hijack, sniffer keys, tun.device,
# tun.auto-route and normalization of dns.fake-ip-range / tun.stack.
# Only whitelisted key lines are ever printed — no private config values.
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SRC_DIR/lib.sh"

[ $# -ge 2 ] || die "usage: verify-ddp.sh <run-dir> <stage-a> <stage-b> [stage-c]..."
RUN_DIR="$1"
shift
STAGES="$*"

ddp_fail=0
ddp_check() { # $1=desc $2=condition-result
  if [ "$2" = "1" ]; then
    ok "$1"
  else
    err "FAIL: $1"
    ddp_fail=$((ddp_fail + 1))
  fi
}

stage_file() { printf '%s/%s/ddp-keys.txt' "$RUN_DIR" "$1"; }

REF=""
for s in $STAGES; do
  [ -f "$(stage_file "$s")" ] || die "missing $(stage_file "$s") (run collect-baseline.sh slot $s first)"
done

# Reference stage = the first one (baseline for the pre-install proof,
# post1 when proving stability across later stages).
for s in $STAGES; do
  REF="$(stage_file "$s")"
  break
done

REF_FAKEIP="$(grep -c '^  store-fake-ip: true$' "$REF" || true)"
REF_FALSE="$(grep -c '^  store-fake-ip: false$' "$REF" || true)"

echo "--- DDP proof across stages: $STAGES ---"
echo "reference key set ($s):"
sed 's/^/    /' "$REF"

# 1. The scenario itself: baseline config carries store-fake-ip: true.
if [ "$REF_FAKEIP" -ge 1 ] && [ "$REF_FALSE" -eq 0 ]; then
  ddp_check "reference stage carries store-fake-ip: true (DDP scenario)" 1
elif [ "$REF_FAKEIP" -eq 0 ] && [ "$REF_FALSE" -ge 1 ]; then
  ddp_check "reference stage carries explicit store-fake-ip: false (accepted variant)" 1
else
  ddp_check "reference stage carries exactly one store-fake-ip key (got true=$REF_FAKEIP false=$REF_FALSE)" 0
fi

# 2. The key set is byte-identical across ALL stages (true survives installs
#    and reboots; hijack/sniffer/device/auto-route verbatim; normalization
#    stable). Byte-identity of the whitelist implies every contract rule.
PREV=""
for s in $STAGES; do
  CUR="$(stage_file "$s")"
  if [ -n "$PREV" ]; then
    if cmp -s "$PREV" "$CUR"; then
      ddp_check "DDP key set identical: $(basename "$(dirname "$PREV")") == $s" 1
    else
      echo "    diff $(basename "$(dirname "$PREV")") -> $s:"
      diff "$PREV" "$CUR" | sed 's/^/      /'
      ddp_check "DDP key set identical: $(basename "$(dirname "$PREV")") == $s" 0
    fi
  fi
  PREV="$CUR"
done

# 3. Required current-contract fields present in every stage.
for s in $STAGES; do
  F="$(stage_file "$s")"
  ddp_check "$s: profile.store-fake-ip present exactly once" \
    "$([ "$(grep -c '^  store-fake-ip:' "$F")" = "1" ] && echo 1 || echo 0)"
  ddp_check "$s: dns.fake-ip-range normalized" \
    "$(grep -q '^  fake-ip-range: 198.18.0.0/16$' "$F" && echo 1 || echo 0)"
  ddp_check "$s: tun.auto-route false" \
    "$(grep -q '^  auto-route: false$' "$F" && echo 1 || echo 0)"
  ddp_check "$s: tun.stack gvisor (current server baseline)" \
    "$(grep -q '^  stack: gvisor$' "$F" && echo 1 || echo 0)"
  ddp_check "$s: tun.device preserved" \
    "$(grep -q '^  device: tun-mihomo$' "$F" && echo 1 || echo 0)"
  ddp_check "$s: tun.dns-hijack entries preserved" \
    "$(grep -q '^    - any:53$' "$F" && grep -q '^    - tcp://any:53$' "$F" && echo 1 || echo 0)"
  ddp_check "$s: sniffer keys preserved" \
    "$(grep -q '^  override-destination: false$' "$F" && echo 1 || echo 0)"
done

echo "---"
if [ "$ddp_fail" -eq 0 ]; then
  ok "DDP proof: ALL PASS"
else
  err "DDP proof: $ddp_fail FAIL"
fi
exit "$ddp_fail"

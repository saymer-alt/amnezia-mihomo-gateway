#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root/proc/sys/net/ipv4/conf/"{all,default,ens3,docker0,eth0.10} \
         "$TMP/root/etc/sysctl.d" "$TMP/root/usr/lib/sysctl.d" "$TMP/bin"
for iface in all default ens3 docker0 eth0.10; do
    printf '0\n' > "$TMP/root/proc/sys/net/ipv4/conf/$iface/rp_filter"
done
printf 'net.ipv4.conf.all.rp_filter = 0\nnet.ipv4.conf.default.rp_filter = 0\n' > "$TMP/root/etc/sysctl.d/99-amnezia-mihomo.conf"
# Tripwires prove no mutating helper can be invoked (including reload).
for command in sysctl ip iptables docker systemctl chattr; do
    printf '#!/bin/sh\necho forbidden >> "$AMG_TEST_FORBIDDEN"\nexit 99\n' > "$TMP/bin/$command"
    chmod +x "$TMP/bin/$command"
done
export AMG_TEST_FORBIDDEN="$TMP/forbidden"
export PATH="$TMP/bin:$PATH"
snapshot() { find "$TMP/root" -type f -exec sha256sum {} + | sort; }
snapshot > "$TMP/before"
AMG_DIAGNOSTIC_ROOT="$TMP/root" bash "$ROOT_DIR/doctor.sh" > "$TMP/healthy"
grep -Fq '[OK] runtime all.rp_filter=0' "$TMP/healthy"
snapshot > "$TMP/after"; cmp "$TMP/before" "$TMP/after"

printf 'net.ipv4.conf.all.rp_filter = 1 # strict\nnet/ipv4/conf/default/rp_filter=2\n-net.ipv4.conf.*.rp_filter = 1\n# net.ipv4.conf.ens3.rp_filter=1\nnet.ipv4.conf.ens3.rp_filter = 0\n' > "$TMP/root/etc/sysctl.conf"
printf 'net.ipv4.conf.eth0.10.rp_filter 1\n' > "$TMP/root/usr/lib/sysctl.d/10-vendor.conf"
printf '1\n' > "$TMP/root/proc/sys/net/ipv4/conf/docker0/rp_filter"
snapshot > "$TMP/before"
if AMG_DIAGNOSTIC_ROOT="$TMP/root" bash "$ROOT_DIR/doctor.sh" > "$TMP/drift"; then
    echo 'FAIL: drift returned healthy' >&2; exit 1
fi
for evidence in 'runtime docker0.rp_filter=1' 'net.ipv4.conf.all.rp_filter=1' \
                'net/ipv4/conf/default/rp_filter=2' 'net.ipv4.conf.*.rp_filter=1' \
                'net.ipv4.conf.eth0.10.rp_filter=1' 'does not calculate the effective boot'; do
    grep -Fq "$evidence" "$TMP/drift" || { echo "FAIL: missing $evidence" >&2; exit 1; }
done
! grep -F 'ens3.rp_filter=1' "$TMP/drift"
snapshot > "$TMP/after"; cmp "$TMP/before" "$TMP/after"
printf 'invalid\n' > "$TMP/root/proc/sys/net/ipv4/conf/default/rp_filter"
if AMG_DIAGNOSTIC_ROOT="$TMP/root" bash "$ROOT_DIR/doctor.sh" > "$TMP/unknown"; then exit 1; fi
grep -Fq 'UNKNOWN: runtime default.rp_filter' "$TMP/unknown"
printf 'net.ipv4.conf.ens3.rp_filter =\n' > "$TMP/root/etc/sysctl.d/20-empty.conf"
ln -s /dev/null "$TMP/root/etc/sysctl.d/30-masked.conf"
if AMG_DIAGNOSTIC_ROOT="$TMP/root" bash "$ROOT_DIR/doctor.sh" > "$TMP/unsupported"; then exit 1; fi
grep -Fq 'has unsupported value' "$TMP/unsupported"
grep -Fq 'persistent file unreadable or not regular' "$TMP/unsupported"
mv "$TMP/root/proc/sys/net/ipv4/conf/all/rp_filter" "$TMP/all-saved"
if AMG_DIAGNOSTIC_ROOT="$TMP/root" bash "$ROOT_DIR/doctor.sh" > "$TMP/missing-all"; then exit 1; fi
grep -Fq 'runtime all.rp_filter missing' "$TMP/missing-all"
if AMG_DIAGNOSTIC_ROOT="$TMP/missing" bash "$ROOT_DIR/doctor.sh" > "$TMP/missing.log"; then exit 1; fi
grep -Fq 'UNKNOWN: runtime rp_filter directory unavailable' "$TMP/missing.log"
test ! -e "$TMP/forbidden"
echo 'PASS: runtime drift, persistent conflicts, wildcard/slash keys, missing/masked/invalid UNKNOWN and read-only tripwires'

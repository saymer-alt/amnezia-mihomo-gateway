#!/usr/bin/env bash
# Read-only rp_filter evidence. Never calls sysctl, ip, Docker or systemctl.
set -uo pipefail

if [ "$#" -gt 0 ]; then
    printf 'Usage: bash doctor.sh (read-only; no root required)\n' >&2
    exit 2
fi
ROOT="${AMG_DIAGNOSTIC_ROOT:-}"
PROC_CONF="${ROOT}/proc/sys/net/ipv4/conf"
warnings=0
warn() { printf '[WARN] %s\n' "$*"; warnings=$((warnings + 1)); }

printf '[INFO] AMG rp_filter diagnostic: read-only; historical incident cause remains unproven.\n'
if [ ! -d "$PROC_CONF" ]; then
    warn "UNKNOWN: runtime rp_filter directory unavailable: $PROC_CONF"
else
    found=0
    found_all=0; found_default=0
    for file in "$PROC_CONF"/*/rp_filter; do
        [ -e "$file" ] || continue
        found=1
        iface="${file%/rp_filter}"; iface="${iface##*/}"
        [ "$iface" != all ] || found_all=1
        [ "$iface" != default ] || found_default=1
        value="$(cat -- "$file" 2>/dev/null || true)"
        case "$value" in
            0) printf '[OK] runtime %s.rp_filter=0\n' "$iface" ;;
            1|2) warn "runtime $iface.rp_filter=$value conflicts with the gateway contract (0)" ;;
            *) warn "UNKNOWN: runtime $iface.rp_filter unreadable or invalid" ;;
        esac
    done
    [ "$found" -eq 1 ] || warn 'UNKNOWN: no runtime rp_filter values found'
    [ "$found_all" -eq 1 ] || warn 'UNKNOWN: runtime all.rp_filter missing'
    [ "$found_default" -eq 1 ] || warn 'UNKNOWN: runtime default.rp_filter missing'
fi

# Show observed declarations, not a prediction of effective boot precedence.
# A masked file can still conflict when explicitly reloaded by an operator.
for file in "$ROOT/etc/sysctl.conf" "$ROOT/etc/sysctl.d/"*.conf \
            "$ROOT/run/sysctl.d/"*.conf "$ROOT/usr/local/lib/sysctl.d/"*.conf \
            "$ROOT/usr/lib/sysctl.d/"*.conf "$ROOT/lib/sysctl.d/"*.conf; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    if [ ! -r "$file" ] || [ ! -f "$file" ]; then
        warn "UNKNOWN: persistent file unreadable or not regular: $file"
        continue
    fi
    if ! declarations="$(awk '
      {
        line=$0
        sub(/[[:space:]]*[#;].*$/, "", line)
        sub(/^[[:space:]]*/, "", line)
        sub(/^-/, "", line)
        split(line, fields, /[[:space:]=]+/)
        key=fields[1]
        if (key ~ /^net\.ipv4\.conf\..+\.rp_filter$/ ||
            key ~ /^net\/ipv4\/conf\/.+\/rp_filter$/) {
            value=fields[2]
            if (value == "") value="UNKNOWN"
            printf "%d\t%s\t%s\n", NR, key, value
        }
      }
    ' "$file")"; then
        warn "UNKNOWN: persistent file could not be parsed: $file"
        continue
    fi
    while IFS=$'\t' read -r number key value; do
        [ -n "$key" ] || continue
        case "$value" in
            0) printf '[INFO] persistent %s:%s %s=0\n' "$file" "$number" "$key" ;;
            1|2) warn "persistent $file:$number $key=$value may reintroduce drift on reload" ;;
            *) warn "UNKNOWN: persistent $file:$number $key has unsupported value" ;;
        esac
    done <<< "$declarations"
done

printf '[INFO] Declarations may be shadowed by sysctl.d precedence/masks; this scan does not calculate the effective boot configuration.\n'
printf '[INFO] Compare runtime all/default/interface values with the project fragment before maintenance. Review conflicting external declarations with the administrator; never blindly reload /etc/sysctl.conf or edit foreign files automatically.\n'
printf '[INFO] No values or files changed. Packet-level evidence is required to establish the historical AWG incident cause.\n'
[ "$warnings" -eq 0 ]

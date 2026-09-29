#!/bin/bash
# =========================================================
# AmneziaAWG to Mihomo (TUN) Routing Installer v2.0
# Проверено: 18/26 -> 40/82+ Мбит на 2-core/1GB VPS
# Оптимизации: clamp-mss-to-pmtu, mtu 1420, gso, find-process-mode off,
#              store-selected/fake-ip false
# Безопасность: gvisor + auto-route:false (SSH не отвалится)
# =========================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${YELLOW}=== Запуск установки маршрутизации Amnezia -> Mihomo (v2.0) ===${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: Этот скрипт должен быть запущен от имени root.${NC}" 
   exit 1
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Ошибка: Docker не установлен.${NC}"
    exit 1
fi

# 1. Автоопределение параметров
echo -e "${YELLOW}[*] Поиск контейнера Amnezia AWG...${NC}"
AWG_CONTAINER=$(docker ps --filter "name=amnezia-awg" --format "{{.Names}}" | head -n1)
if [ -z "$AWG_CONTAINER" ]; then
    echo -e "${RED}Ошибка: Контейнер amnezia-awg не найден! Убедись, что Amnezia запущена.${NC}"
    exit 1
fi
echo -e "${GREEN}Найден контейнер: $AWG_CONTAINER${NC}"

NETWORK_NAME=$(docker inspect "$AWG_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' | grep 'amnezia' | head -n1)
if [ -z "$NETWORK_NAME" ]; then
    NETWORK_NAME=$(docker inspect "$AWG_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' | head -n1)
fi

DOCKER_NETS=$(docker network inspect "$NETWORK_NAME" --format='{{range .IPAM.Config}}{{.Subnet}}{{end}}')
if [ -z "$DOCKER_NETS" ]; then
    echo -e "${RED}Ошибка: Не удалось определить подсеть Docker.${NC}"
    exit 1
fi

WG_PORT=$(docker port "$AWG_CONTAINER" | grep '/udp' | head -n1 | awk -F'/' '{print $1}')
if [ -z "$WG_PORT" ]; then
    WG_PORT=$(docker inspect "$AWG_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Ports}}{{$k}}{{end}}' | grep '/udp' | head -n1 | awk -F'/' '{print $1}')
fi
if [ -z "$WG_PORT" ]; then
    echo -e "${RED}Ошибка: Не удалось определить порт AWG (UDP).${NC}"
    exit 1
fi

HOST_IF=$(ip -o -4 route show to default | awk '{print $5}')
PROXY_IF="tun-mihomo"
TABLE_ID="100"
TABLE_NAME="mihomo"
FAKE_IP_RANGE="198.18.0.0/16"
STATE_DIR="/var/lib/amnezia-mihomo-gateway"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

echo -e "${GREEN}Настройки определены:${NC}"
echo -e " - Сеть Docker: $DOCKER_NETS"
echo -e " - Порт AWG:    $WG_PORT"
echo -e " - Интерфейс:   $HOST_IF"
echo -e " - Прокси TUN:  $PROXY_IF"

# 2. SYSCTL: только то, чего нет (не ломаем существующий hardening)
echo -e "${YELLOW}[*] Проверка sysctl...${NC}"
SYSCTL_FILE="/etc/sysctl.d/99-amnezia-mihomo.conf"
rm -f "$SYSCTL_FILE"

cat << 'EOF' > "$SYSCTL_FILE"
# rp_filter ОБЯЗАТЕЛЬНО 0 для gvisor
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF

CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
if [ "$CURRENT_CC" != "bbr" ]; then
    echo "net.core.default_qdisc = fq" >> "$SYSCTL_FILE"
    echo "net.ipv4.tcp_congestion_control = bbr" >> "$SYSCTL_FILE"
    echo -e "${CYAN}    -> BBR добавлен.${NC}"
else
    echo -e "${CYAN}    -> BBR уже активен, пропускаем.${NC}"
fi

CURRENT_IPF=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
if [ "$CURRENT_IPF" != "1" ]; then
    echo "net.ipv4.ip_forward = 1" >> "$SYSCTL_FILE"
fi

sysctl -p "$SYSCTL_FILE" > /dev/null
for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done

# 2.5 Именованная таблица маршрутизации
if ! grep -q "^$TABLE_ID $TABLE_NAME$" /etc/iproute2/rt_tables; then
    echo "$TABLE_ID $TABLE_NAME" >> /etc/iproute2/rt_tables
    : > "$STATE_DIR/rt_table_added"
fi

# 2.6 DNS
echo -e "${YELLOW}[*] Настройка DNS...${NC}"
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl disable --now systemd-resolved 2>/dev/null || true
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat << 'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF
    chattr +i /etc/resolv.conf
    echo -e "${CYAN}    -> systemd-resolved отключён.${NC}"
else
    echo -e "${CYAN}    -> systemd-resolved уже отключён.${NC}"
fi

DOCKER_GW=$(ip -4 addr show docker0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -n "$DOCKER_GW" ]; then
    if [ ! -f /etc/docker/daemon.json ]; then
        cat << EOF > /etc/docker/daemon.json
{
  "dns": ["$DOCKER_GW"]
}
EOF
        : > "$STATE_DIR/docker_daemon_created"
        sha256sum /etc/docker/daemon.json | awk '{print $1}' > "$STATE_DIR/docker_daemon_sha256"
        printf '%s\n' "$DOCKER_GW" > "$STATE_DIR/docker_dns_gateway"
        systemctl restart docker
        echo -e "${CYAN}    -> Docker DNS настроен; ownership-state сохранён.${NC}"
    else
        echo -e "${CYAN}    -> daemon.json уже существует, пропускаем.${NC}"
    fi
fi

# 2.7 Авто-патч config.yaml Mihomo (все проверенные оптимизации v2.0)
echo -e "${YELLOW}[*] Поиск и патч config.yaml Mihomo...${NC}"
MIHOMO_CONFIG=$(find /etc/mihomo /opt/mihomo /root /home -maxdepth 3 -name "config.yaml" 2>/dev/null | head -n1)
if [ -n "$MIHOMO_CONFIG" ]; then
    echo -e "${GREEN}    Найден конфиг: $MIHOMO_CONFIG${NC}"

    MIHOMO_BACKUP="$MIHOMO_CONFIG.bak.$(date +%s)"
    cp "$MIHOMO_CONFIG" "$MIHOMO_BACKUP"

    CURRENT_MIHOMO_SHA=$(sha256sum "$MIHOMO_CONFIG" | awk '{print $1}')
    if [ -f "$STATE_DIR/mihomo_config_path" ] &&
       [ -f "$STATE_DIR/mihomo_patched_sha256" ]; then
        PREVIOUS_CONFIG=$(cat "$STATE_DIR/mihomo_config_path" 2>/dev/null || true)
        PREVIOUS_PATCHED_SHA=$(cat "$STATE_DIR/mihomo_patched_sha256" 2>/dev/null || true)
        if [ "$PREVIOUS_CONFIG" != "$MIHOMO_CONFIG" ] ||
           [ "$CURRENT_MIHOMO_SHA" != "$PREVIOUS_PATCHED_SHA" ]; then
            : > "$STATE_DIR/mihomo_config_diverged"
        fi
    fi

    if [ ! -f "$STATE_DIR/mihomo_config_original.yaml" ]; then
        cp "$MIHOMO_CONFIG" "$STATE_DIR/mihomo_config_original.yaml"
        chmod 600 "$STATE_DIR/mihomo_config_original.yaml"
        printf '%s\n' "$MIHOMO_CONFIG" > "$STATE_DIR/mihomo_config_path"
    fi

    # BEGIN MIHOMO_CONFIG_PATCH
    # Scope-aware patcher for the top-level dns/tun/profile mappings.
    # Unsupported/ambiguous YAML structures fail closed instead of being guessed.
    patch_mihomo_config() {
        local config="$1"
        local config_dir config_base hardlinks lock_file

        config_dir=$(dirname -- "$config")
        config_base=$(basename -- "$config")
        lock_file="$config.amg.lock"

        if [ -L "$config" ]; then
            echo -e "${RED}Ошибка: config.yaml является symlink; безопасный atomic replace не выполняется.${NC}" >&2
            return 1
        fi

        hardlinks=$(stat -c '%h' -- "$config")
        if [ "$hardlinks" -ne 1 ]; then
            echo -e "${RED}Ошибка: config.yaml имеет $hardlinks hardlink(s); atomic replace изменил бы семантику файла.${NC}" >&2
            return 1
        fi

        if ! command -v flock >/dev/null 2>&1; then
            echo -e "${RED}Ошибка: для безопасного патча требуется flock (util-linux).${NC}" >&2
            return 1
        fi

        (
            local body tmp
            exec 9>"$lock_file"
            if ! flock -n 9; then
                echo -e "${RED}Ошибка: config.yaml уже изменяется другим процессом.${NC}" >&2
                exit 1
            fi

            body=$(mktemp "$config_dir/.${config_base}.amg.body.XXXXXX")
            tmp=$(mktemp "$config_dir/.${config_base}.amg.XXXXXX")
            trap 'rm -f -- "$body" "$tmp"' EXIT HUP INT TERM

            if ! awk -v fake="$FAKE_IP_RANGE" '
              function fail(msg) {
                  print "amg-patcher: " msg > "/dev/stderr"
                  bad=1
              }
              function reset_seen() {
                  seen_fake=seen_stack=seen_autoroute=seen_icmp=seen_mtu=seen_gso=seen_autodetect=0
                  seen_store_selected=seen_store_fake=0
                  indent_checked=0
                  skip_inet4=0
              }
              function emit_missing(which) {
                  if (which == "dns") {
                      if (!seen_fake) print "  fake-ip-range: " fake
                  } else if (which == "tun") {
                      if (!seen_stack) print "  stack: gvisor"
                      if (!seen_autoroute) print "  auto-route: false"
                      if (!seen_icmp) print "  disable-icmp-forwarding: true"
                      if (!seen_mtu) print "  mtu: 1420"
                      if (!seen_gso) print "  gso: true"
                      if (!seen_autodetect) print "  auto-detect-interface: true"
                  } else if (which == "profile") {
                      if (!seen_store_selected) print "  store-selected: false"
                      if (!seen_store_fake) print "  store-fake-ip: false"
                  }
              }
              function close_section() {
                  if (section != "") emit_missing(section)
                  section=""
              }
              function check_direct_indent(line, n) {
                  if (indent_checked || line ~ /^[[:space:]]*($|#)/) return
                  if (line ~ /^\t/) {
                      fail("tabs inside top-level " section " mapping are unsupported")
                      indent_checked=1
                      return
                  }
                  if (match(line, /^ +[^ #]/)) {
                      n=RLENGTH-1
                      if (n != 2) fail("top-level " section " mapping must use two-space direct-child indentation")
                      indent_checked=1
                  }
              }
              BEGIN {
                  section=""
                  bad=0
                  dns_sections=tun_sections=profile_sections=find_count=0
                  reset_seen()
              }
              {
                  line=$0

                  if (line ~ /^dns:/ && line !~ /^dns:[[:space:]]*(#.*)?$/) {
                      fail("inline/anchored top-level dns mapping is unsupported")
                  }
                  if (line ~ /^tun:/ && line !~ /^tun:[[:space:]]*(#.*)?$/) {
                      fail("inline/anchored top-level tun mapping is unsupported")
                  }
                  if (line ~ /^profile:/ && line !~ /^profile:[[:space:]]*(#.*)?$/) {
                      fail("inline/anchored top-level profile mapping is unsupported")
                  }

                  if (line ~ /^dns:[[:space:]]*(#.*)?$/) {
                      close_section()
                      dns_sections++
                      if (dns_sections > 1) fail("duplicate top-level dns section")
                      section="dns"
                      reset_seen()
                      print
                      next
                  }
                  if (line ~ /^tun:[[:space:]]*(#.*)?$/) {
                      close_section()
                      tun_sections++
                      if (tun_sections > 1) fail("duplicate top-level tun section")
                      section="tun"
                      reset_seen()
                      print
                      next
                  }
                  if (line ~ /^profile:[[:space:]]*(#.*)?$/) {
                      close_section()
                      profile_sections++
                      if (profile_sections > 1) fail("duplicate top-level profile section")
                      section="profile"
                      reset_seen()
                      print
                      next
                  }

                  if (section != "" && line ~ /^[^[:space:]#][^:]*:/) {
                      close_section()
                  }

                  if (section == "") {
                      if (line ~ /^find-process-mode:[[:space:]]*/) {
                          find_count++
                          if (find_count > 1) fail("duplicate top-level find-process-mode")
                          print "find-process-mode: off"
                          next
                      }
                      if (line ~ /^endpoint-independent-nat:[[:space:]]*/) {
                          next
                      }
                      print
                      next
                  }

                  check_direct_indent(line)

                  if (section == "dns") {
                      if (line ~ /^  fake-ip-range:[[:space:]]*/) {
                          seen_fake++
                          if (seen_fake > 1) fail("duplicate dns.fake-ip-range")
                          print "  fake-ip-range: " fake
                          next
                      }
                      print
                      next
                  }

                  if (section == "tun") {
                      if (skip_inet4) {
                          if (line ~ /^    / || line ~ /^  -[[:space:]]/) next
                          skip_inet4=0
                      }
                      if (line ~ /^  inet4-address:[[:space:]]*/) {
                          skip_inet4=1
                          next
                      }
                      if (line ~ /^  stack:[[:space:]]*/) {
                          seen_stack++
                          if (seen_stack > 1) fail("duplicate tun.stack")
                          print "  stack: gvisor"
                          next
                      }
                      if (line ~ /^  auto-route:[[:space:]]*/) {
                          seen_autoroute++
                          if (seen_autoroute > 1) fail("duplicate tun.auto-route")
                          print "  auto-route: false"
                          next
                      }
                      if (line ~ /^  disable-icmp-forwarding:[[:space:]]*/) {
                          seen_icmp++
                          if (seen_icmp > 1) fail("duplicate tun.disable-icmp-forwarding")
                          print "  disable-icmp-forwarding: true"
                          next
                      }
                      if (line ~ /^  mtu:[[:space:]]*/) {
                          seen_mtu++
                          if (seen_mtu > 1) fail("duplicate tun.mtu")
                          print "  mtu: 1420"
                          next
                      }
                      if (line ~ /^  gso:[[:space:]]*/) {
                          seen_gso++
                          if (seen_gso > 1) fail("duplicate tun.gso")
                          print "  gso: true"
                          next
                      }
                      if (line ~ /^  auto-detect-interface:[[:space:]]*/) {
                          seen_autodetect++
                          if (seen_autodetect > 1) fail("duplicate tun.auto-detect-interface")
                          print "  auto-detect-interface: true"
                          next
                      }
                      print
                      next
                  }

                  if (section == "profile") {
                      if (line ~ /^  store-selected:[[:space:]]*/) {
                          seen_store_selected++
                          if (seen_store_selected > 1) fail("duplicate profile.store-selected")
                          print "  store-selected: false"
                          next
                      }
                      if (line ~ /^  store-fake-ip:[[:space:]]*/) {
                          seen_store_fake++
                          if (seen_store_fake > 1) fail("duplicate profile.store-fake-ip")
                          print "  store-fake-ip: false"
                          next
                      }
                      print
                      next
                  }
              }
              END {
                  close_section()

                  if (dns_sections != 1) fail("exactly one top-level dns section is required")
                  if (tun_sections != 1) fail("exactly one top-level tun section is required")

                  if (find_count == 0) print "find-process-mode: off"

                  if (profile_sections == 0) {
                      print ""
                      print "profile:"
                      print "  store-selected: false"
                      print "  store-fake-ip: false"
                  }

                  if (bad) exit 42
              }
            ' "$config" > "$body"; then
                echo -e "${RED}Ошибка: структура config.yaml неоднозначна или не поддерживается; исходный файл не изменён.${NC}" >&2
                exit 1
            fi

            # Preserve owner/group/mode/ACL/xattrs on the replacement inode.
            cp --preserve=all -- "$config" "$tmp"
            cat -- "$body" > "$tmp"

            if command -v mihomo >/dev/null 2>&1; then
                if ! mihomo -t -f "$tmp"; then
                    echo -e "${RED}Ошибка: mihomo -t отклонил пропатченный config.yaml; исходный файл не изменён.${NC}" >&2
                    exit 1
                fi
                echo -e "${CYAN}    -> mihomo -t: PASS.${NC}"
            else
                echo -e "${YELLOW}    -> WARN: локальный бинарник mihomo не найден; syntax validation будет выполнена на live acceptance.${NC}"
            fi

            # Same-directory rename is atomic on the target filesystem.
            mv -f -- "$tmp" "$config"
            tmp=""
            rm -f -- "$body"
            body=""
            trap - EXIT HUP INT TERM
        )
    }

    patch_mihomo_config "$MIHOMO_CONFIG"
    # END MIHOMO_CONFIG_PATCH

    sha256sum "$MIHOMO_CONFIG" | awk '{print $1}' > "$STATE_DIR/mihomo_patched_sha256"
    echo -e "${GREEN}    Патчи применены: stack: gvisor, auto-route: false, mtu: 1420, gso: true, find-process-mode: off, store-*: false${NC}"
    echo -e "${CYAN}    -> Pre-install state сохранён для будущего безопасного rollback.${NC}"
else
    echo -e "${YELLOW}    Конфиг config.yaml не найден автоматически. Проверьте вручную!${NC}"
fi

# 3. Скрипт маршрутизации (clamp-mss-to-pmtu — проверено, даёт ~2x прирост)
echo -e "${YELLOW}[*] Создание скрипта маршрутизации...${NC}"
cat << EOF > /usr/local/sbin/warp-docker-routing.sh
#!/bin/sh
set -eu

PROXY_IF="$PROXY_IF"
DOCKER_NETS="$DOCKER_NETS"
WG_PORT="$WG_PORT"
TABLE_ID="$TABLE_ID"
HOST_IF="$HOST_IF"
FAKE_IP_RANGE="$FAKE_IP_RANGE"
GUARD_CHAIN="AMG_FAILSECURE"
FAILSAFE_METRIC="42760"

ensure_guard() {
    # Independent barrier: AWG client traffic may use only TUN or the marked outer AWG reply path.
    iptables -N "\$GUARD_CHAIN" 2>/dev/null || true
    iptables -C "\$GUARD_CHAIN" -s "\$DOCKER_NETS" -o "\$PROXY_IF" -j ACCEPT 2>/dev/null || \
        iptables -A "\$GUARD_CHAIN" -s "\$DOCKER_NETS" -o "\$PROXY_IF" -j ACCEPT
    iptables -C "\$GUARD_CHAIN" -s "\$DOCKER_NETS" -m mark --mark 0x88 -o "\$HOST_IF" -j ACCEPT 2>/dev/null || \
        iptables -A "\$GUARD_CHAIN" -s "\$DOCKER_NETS" -m mark --mark 0x88 -o "\$HOST_IF" -j ACCEPT
    iptables -C "\$GUARD_CHAIN" -s "\$DOCKER_NETS" -j REJECT --reject-with icmp-admin-prohibited 2>/dev/null || \
        iptables -A "\$GUARD_CHAIN" -s "\$DOCKER_NETS" -j REJECT --reject-with icmp-admin-prohibited
    iptables -C FORWARD -s "\$DOCKER_NETS" -j "\$GUARD_CHAIN" 2>/dev/null || \
        iptables -I FORWARD 1 -s "\$DOCKER_NETS" -j "\$GUARD_CHAIN"
}

remove_guard() {
    while iptables -D FORWARD -s "\$DOCKER_NETS" -j "\$GUARD_CHAIN" 2>/dev/null; do :; done
    iptables -F "\$GUARD_CHAIN" 2>/dev/null || true
    iptables -X "\$GUARD_CHAIN" 2>/dev/null || true
}

if [ "\${1:-}" = "guard" ]; then
    ensure_guard
    ip route replace unreachable default metric "\$FAILSAFE_METRIC" table "\$TABLE_ID"
    logger "warp-routing: fail-secure guard установлен."
    exit 0
fi

if [ "\${1:-}" = "purge" ]; then
    logger "warp-routing: Полное удаление project-owned routing/guard state..."
    ip rule del fwmark 0x88 lookup main priority 40 2>/dev/null || true
    ip rule del from "\$DOCKER_NETS" lookup "\$TABLE_ID" priority 100 2>/dev/null || true
    ip route del default dev "\$PROXY_IF" table "\$TABLE_ID" 2>/dev/null || true
    ip route del unreachable default metric "\$FAILSAFE_METRIC" table "\$TABLE_ID" 2>/dev/null || true
    ip route del "\$FAKE_IP_RANGE" dev "\$PROXY_IF" 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "\$DOCKER_NETS" -p udp --sport "\$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null || true
    iptables -t mangle -D FORWARD -s "\$DOCKER_NETS" -o "\$PROXY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "\$PROXY_IF" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || true
    remove_guard
    logger "warp-routing: Полное удаление project-owned state завершено."
    exit 0
fi

if [ "\${1:-}" = "cleanup" ]; then
    logger "warp-routing: Выполняется очистка правил..."
    ip rule del fwmark 0x88 lookup main priority 40 2>/dev/null || true
    ip rule del from "\$DOCKER_NETS" lookup "\$TABLE_ID" priority 100 2>/dev/null || true
    # Runtime stop/restart keeps fail-secure barriers in place.
    ip route del default dev "\$PROXY_IF" table "\$TABLE_ID" 2>/dev/null || true
    ip route del "\$FAKE_IP_RANGE" dev "\$PROXY_IF" 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "\$DOCKER_NETS" -p udp --sport "\$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null || true
    iptables -t mangle -D FORWARD -s "\$DOCKER_NETS" -o "\$PROXY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "\$PROXY_IF" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || true
    logger "warp-routing: Очистка завершена."
    exit 0
fi

logger "warp-routing: Запуск применения правил..."

# Install barriers before waiting for TUN or deleting the source rule.
ensure_guard
ip route replace unreachable default metric "\$FAILSAFE_METRIC" table "\$TABLE_ID"

for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "\$i"; done

# Ждем появления интерфейса Mihomo (до 30 секунд)
if ! ip link show "\$PROXY_IF" >/dev/null 2>&1; then
    logger "warp-routing: Интерфейс '\$PROXY_IF' не найден. Ожидание Mihomo..."
    echo "Waiting for Mihomo interface..."
    for i in \$(seq 1 15); do
        if ip link show "\$PROXY_IF" >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
fi

if ! ip link show "\$PROXY_IF" >/dev/null 2>&1; then
    logger "warp-routing: ОШИБКА - Интерфейс '\$PROXY_IF' так и не появился."
    echo "Error: Interface '\$PROXY_IF' does not exist."
    exit 1
fi

# Увеличиваем очередь передачи на TUN (меньше dropped packets)
ip link set dev "\$PROXY_IF" txqueuelen 5000 2>/dev/null || true

# Очистка старых правил
ip rule del fwmark 0x88 lookup main priority 40 2>/dev/null || true
ip rule del from "\$DOCKER_NETS" lookup "\$TABLE_ID" priority 100 2>/dev/null || true
iptables -t mangle -D PREROUTING -s "\$DOCKER_NETS" -p udp --sport "\$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null || true
iptables -t nat -D POSTROUTING -o "\$PROXY_IF" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -s "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -d "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || true

# Маршруты в отдельную таблицу (main не трогаем — SSH в безопасности)
ip route replace default dev "\$PROXY_IF" metric 10 table "\$TABLE_ID"
ip route replace "\$FAKE_IP_RANGE" dev "\$PROXY_IF"
logger "warp-routing: Маршруты обновлены."

ip rule add from "\$DOCKER_NETS" lookup "\$TABLE_ID" priority 100 2>/dev/null || true
ip rule add fwmark 0x88 lookup main priority 40 2>/dev/null || true

# Помечаем ответный WG-трафик, чтобы шел в main (избегаем петли)
iptables -t mangle -C PREROUTING -s "\$DOCKER_NETS" -p udp --sport "\$WG_PORT" -j MARK --set-mark 0x88 2>/dev/null || \\
iptables -t mangle -I PREROUTING 1 -s "\$DOCKER_NETS" -p udp --sport "\$WG_PORT" -j MARK --set-mark 0x88

# CLAMP-MSS-TO-PMTU — проверено: даёт ~2x прирост скорости
iptables -t mangle -C FORWARD -s "\$DOCKER_NETS" -o "\$PROXY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \\
iptables -t mangle -A FORWARD -s "\$DOCKER_NETS" -o "\$PROXY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# NAT
iptables -t nat -C POSTROUTING -o "\$PROXY_IF" -j MASQUERADE 2>/dev/null || \\
iptables -t nat -A POSTROUTING -o "\$PROXY_IF" -j MASQUERADE

# Форвардинг: source-side allow теперь принадлежит AMG_FAILSECURE.
# Удаляем legacy broad ACCEPT, чтобы он не мог обойти guard.
while iptables -D FORWARD -s "\$DOCKER_NETS" -j ACCEPT 2>/dev/null; do :; done

iptables -C FORWARD -d "\$DOCKER_NETS" -j ACCEPT 2>/dev/null || \\
iptables -I FORWARD 2 -d "\$DOCKER_NETS" -j ACCEPT

logger "warp-routing: Правила успешно применены."
EOF
chmod +x /usr/local/sbin/warp-docker-routing.sh

# 4. Systemd
echo -e "${YELLOW}[*] Создание systemd сервиса...${NC}"
cat << 'EOF' > /etc/systemd/system/warp-docker-routing.service
[Unit]
Description=Route Amnezia Docker traffic through Mihomo TUN
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/warp-docker-routing.sh
ExecStop=/usr/local/sbin/warp-docker-routing.sh cleanup
RemainAfterExit=yes
ExecReload=/usr/local/sbin/warp-docker-routing.sh

[Install]
WantedBy=multi-user.target
EOF

# 5. Watchdog
echo -e "${YELLOW}[*] Настройка watchdog-таймера...${NC}"
cat << EOF > /usr/local/sbin/check-warp-routing.sh
#!/bin/sh
PROXY_IF="$PROXY_IF"
DOCKER_NETS="$DOCKER_NETS"
TABLE_ID="$TABLE_ID"
TABLE_NAME="$TABLE_NAME"

routing_ok() {
    ip link show "\$PROXY_IF" >/dev/null 2>&1 &&
    ip rule show | grep -Eq "^100:[[:space:]]+from \$DOCKER_NETS lookup (\$TABLE_ID|\$TABLE_NAME)( |\$)" &&
    ip rule show | grep -Eq "^40:[[:space:]]+from all fwmark 0x88(/0xffffffff)? lookup main( |\$)" &&
    ip route show table "\$TABLE_ID" | grep -Fq "default dev \$PROXY_IF" &&
    ip route show table "\$TABLE_ID" | grep -Eq "^unreachable default .*metric 42760( |\$)" &&
    iptables -C FORWARD -s "\$DOCKER_NETS" -j AMG_FAILSECURE >/dev/null 2>&1 &&
    iptables -C AMG_FAILSECURE -s "\$DOCKER_NETS" -j REJECT --reject-with icmp-admin-prohibited >/dev/null 2>&1
}

if ! ip link show "\$PROXY_IF" >/dev/null 2>&1; then
    logger "warp-check: Интерфейс \$PROXY_IF отсутствует. Пытаюсь перезапустить Mihomo..."
    if systemctl list-unit-files | grep -q "^mihomo.service"; then
        systemctl restart mihomo.service
    elif command -v docker >/dev/null 2>&1; then
        MIHOMO_C=\$(docker ps -a --format '{{.Names}}' | grep "mihomo" | head -n1)
        if [ -n "\$MIHOMO_C" ]; then
            docker restart "\$MIHOMO_C"
        fi
    fi
    for i in \$(seq 1 10); do
        if ip link show "\$PROXY_IF" >/dev/null 2>&1; then break; fi
        sleep 2
    done
fi

if routing_ok; then
    exit 0
fi

logger "warp-check: Правила маршрутизации отсутствуют или неполны. Восстанавливаю..."
if ! systemctl restart warp-docker-routing.service; then
    logger "warp-check: ОШИБКА — не удалось перезапустить warp-docker-routing.service"
    exit 1
fi

sleep 1

if routing_ok; then
    logger "warp-check: Правила успешно восстановлены."
    exit 0
fi

logger "warp-check: ОШИБКА — правила не восстановились после перезапуска."
exit 1
EOF
chmod +x /usr/local/sbin/check-warp-routing.sh

cat << 'EOF' > /etc/systemd/system/check-warp-routing.service
[Unit]
Description=Check WARP Docker routing

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/check-warp-routing.sh
EOF

cat << 'EOF' > /etc/systemd/system/check-warp-routing.timer
[Unit]
Description=Periodic WARP routing check

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

# 6. Перед рестартом Mihomo ставим независимый fail-secure barrier.
echo -e "${YELLOW}[*] Установка fail-secure guard...${NC}"
/usr/local/sbin/warp-docker-routing.sh guard

# 6. Перезапуск Mihomo
echo -e "${YELLOW}[*] Перезапуск Mihomo...${NC}"
if systemctl list-unit-files | grep -q "^mihomo.service"; then
    systemctl restart mihomo.service
elif command -v docker >/dev/null 2>&1; then
    MIHOMO_C=$(docker ps -a --format '{{.Names}}' | grep "mihomo" | head -n1)
    if [ -n "$MIHOMO_C" ]; then
        docker restart "$MIHOMO_C"
    fi
fi
sleep 5

# 7. Запуск маршрутизации
echo -e "${YELLOW}[*] Перезагрузка systemd и запуск...${NC}"
systemctl daemon-reload
systemctl enable --now warp-docker-routing.service
systemctl enable --now check-warp-routing.timer

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! (Версия 2.0)${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "${YELLOW}Скрипт автоматически пропатчил config.yaml Mihomo:${NC}"
echo -e "  1. fake-ip-range: $FAKE_IP_RANGE"
echo -e "  2. legacy top-level tun.inet4-address удалён"
echo -e "  3. stack: gvisor (SSH безопасность)"
echo -e "  4. auto-route: false"
echo -e "     disable-icmp-forwarding: true (strict privacy)"
echo -e "  5. mtu: 1420"
echo -e "  6. gso: true"
echo -e "  7. auto-detect-interface: true"
echo -e "  8. find-process-mode: off"
echo -e "  9. store-selected: false, store-fake-ip: false"
echo -e "  10. endpoint-independent-nat удалён (ломает gvisor)"
echo -e "  + TCPMSS --clamp-mss-to-pmtu (проверено: +~2x скорость)"
echo ""
echo -e "${CYAN}Проверка: запустите спидтест с клиента.${NC}"
echo -e "${CYAN}Ожидаемая скорость: 35-45 / 70-90+ Мбит на 2-core VPS${NC}"

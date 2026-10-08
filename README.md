

# amnezia-mihomo-gateway

Автоматизированная настройка маршрутизации Docker-контейнера **AmneziaAWG** через TUN-интерфейс **Mihomo** (Clash Meta) с выходом в интернет через **Cloudflare WARP**.

**Задача:** клиенты подключаются к твоему серверу по AmneziaWG, но в интернет выходят с IP-адреса Cloudflare WARP — твой реальный IP сервера остаётся скрытым.

---

## Зачем это нужно

По умолчанию AmneziaAWG в Docker отправляет клиентский трафик напрямую через сетевой интерфейс сервера. Если хочешь скрыть IP VPS от клиентов (и от сайтов, которые они посещают), нужно завернуть весь исходящий трафик контейнера в прокси/VPN.

Этот скрипт делает это через **Linux policy routing** — чисто, надёжно, без костылей с `proxychains` или `redsocks`.

---

## Архитектура

```
┌─────────────┐     UDP WG_PORT      ┌──────────────────┐
│   Клиент    │ ───────────────────> │ AmneziaAWG       │
│  (AWG app)  │                      │ (Docker)         │
└─────────────┘                      └────────┬─────────┘
                                              │
                                              │ Docker bridge
                                              ▼
┌─────────────────────────────────────────────────────────┐
│                    Linux Routing Stack                  │
│  ┌─────────────────────────────────────────────────┐    │
│  │  ip rule: from Docker_Net -> lookup table 100   │    │
│  │  ip route: default dev tun-mihomo (table 100)   │    │
│  └─────────────────────────────────────────────────┘    │
│                           │                             │
│              ┌────────────┴────────────┐                │
│              │                         │                │
│              ▼                         ▼                │
│    ┌─────────────────┐      ┌─────────────────┐         │
│    │  Обычный трафик │      │  Ответы AWG     │         │
│    │  (TCP/UDP)      │      │  (WG_PORT)      │         │
│    │  -> tun-mihomo  │      │  -> fwmark 0x88 │         │
│    │  -> WARP        │      │  -> main table  │         │
│    │  -> Интернет    │      │  -> Клиент      │         │
│    └─────────────────┘      └─────────────────┘         │
└─────────────────────────────────────────────────────────┘
```

**Ключевые моменты:**
- **Таблица 100** — весь трафик из Docker-сети AWG идёт через `tun-mihomo`. Поскольку установщик регистрирует её как `100 mihomo` в `/etc/iproute2/rt_tables`, `ip rule show` может отображать это же правило как `lookup mihomo` — это та же таблица, а не ошибка.
- **fwmark 0x88** — ответы WireGuard (UDP с source port WG_PORT) маркируются и идут напрямую к клиенту, минуя прокси. Без этого клиент не сможет подключиться.
- **MASQUERADE** — NAT трафика перед отправкой в tun-интерфейс
- **TCPMSS clamping** — корректировка MTU для стабильной работы через двойную инкапсуляцию (AWG + WARP)

---

## Что входит в проект

| Файл | Назначение |
|---|---|
| `install.sh` | Установщик. Автоопределяет сеть Docker, порт AWG, создаёт скрипты и systemd-юниты |
| `uninstall.sh` | Удаление routing rules, сервисов и generated files; ownership-aware rollback системных изменений installer'а при доказанном ownership/checksum match (см. раздел «Удаление») |
| `warp-docker-routing.sh` | Скрипт маршрутизации (создаётся автоматически в `/usr/local/sbin/`) |
| `check-warp-routing.sh` | Watchdog: проверяет наличие tun-интерфейса и правил раз в минуту |
| `warp-docker-routing.service` | Systemd unit для маршрутизации |
| `check-warp-routing.timer` | Systemd timer для watchdog |
| `docs/LIVE_AUDIT_2026-09-23.md` | Live-аудит: подтверждённые VPS-наблюдения, ownership-state и release gates |

---

## Требования

- **OS:** Debian 12 / Ubuntu 22.04+ (другие systemd-based дистрибутивы — вероятно, тоже)
- **Docker:** Установлен и запущен
- **AmneziaAWG:** Контейнер `amnezia-awg` запущен и работает
- **Mihomo (Clash Meta):** Запущен как `mihomo.service` или Docker-контейнер; в конфиге включён TUN-интерфейс `tun-mihomo`
- **Root:** Скрипт запускается от root

---

## Read-only диагностика rp_filter (development)

В checkout ветки main можно выполнить `bash doctor.sh` без root. Команда только
читает runtime `/proc/sys/net/ipv4/conf/*/rp_filter` и persistent sysctl declarations:
выводит конфликтующие all/default/interface значения, wildcard/slash keys и UNKNOWN
для недоступных данных. Exit 0 — наблюдаемых предупреждений нет; 1 — WARN/UNKNOWN;
2 — неверные аргументы. `AMG_DIAGNOSTIC_ROOT` задаёт корень fixture-дерева для тестов.

Это диагностическая возможность main, ещё не опубликованная в stable v2.0.1.
Doctor не вычисляет итоговый boot precedence/masks: найденный directive может быть
перекрыт другим файлом, но опасен при ручном whole-file reload. Он не вызывает
sysctl/reload, не правит внешний config и не доказывает причину исторического AWG
инцидента #31. Перед maintenance сопоставьте runtime all/default/interfaces с
project fragment и согласуйте конфликтующие внешние настройки с администратором;
не выполняйте слепой `sysctl -p /etc/sysctl.conf`.

## Быстрая установка

Для обычной установки используйте ветку `stable`. Ветка `main` — интеграционная: изменения сначала проходят CI и проверку, а затем отдельным PR продвигаются в `stable`.

```bash
# 1. Убедись, что AmneziaAWG и Mihomo уже запущены
docker ps | grep amnezia-awg
systemctl status mihomo

# 2. Скачай и запусти установщик
curl -fsSL https://raw.githubusercontent.com/saymer-alt/amnezia-mihomo-gateway/stable/install.sh -o install.sh
chmod +x install.sh
./install.sh

# 3. Проверь, что клиент выходит с IP WARP
# (с подключённого устройства зайди на 2ip.ru или ifconfig.co)
```

---

## Пошаговая установка (ручная)

```bash
install.sh
chmod +x install.sh uninstall.sh
sudo ./install.sh
```

Скрипт автоматически:
1. Найдёт контейнер `amnezia-awg`
2. Определит его Docker-подсеть
3. Определит UDP-порт WireGuard
4. Настроит `sysctl` (`ip_forward=1`, `rp_filter=0`)
5. Создаст скрипт маршрутизации и systemd-юниты
6. Запустит сервис и watchdog

---
---

### Настройка Mihomo (важно!):

```markdown
## Настройка Mihomo (важно!)

В `config.yaml` Mihomo должен быть включён TUN-режим строго со следующими параметрами:

```yaml
# --- НАСТРОЙКА TUN ИНТЕРФЕЙСА ---
tun:
  enable: true
  stack: gvisor
  device: tun-mihomo
  auto-route: false          # <-- СТРОГО false! Иначе отвалится SSH и скрипт конфликтует
  auto-detect-interface: true
  disable-icmp-forwarding: true # strict privacy: не выпускать ICMP через host socket

# --- DNS СЕКЦИЯ (рекомендуется) ---
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  # Возвращаем безопасный диапазон
  fake-ip-range: 198.18.0.0/16
  listen: 0.0.0.0:53
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
  proxy-server-nameserver:
    - 1.1.1.1
```

**Важно:** 
- `auto-route: false` критически важен. Наш скрипт маршрутизации сам создаёт отдельную **таблицу 100** и направляет туда только трафик Докера. Если Mihomo включит `auto-route`, он перехватит весь трафик сервера.
- IPv4 на TUN по-прежнему необходим для корректного IPv4/NAT-сценария, но в **Mihomo 1.19.31** top-level `tun.inet4-address` не управляет этим адресом: `RawTun.Inet4Address` не разбирается, а `parseTun()` формирует IPv4-префикс TUN из `dns.fake-ip-range` и приводит его к `/30`. При нашем `fake-ip-range: 198.18.0.0/16` это объясняет наблюдавшийся live-префикс `198.18.0.0/30`. Installer удаляет legacy top-level `tun.inet4-address`, если он остался от старого конфига, и больше не пытается навязать отдельный `10.255.255.1/30` через неэффективное поле. `inet4-address` внутри per-proxy TUN listeners не удаляется: это другой config path Mihomo, где поле поддерживается.

### Практическая проверка MIPS vs gVisor (21.09.2026)

Проверка выполнялась на **Mihomo 1.19.31**. Новый TUN-стек `mips` был опробован на трёх VPS. На сервере **EE** отдельно выполнены три сравнительных замера при переключении между `gvisor` и `mips`.

Зафиксированные в этой серии результаты Speedtest: **28,9/40,0**, **25,8/45,9** и **34,7/47,6 Мбит/с** (download/upload). По практическому сравнению владельца проекта `mips` оказался примерно на **10 Мбит/с хуже по download**, чем текущий `gvisor`-baseline. Это реальный VPS-тест проекта, а не синтетический benchmark.

Поэтому для серверного сценария этого проекта текущий проверенный выбор остаётся:

```yaml
tun:
  stack: gvisor
```

Это не означает, что `mips` исключён навсегда: его имеет смысл повторно проверить после дальнейшего созревания реализации и обновлений Mihomo. До появления новых сравнительных измерений не менять серверный baseline на `mips` только потому, что этот стек новее или показал себя лучше на роутерах.

`system` и `mixed` владелец также пробовал на VPS, но устойчивого положительного результата не зафиксировано. Для этого gateway они считаются экспериментальными и не рекомендуются; проверенный baseline остаётся `gvisor`, а `mips` — допустимый вариант для повторных экспериментов.

Если используешь WARP через прокси-группу в Mihomo:

```yaml
proxy-groups:
  - name: "WARP"
    type: select
    proxies:
      - "WARP-WireGuard"

proxies:
  - name: "WARP-WireGuard"
    type: wireguard
    server: engage.cloudflareclient.com
    port: 2408
    ...
```
---
---

## Проверка работы

**На сервере:**
```bash
# Статус сервиса
systemctl status warp-docker-routing.service

# Правила маршрутизации
ip rule show
ip route show table 100

# Правила iptables
iptables -t mangle -L PREROUTING -n -v
iptables -t nat -L POSTROUTING -n -v
iptables -L FORWARD -n -v

# Логи watchdog
journalctl -u check-warp-routing.service -n 20
```

**На клиенте (подключённом к AWG):**
```bash
# Должен показать IP Cloudflare WARP (104.x.x.x или 172.x.x.x)
curl https://ifconfig.co

# Должен показать DNS Cloudflare
curl https://1.1.1.1/cdn-cgi/trace
```

---

## Как это работает (для любопытных)

### 1. Policy Routing
Когда пакет покидает Docker-сеть AWG, ядро смотрит на **source IP**. Если он из `DOCKER_NETS`, срабатывает правило:
```bash
ip rule add from 172.29.172.0/24 lookup 100 priority 100
```
В таблице 100 default gateway — это `tun-mihomo`. Пакет уходит в Mihomo.

### 2. Обратный трафик (ответы WireGuard)
Если бы ответы AWG тоже шли через `tun-mihomo`, клиент получил бы их с чужого IP и дропнул. Поэтому:
```bash
iptables -t mangle -I PREROUTING -s DOCKER_NET -p udp --sport WG_PORT -j MARK --set-mark 0x88
ip rule add fwmark 0x88 lookup main priority 40
```
Маркированные пакеты идут через `main` таблицу — напрямую к клиенту.

### 3. rp_filter
`rp_filter=0` отключает проверку обратного пути. Без этого ядро дропает пакеты, которые приходят с одного интерфейса, а уходят с другого (что как раз происходит с Docker bridge → tun).

### 4. Watchdog
Раз в минуту проверяется:
- Жив ли `tun-mihomo`? Если нет — перезапускается `mihomo.service`
- На месте ли правила `ip rule`? Если нет — пересоздаются

---

## Удаление

```bash
sudo ./uninstall.sh
```

Это:
- остановит и отключит routing/watchdog-сервисы;
- сначала остановит watchdog, затем routing service; обычный `cleanup` оставляет fail-secure guard, после чего uninstaller вызывает явный `purge` и удаляет project-owned `iptables`, `ip rule`, terminal route и routing-table routes;
- выполнит ownership-aware rollback системных изменений installer'а (условия — ниже);
- удалит generated scripts и systemd units.

**Rollback опирается на ownership/pre-install state в `/var/lib/amnezia-mihomo-gateway`, который installer записывает при установке.** Каждое системное изменение восстанавливается только при доказанном владении: ownership-маркер плюс checksum match. Состояние, изменённое администратором после установки, не перезаписывается — uninstaller оставляет его без изменений и завершает шаг warning'ом. Pre-existing состояние (существовавший `daemon.json`, чужая запись в `rt_tables`, исходный DNS-механизм, чужие sysctl-значения) никогда не удаляется.

Условия восстановления по компонентам:

- **Mihomo `config.yaml`** — точное pre-install содержимое возвращается только при checksum match текущего файла с записанным пропатченным состоянием и отсутствии флага divergence; кандидат заранее проверяется `mihomo -t -f`, замена атомарная, затем Mihomo перезапускается (systemd-сервис или Docker-контейнер). При любом расхождении текущий config сохраняется.
- **`/etc/docker/daemon.json`** — удаляется только если создан installer'ом (ownership-маркер) и не менялся после установки (checksum match); затем Docker перезапускается.
- **`100 mihomo` в `/etc/iproute2/rt_tables`** — запись удаляется только при ownership-маркере и отсутствии runtime-потребителей (нет правил `ip rule` и маршрутов в таблице 100); если таблица ещё используется, запись сохраняется.
- **DNS** — `systemd-resolved` и `/etc/resolv.conf` восстанавливаются по pre-install snapshot только если текущий `resolv.conf` всё ещё installer-owned (checksum match, обычный файл без symlink): возвращаются исходное содержимое, immutable-атрибут и исходный enabled/active-state `systemd-resolved`.
- **sysctl** — файл `/etc/sysctl.d/99-amnezia-mihomo.conf` и live-значения (`net.core.default_qdisc`, `net.ipv4.tcp_congestion_control`, `net.ipv4.ip_forward`, `rp_filter` по интерфейсам) восстанавливаются только когда файл совпадает по checksum, а текущее live-значение всё ещё равно значению, выставленному installer'ом; admin-modified live-значения сохраняются с warning'ом.

Если хотя бы один шаг не смог доказать ownership (изменённые файлы, неполный rollback-state, ошибка восстановления), uninstall завершает работу с ненулевым кодом выхода (2) и **сохраняет state-dir** для ручной проверки. При полном доказанном rollback state-dir удаляется.

Перед patch `config.yaml` installer создаёт backup `.bak.<timestamp>`.

Подробный live-аудит и release gates:
[docs/LIVE_AUDIT_2026-09-23.md](docs/LIVE_AUDIT_2026-09-23.md).

---

## Траблшутинг

### После `sysctl -p /etc/sysctl.conf` перестал работать AWG через Docker

Для этой схемы `rp_filter=0` критичен: Docker-трафик приходит через bridge, а уходит через `tun-mihomo`. Если в общем `/etc/sysctl.conf` остались старые строки вроде:

```text
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
```

то команда `sysctl -p /etc/sysctl.conf` может повторно применить их и сломать Docker-based AWG path, даже если project-owned fragment и routing service настроены правильно.

Проверь live-состояние:

```bash
sysctl net.ipv4.conf.all.rp_filter \
       net.ipv4.conf.default.rp_filter \
       net.ipv4.conf.ens3.rp_filter \
       net.ipv4.conf.docker0.rp_filter \
       net.ipv4.conf.amn0.rp_filter
```

Для активного `amnezia-mihomo-gateway` ожидается `0` на участвующих интерфейсах. Не используйте whole-file reload как способ применить одну отдельную sysctl-настройку на production gateway: применяйте конкретный ключ или отдельный managed fragment и затем проверяйте live `rp_filter`.

Реальный инцидент 2026-09-29: после whole-file reload Docker AWG 2.0 перестал работать, AWG 3.1 через 3X-UI продолжил работать, а reboot восстановил AWG 2.0. Это сильное причинное свидетельство в пользу `rp_filter`, хотя broken runtime до reboot не был снят packet capture'ом. Отслеживание: issue #31.

### Клиент не подключается к AWG после установки
```bash
# Проверь, что ответы AWG не уходят в tun
iptables -t mangle -L PREROUTING -n -v | grep 0x88
# Должно быть правило с --sport WG_PORT и MARK set 0x88
```

### Сайты открываются, но файлы не скачиваются / видео не грузится
```bash
# Проверь MSS clamping
iptables -t mangle -L FORWARD -n -v | grep TCPMSS
# Если пусто — перезапусти сервис: systemctl restart warp-docker-routing
```

### `Error: Interface 'tun-mihomo' does not exist`
Mihomo не поднял TUN. Проверь:
```bash
systemctl status mihomo
ip link | grep tun
# В конфиге Mihomo должно быть: device: tun-mihomo
```

### Правила слетают после перезагрузки
Убедись, что сервис включён:
```bash
systemctl is-enabled warp-docker-routing.service
systemctl is-enabled check-warp-routing.timer
```

### Два одинаковых правила в iptables
Такого не должно быть — скрипт использует `-C || -A` (проверка перед добавлением). Если всё же появились дубли:
```bash
/usr/local/sbin/warp-docker-routing.sh cleanup
systemctl restart warp-docker-routing
```

---

## Безопасность и ограничения

- **IPv6:** Скрипт настраивает только IPv4. Если у клиентов есть IPv6 и AWG его проксирует — трафик может уйти напрямую. Рекомендуется отключить IPv6 в конфиге AWG (`AllowedIPs = 0.0.0.0/0` без `::/0`).
- **UFW/Firewalld:** Скрипт вставляет правила `FORWARD` в начало цепочки iptables, обходя `DROP` по умолчанию. Если используешь `nftables` — потребуется адаптация.
- **Fail-secure:** защита строится в два слоя: в table 100 постоянно остаётся terminal `unreachable default`, а отдельная project-owned цепочка `AMG_FAILSECURE` разрешает клиентскому трафику только выход через `tun-mihomo` либо помеченный outer AWG reply path. Обычный restart/stop routing service оставляет эти барьеры включёнными; полный демонтаж выполняется только явным `purge` из uninstaller.
- **ICMP privacy:** для Mihomo 1.19.31 installer выставляет `tun.disable-icmp-forwarding: true`. Без этого gVisor может создать host ICMP socket, который идёт в обход обычного TCP/UDP proxy rule matching. Ping клиента в этом режиме не следует использовать как доказательство реального WARP latency.

---

## Лицензия

MIT

---

## Автор

Сделано для тех, кто не хочет светить IP своего VPS.

Если скрипт помог — поставь ⭐



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
| `uninstall.sh` | Удаление routing rules, сервисов и generated files; **не полный rollback** системных изменений (см. раздел «Удаление») |
| `warp-docker-routing.sh` | Скрипт маршрутизации (создаётся автоматически в `/usr/local/sbin/`) |
| `check-warp-routing.sh` | Watchdog: проверяет наличие tun-интерфейса и правил раз в минуту |
| `warp-docker-routing.service` | Systemd unit для маршрутизации |
| `check-warp-routing.timer` | Systemd timer для watchdog |

---

## Требования

- **OS:** Debian 12 / Ubuntu 22.04+ (другие systemd-based дистрибутивы — вероятно, тоже)
- **Docker:** Установлен и запущен
- **AmneziaAWG:** Контейнер `amnezia-awg` запущен и работает
- **Mihomo (Clash Meta):** Запущен как `mihomo.service` или Docker-контейнер; в конфиге включён TUN-интерфейс `tun-mihomo`
- **Root:** Скрипт запускается от root

---

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
  inet4-address: 10.255.255.1/30 # <-- Текущее значение installer v2.0; без IPv4 адреса NAT не будет работать

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
- `inet4-address` обязателен для создания IPv4-адреса на интерфейсе, чтобы `iptables` могла корректно делать MASQUERADE. Текущий installer v2.0 использует `10.255.255.1/30` и приводит `fake-ip-range` к `198.18.0.0/16`.

### Практическая проверка MIPS vs gVisor (21.09.2026)

Проверка выполнялась на **Mihomo 1.19.31**. Новый TUN-стек `mips` был опробован на трёх VPS. На сервере **EE** отдельно выполнены три сравнительных замера при переключении между `gvisor` и `mips`.

Зафиксированные в этой серии результаты Speedtest: **28,9/40,0**, **25,8/45,9** и **34,7/47,6 Мбит/с** (download/upload). По практическому сравнению владельца проекта `mips` оказался примерно на **10 Мбит/с хуже по download**, чем текущий `gvisor`-baseline. Это реальный VPS-тест проекта, а не синтетический benchmark.

Поэтому для серверного сценария этого проекта текущий проверенный выбор остаётся:

```yaml
tun:
  stack: gvisor
```

Это не означает, что `mips` исключён навсегда: его имеет смысл повторно проверить после дальнейшего созревания реализации и обновлений Mihomo. До появления новых сравнительных измерений не менять серверный baseline на `mips` только потому, что этот стек новее или показал себя лучше на роутерах.

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
- вызовет `cleanup` и удалит созданные проектом `iptables`, `ip rule` и routing-table routes;
- удалит generated scripts, systemd units и `/etc/sysctl.d/99-amnezia-mihomo.conf`;
- удалит запись `100 mihomo` из `/etc/iproute2/rt_tables`, если после cleanup таблица больше никем не используется;
- удалит `/etc/docker/daemon.json`, **только если этот файл создал installer и он не был изменён позже**;
- для старых установок без state marker распознает только точный legacy-файл вида
  `{"dns": ["<docker0-gateway>"]}`, который создавали прежние версии installer'а, и после удаления перезапустит Docker.

Новые установки хранят ownership-markers в `/var/lib/amnezia-mihomo-gateway`.
Это нужно, чтобы uninstall не удалял пользовательский `daemon.json`.

**Почему это важно.** На живом Debian 12 сервере 23.09.2026 обнаружились два legacy-хвоста.
Во-первых, после удаления gateway в Mihomo оставались installer-патчи (`tun`, `fake-ip-range`,
`find-process-mode: off`, `store-selected/store-fake-ip: false` и другие значения), потому что
старый uninstall не восстанавливал pre-install config. Во-вторых, остался старый
`daemon.json` с `"dns": ["172.17.0.1"]`. Docker продолжал отправлять DNS контейнера в Mihomo,
хотя TUN/policy routing уже были отключены. В результате `amnezia-awg` получал
`Resolving timed out`. После удаления override Docker снова использовал DNS хоста
(1.1.1.1 / 8.8.8.8), и DNS/HTTPS внутри контейнера сразу восстановились.

**Важно: это всё ещё не полный rollback сервера к состоянию до установки.** `uninstall.sh`
пока не восстанавливает автоматически:

- live-значения sysctl, уже применённые installer'ом;
- `systemd-resolved`, если installer его отключил;
- прежний `/etc/resolv.conf` и его immutable attribute;
- автоматически пропатченный `config.yaml` Mihomo для **legacy-установок**, сделанных до появления ownership-state.

Для новых установок installer сохраняет точный pre-install snapshot Mihomo в
`/var/lib/amnezia-mihomo-gateway/mihomo_config_original.yaml` и checksum пропатченного файла.
При uninstall исходный конфиг восстанавливается автоматически **только если текущий config.yaml
не менялся после installer'а**. Если администратор правил его вручную, uninstall ничего не
перезаписывает и оставляет snapshot для ручного сравнения/rollback.

Обычный timestamp-backup `config.yaml.bak.<timestamp>` также продолжает создаваться перед каждым patch.

---

## Траблшутинг

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
- **Fail-secure:** Если `tun-mihomo` падает, трафик из Docker-сети не уходит в интернет напрямую (нет fallback-маршрута в `main` таблице). Клиенты останутся без интернета, но IP сервера не вылезет.

---

## Лицензия

MIT

---

## Автор

Сделано для тех, кто не хочет светить IP своего VPS.

Если скрипт помог — поставь ⭐

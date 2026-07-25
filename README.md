---
```markdown
# awg-warp-router

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
│  ┌─────────────────────────────────────────────────┐   │
│  │  ip rule: from Docker_Net -> lookup table 100   │   │
│  │  ip route: default dev tun-mihomo (table 100)   │   │
│  └─────────────────────────────────────────────────┘   │
│                           │                             │
│              ┌────────────┴────────────┐               │
│              │                         │               │
│              ▼                         ▼               │
│    ┌─────────────────┐      ┌─────────────────┐       │
│    │  Обычный трафик │      │  Ответы AWG     │       │
│    │  (TCP/UDP)      │      │  (WG_PORT)      │       │
│    │  -> tun-mihomo  │      │  -> fwmark 0x88 │       │
│    │  -> WARP        │      │  -> main table  │       │
│    │  -> Интернет    │      │  -> Клиент      │       │
│    └─────────────────┘      └─────────────────┘       │
└─────────────────────────────────────────────────────────┘
```

**Ключевые моменты:**
- **Таблица 100** — весь трафик из Docker-сети AWG идёт через `tun-mihomo`
- **fwmark 0x88** — ответы WireGuard (UDP с source port WG_PORT) маркируются и идут напрямую к клиенту, минуя прокси. Без этого клиент не сможет подключиться.
- **MASQUERADE** — NAT трафика перед отправкой в tun-интерфейс
- **TCPMSS clamping** — корректировка MTU для стабильной работы через двойную инкапсуляцию (AWG + WARP)

---

## Что входит в проект

| Файл | Назначение |
|---|---|
| `install.sh` | Установщик. Автоопределяет сеть Docker, порт AWG, создаёт скрипты и systemd-юниты |
| `uninstall.sh` | Полное удаление всех правил, сервисов и файлов |
| `warp-docker-routing.sh` | Скрипт маршрутизации (создаётся автоматически в `/usr/local/sbin/`) |
| `check-warp-routing.sh` | Watchdog: проверяет наличие tun-интерфейса и правил раз в минуту |
| `warp-docker-routing.service` | Systemd unit для маршрутизации |
| `check-warp-routing.timer` | Systemd timer для watchdog |

---

## Требования

- **OS:** Debian 12 / Ubuntu 22.04+ (другие systemd-based дистрибутивы — вероятно, тоже)
- **Docker:** Установлен и запущен
- **AmneziaAWG:** Контейнер `amnezia-awg` запущен и работает
- **Mihomo (Clash Meta):** Установлен как systemd-сервис `mihomo.service`, в конфиге включён TUN-интерфейс с именем `tun-mihomo`
- **Root:** Скрипт запускается от root

---

## Быстрая установка

```bash
# 1. Убедись, что AmneziaAWG и Mihomo уже запущены
docker ps | grep amnezia-awg
systemctl status mihomo

# 2. Скачай и запусти установщик
curl -fsSL https://raw.githubusercontent.com/ТВОЙ_НИК/awg-warp-router/main/install.sh | sudo bash

# 3. Проверь, что клиент выходит с IP WARP
# (с подключённого устройства зайди на 2ip.ru или ifconfig.co)
```

---

## Пошаговая установка (ручная)

```bash
git clone https://github.com/ТВОЙ_НИК/awg-warp-router.git
cd awg-warp-router
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

## Настройка Mihomo (важно!)

В `config.yaml` Mihomo должен быть включён TUN-режим:

```yaml
tun:
  enable: true
  stack: gvisor        # или system / mixed
  dns-hijack:
    - "any:53"
  auto-route: true
  auto-detect-interface: true
  device: tun-mihomo   # <-- именно это имя использует скрипт
```

**Важно:** `auto-route: true` позволяет Mihomo самому управлять маршрутами в `main` таблице. Наш скрипт не трогает `main` таблицу — он создаёт отдельную **таблицу 100**, поэтому конфликтов не будет.

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
- Остановит и отключит сервисы
- Вызовет `cleanup` (удалит все `iptables`, `ip rule`, `ip route`)
- Удалит все созданные файлы
- Вернёт `sysctl` к состоянию по умолчанию (файл `99-amnezia-mihomo.conf` удаляется)

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
```

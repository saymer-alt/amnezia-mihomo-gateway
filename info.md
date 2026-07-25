# awg-warp-router

Автоматическая маршрутизация трафика **AmneziaAWG** через **Mihomo TUN** с выходом в интернет через **Cloudflare WARP**.

Клиенты подключаются к твоему серверу по AmneziaWG, но сайты видят IP-адрес Cloudflare WARP — реальный IP сервера остаётся скрытым.

---

## ⚡ Быстрая установка (одной командой)

```bash
curl -fsSL https://github.com/saymer-alt/amnezia-mihomo-gateway/main/install.sh | sudo bash
```

---

## 🛠 Ручная установка

### 1. Установка

Зайди на сервер по SSH и выполни:

```bash
nano install.sh
```

Вставь код из файла `install.sh` этого репозитория.  
Сохрани: `Ctrl+O`, `Enter`, `Ctrl+X`.  
Сделай исполняемым и запусти:

```bash
chmod +x install.sh
sudo ./install.sh
```

### 2. Удаление

Если нужно всё откатить:

```bash
nano uninstall.sh
```

Вставь код из файла `uninstall.sh` этого репозитория.  
Сохрани: `Ctrl+O`, `Enter`, `Ctrl+X`.  
Сделай исполняемым и запусти:

```bash
chmod +x uninstall.sh
sudo ./uninstall.sh
```

---

## 📋 Что делает скрипт

1. **Auto-detect** — сам находит контейнер Амнезии, определяет его подсеть Docker (например `172.29.172.0/24`), парсит UDP-порт AWG (например `51820` или `31825`) и определяет главный сетевой интерфейс сервера.
2. **Kernel Config** — отключает `rp_filter` и включает `ip_forward` (создаёт файл в `/etc/sysctl.d/99-amnezia-mihomo.conf`).
3. **Routing Script** — генерирует `/usr/local/sbin/warp-docker-routing.sh` с уже подставленными переменными.
4. **Systemd Services** — создаёт `warp-docker-routing.service` и привязывает его к запуску после `mihomo.service` и `docker.service`.
5. **Watchdog** — создаёт скрипт проверки и systemd-timer, который раз в минуту проверяет: жив ли интерфейс `tun-mihomo` и не слетели ли правила маршрутизации. Если что-то упало — сам восстанавливает.
6. **Auto-restart** — прописывает `Restart=always` для сервиса Mihomo (если он установлен как системный сервис).

---

## ✅ Проверка работы

**На клиенте** (подключённом к AWG):
- Зайди на [2ip.ru](https://2ip.ru) или выполни `curl https://ifconfig.co`
- Должен показаться IP Cloudflare WARP (`104.x.x.x` или `172.x.x.x`), а не IP твоего VPS

**На сервере:**
```bash
systemctl status warp-docker-routing.service
ip rule show
ip route show table 100
```

---

## 🏗 Архитектура

```
Клиент (AWG) ──UDP──> AmneziaAWG (Docker)
                              │
                              ▼
                    Docker bridge (172.x.x.0/24)
                              │
                              ▼
              ┌───────────────────────────────┐
              │  ip rule: from Docker_Net     │
              │         lookup table 100      │
              └───────────────────────────────┘
                              │
                              ▼
                    tun-mihomo (Mihomo TUN)
                              │
                              ▼
                    Cloudflare WARP / Интернет
```

- **Таблица 100** — весь исходящий трафик из Docker-сети идёт через `tun-mihomo`
- **fwmark 0x88** — ответы WireGuard маркируются и идут напрямую к клиенту, минуя прокси (иначе подключение не установится)
- **TCPMSS clamping** — корректировка MTU для стабильной работы через двойную инкапсуляцию (AWG + WARP)

---

## ⚠️ Требования

- Debian 12 / Ubuntu 22.04+
- Docker с запущенным контейнером `amnezia-awg`
- Mihomo (Clash Meta) установлен как systemd-сервис `mihomo.service` с включённым TUN-интерфейсом `tun-mihomo`
- Права root

---

## 🧹 Траблшутинг

**Клиент не подключается:**
```bash
iptables -t mangle -L PREROUTING -n -v | grep 0x88
```

**Сайты открываются, но файлы не качаются:**
```bash
iptables -t mangle -L FORWARD -n -v | grep TCPMSS
```

**Интерфейс tun-mihomo не найден:**
```bash
systemctl status mihomo
# В config.yaml Mihomo должно быть: device: tun-mihomo
```


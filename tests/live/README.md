# Disposable VPS Live Acceptance Kit

Оркестрация, сбор доказательств и верификация для финального live-гейта
patch-релиза (`v2.0.1`). Кит **не содержит логики шлюза**: единственный source
of truth — публичный продакшн-канал
`raw.githubusercontent.com/saymer-alt/amnezia-mihomo-gateway/stable/{install,uninstall}.sh`.
Кит только скачивает их (с проверкой SHA256 против запиненных значений),
запускает и собирает доказательства.

Целевой цикл:

```text
baseline → install → verify → DDP proof → repeated install → verify
→ reboot → verify → uninstall → baseline comparison
```

## Границы

- **Только disposable VPS.** Продакшн-хосты (вся текущая флота — production
  VPN-шлюзы) не подходят по определению.
- `NO EXPLICIT DISPOSABLE OPT-IN → NO DESTRUCTIVE ACTION`: деструктивные
  шаги требуют **двух** независимых подтверждений:
  `AMG_DISPOSABLE_TEST_HOST=YES` (env) и `--confirm-disposable` (argv).
- Хост с уже существующим состоянием шлюза (ownership state-dir, generated
  units/scripts, `100 mihomo` в rt_tables, `AMG_FAILSECURE` в iptables,
  policy-правило) → **REFUSE**: это либо production, либо чужой запуск кита.
  Hostname/IP никогда не считаются доказательством disposable-статуса.
- `run-post-reboot.sh` продолжает только **свой** run: checkpoint
  (`READY-FOR-REBOOT`) + совпадение `machine-id` хоста.

## Требования к disposable VPS (§ provisioning prerequisites)

- Ubuntu 24.04 (основная проверенная платформа; Debian 12 — поддерживается
  китом как цель, но live-приёмка на нём пока не проводилась — честно
  зафиксируйте ОС в отчёте).
- 1 vCPU / 1 GiB RAM / ~10 GB диска — подтверждено фактической эксплуатацией
  флота (весь прод-стек живёт на машинах этого класса); меньше — не проверялось.
- root SSH, публичный IPv4, systemd, Docker (CS/CE любой свежий), возможность
  reboot, желательно консоль хостера. Временная/одноразовая.

## Подготовка стека на disposable-хосте

Кит требует, чтобы ДО установки уже стояли (проверка FAIL BEFORE MUTATION):

1. Docker + AWG-контейнер с именем на `amnezia-awg` (installer ищет
   `name=amnezia-awg`).
2. Mihomo (systemd-сервис `mihomo.service` или контейнер с `mihomo` в имени).
3. Ровно один `config.yaml` в местах поиска installer'а
   (`/etc/mihomo /opt/mihomo /root /home`, maxdepth 3).

Для DDP-сценария конфиг обязан содержать `profile.store-fake-ip: true` плюс
текущие секции генератора (`dns` + `fake-ip-range`, `tun` + `dns-hijack`,
`sniffer`). Скелет без секретов: [`fixtures/ddp-config-skeleton.yaml`](fixtures/ddp-config-skeleton.yaml)
(структурный; для traffic/privacy-проверки подмените upstream на реальный
конфиг из VPS-профиля link-generators или положитесь на probe-контейнер,
если у Mihomo есть рабочие upstream).

## Порядок запуска

```bash
# 1. provision VPS (см. требования выше), подготовить стек по скелету
# 2. забросить кит на хост (git clone репо или scp каталога tests/live)
cd tests/live

# 3. baseline + assertions + скачивание/проверка installer + install + verify
#    + repeated install + verify + fake-ip snapshot
sudo AMG_DISPOSABLE_TEST_HOST=YES ./run-pre-reboot.sh --confirm-disposable

# 4. reboot (вручную; SSH-сессия оборвётся — это ожидаемо)
sudo reboot

# 5. после возврата хоста: post-reboot verify + DDP/fake-ip proof
#    + watchdog no-false-repair + (опционально traffic probe)
sudo AMG_DISPOSABLE_TEST_HOST=YES ./run-post-reboot.sh \
  --run-dir "$HOME/amg-live-acceptance/live-acceptance-<ts>" --confirm-disposable

#    в конце скрипт спросит подтверждение UNINSTALL; для неинтерактивного
#    запуска добавьте --yes-uninstall
# 6. verdict: FINAL-VERDICT.txt (BASELINE RESTORED / список unexpected diffs)
# 7. destroy VPS
```

Опциональные переменные:

- `AMG_EVIDENCE_ROOT` — каталог для run-директорий (по умолчанию
  `~/amg-live-acceptance`).
- `AMG_TRAFFIC_PROBE=YES` — включить автоматический traffic-проб
  (ephemeral-контейнер в сети AWG → cloudflare trace; `warp=on` и egress IP ≠
  host IP). Без него — `MANUAL STEP REQUIRED` с готовой командой.
- `AMG_FAKEIP_PROBE_DOMAIN` — домен для fake-ip persistence (по умолчанию
  `www.example.com`).
- `AMG_PROBE_IMAGE` — образ для probe-контейнера (по умолчанию
  `curlimages/curl`).
- `--expected-sha <hex>` (только `run-pre-reboot.sh`) — переопределение пина
  install.sh. Использовать ТОЛЬКО после независимого re-audit нового stable
  blob; кит обязан refuse при любом расхождении по умолчанию.

Read-only шаги можно запускать отдельно (без opt-in — они ничего не меняют):

```bash
./collect-baseline.sh <run-dir> <slot>       # slot: baseline|post1|post2|postreboot|postuninstall
./verify-gateway.sh <slot-dir>               # инварианты текущего AGENTS.md
./verify-gateway.sh --self-test              # парсеры на фикстурах
./verify-ddp.sh <run-dir> baseline post1 post2 postreboot
./compare-baseline.sh <run-dir>              # финальный вердикт цикла
```

## Что проверяется

- **verify-gateway** (по собранным артефактам, текущий контракт):
  TUN up + /30 из fake-ip-range; source-правило в table 100/mihomo (обе
  формы рендера); fwmark `0x88` → main; preferred TUN default metric 10;
  terminal `unreachable default metric 42760`; fake-IP route; хук и все три
  правила `AMG_FAILSECURE`; отсутствие legacy broad source ACCEPT; TCPMSS
  clamp; MASQUERADE; reverse FORWARD; сервисы + таймер; mihomo жив.
- **verify-ddp**: `store-fake-ip: true` переживает install/re-install/reboot
  (byte-identity whitelist-набора ключей между слотами);
  `tun.dns-hijack`/`sniffer`/`device`/`auto-route` дословно;
  `fake-ip-range`/`stack` — нормализованный текущий контракт. Печатаются
  только whitelist-ключи, никогда — приватные значения конфига.
- **run-pre-reboot**: дубликаты после повторной установки (правила, маршруты,
  iptables, ключи конфига, ожидаемые ровно 2 конфиг-бэкапа), SHA256 публичного
  installer'а против пина.
- **run-post-reboot**: восстановление после reboot; fake-ip persistence
  (тот же ответ 198.18.x.x, что до reboot; иначе MANUAL STEP); ручной запуск
  watchdog на здоровой топологии не должен рестартовать сервис
  (NRestarts стабилен); uninstall exit 2 = неполный rollback = FAIL;
  compare-baseline.
- **compare-baseline**: EXACT MATCH / EXPECTED DIFFERENCE / UNEXPECTED
  DIFFERENCE по контролируемым позициям; volatile (meta: дата/uptime) не
  сравнивается; ожидаемый residue — только `config.yaml.bak.<epoch>` и
  удалённый ownership state-dir после доказанного rollback. Итог —
  `BASELINE RESTORED` или точный diff.

## Evidence policy (§ что можно прикладывать к PR/отчёту)

Пишется в `<AMG_EVIDENCE_ROOT>/live-acceptance-<ts>/` (на disposable-хосте,
в git не коммитится):

- **Безопасно прикладывать**: `FINAL-VERDICT.txt`, `CHECKPOINT`,
  `install-1.log`, `install-2.log`, `uninstall.log`,
  `downloads/SHA256SUMS`, `*/ddp-keys.txt` (whitelist-ключи),
  `trace-host.txt`, `trace-awg-net.txt`, сводку compare-baseline,
  `watchdog-manual-run.log`.
- **Никогда не прикладывать**: `*/mihomo-config-copy.REDACTED.yaml`
  (редакция best-effort; реальный конфиг может содержать секреты в иных
  формах), сырые `docker.txt`/`ip-addr.txt` (содержат адреса хоста),
  `sysctl.txt`/`dns-state.txt` — только в обезличенном виде по решению
  владельца. Публичные адреса disposable-хоста в PR не публикуются.

## Тесты самого кита

`bash tests/live/test-kit.sh` (запускается в CI): refusal-пути (нет opt-in,
нет второго подтверждения, prior state, wrong stage, чужой machine-id),
redaction (ключи/пароли/URL-userinfo), парсеры (named+numeric рендеры,
здоровый/сломанный фикстур-набор), extract_ddp_keys на shipped-фикстуре,
классификация пар компаратором. Требует только bash; root/VPS не нужны.

## Scope

- Проверено для: Ubuntu 24.04 (целевая платформа live-приёмки v2.0.1).
- Debian 12: кит написан под обе ОС (bash + systemd + docker), но live-цикл
  на Debian 12 не проводился — если приёмка идёт на Ubuntu 24.04, так и
  пишите в отчёте.
- Другие ОС не заявляются и не поддерживаются без отдельных доказательств.

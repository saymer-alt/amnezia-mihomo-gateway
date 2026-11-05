# Независимая ревизия #20 / #21 / #22 и Draft #45 — 2026-11-05

**Метод:** read-only ревизия main (`086fe1b`) и Draft #45 (`36f3e3c`); полный прогон
fixture-наборов в локальной disposable Linux-лаборатории (WSL). Без реальных VPS,
без перезапусков Docker, без изменений host DNS/Docker/iptables/sysctl. Этот
документ — доказательная запись, не production acceptance.

## #20 — runtime identity (приоритет 1)

**Дефект main подтверждён:** выбор конфига — `find /etc/mihomo /opt/mihomo /root /home
-maxdepth 3 -name config.yaml | head -n1` (install.sh:243): «первый найденный» не является
доказательством runtime identity (случай live-2026-09-29 с backup в /root — везение, не механизм).
Сам patcher при этом scoped/atomic и отказывается от symlink/hardlink/неоднозначных структур —
дефект именно в выборе пути.

**Draft #45: что доказывает admission.** Один запущенный mihomo-процесс (`/proc`, ровно один),
ровно один контроллер (systemd `mihomo.service` MainPID+active либо Docker по точному ID с
совпадением State.Pid и argv), конфиг только из argv (`-f`, либо `-d config.yaml`; in-memory/
encrypted/test/env-конфиги и default-guessing отвергаются), для Docker — ровно один RW directory
bind-mount с проверкой device/inode через `/proc/PID/root`, re-check до state-записей, перед
backup и непосредственно перед atomic rename; watchdog и restart используют выбранный контроллер,
а не «первое похожее имя». `test_preflight_before_all_writes` фиксирует: admission до `mkdir state`,
`find`-поиска больше нет. Fixtures: 23 → **25** (добавлены формы перехода, ниже); полный набор и
все существующие regression-наборы — PASS локально на ветке PR и на main.

**Блокер Draft #45 (daemon.json → Docker restart → смена PID) — разбор.**
Порядок PR: discovery (PID X) → sysctl/table/DNS → создание daemon.json (только если файл
отсутствует) + restart Docker → контейнер Mihomo возвращается с PID Y → все последующие
`verify` отказываются → install завершается отказом **после** уже сделанных sysctl/DNS-записей
(fail-closed, но частично применённая установка; повторный запуск завершается успешно, т.к.
daemon.json уже существует и Docker не перезапускается). Молча пере-открывать другой runtime
нельзя — это правильно зафиксировано в PR.

| Вариант | Суть | Оценка |
|---|---|---|
| **A. Перенести создание daemon.json до discovery** (рекомендация) | единственный шаг, вызывающий restart Docker, выполняется до сэмплирования identity; discovery после restart = fresh admission; если контейнер не вернулся — чистый отказ **до** каких-либо системных записей | минимальное окно отказа; требует обновления порядка в AGENTS.md (owner decision) |
| B. Сохранить порядок; отказ + повторный запуск | текущее поведение draft | безопасно, но частичные ранние записи и неожиданность для оператора |
| C. Явная re-admission при том же container ID | `docker restart` сохраняет ID (меняется только PID/StartedAt); recreate меняет ID. Re-bind допустим только при: том же ID, argv, mount и config-inode; любое отличие — отказ | сильнее, но требует новой admission-логики,fixtures и владения решением |

**Новые fixtures (этот PR, test-only):** `test_docker_same_id_restart_new_pid_refused`
(тот же container ID, новый PID/StartedAt — форма блокера; verify обязан отказывать) и
`test_docker_recreated_container_new_id_refused` (recreate: новый ID при том же имени/argv/
mounts — fresh admission обязателен, mid-run verify отказывает). Формы перехода теперь
зафиксированы как fail-closed до owner-решения о варианте A/C.

### Решение-кандидат: вариант C — тот же container ID, явная re-admission (2026-11-05, продолжение)

Реализовано в install.sh (ветка этого PR): новый режим `readmit` в runtime-binding — после
**установщиком вызванного** `systemctl restart docker` (единственный шаг, перезапускающий Docker)
для Docker-bound Mihomo выполняется явная повторная привязка. Re-admission принимается ТОЛЬКО при
полной идентичности: container ID, argv, mounts, config path, config file fingerprint
(device/inode + sha256); различаться могут только PID/start процесса и State.Pid/StartedAt
контейнера. Любое другое изменение (recreate с новым ID, подмена mount, смена argv, внешняя правка
конфига) — отказ fail-closed. Сообщение о re-admission печатается явно; молчаливого rediscovery нет.
systemd-bound Mihomo этим переходом не затрагивается и продолжает строгий verify.

**Почему не A (перенос daemon.json до discovery):** перенос перемещает системную мутацию
(создание daemon.json + перезапуск Docker) ДО runtime admission: на хосте без запущенного Mihomo
установщик сначала мутировал бы Docker-состояние и только затем отказал — регрессия против
текущего порядка, где no-running-Mihomo отказывает до любых записей. Успешный Docker restart
тоже перестаёт быть покрытым проверкой живого Mihomo (admission до restart ничего не знает о
последствиях restart для контейнера).

**Почему C — самый маленький проверяемый вариант (оценка по критериям):**
SSH/management access — не затрагивается (переход не касается SSH-путей); восстановление после
частичной операции — при отказе re-admission сохраняется прежняя честная семантика B (повторный
запуск завершает установку: daemon.json уже существует, restart не повторяется); ownership уже
изменённых файлов — не меняется (daemon.json-admission и DNS ownership работают как раньше);
неуспешный Docker restart — контейнер не вернулся → нет mihomo-процесса → отказ no-runtime до
любой записи конфига; container recreation — новый ID не принимается (fresh admission); замена
mounts — mount-набор входит в сравнение; PID reuse — PID сопоставляется с `State.Pid` того же
container ID + exe/argv/env-check; race discovery ↔ atomic rename — сохранены существующие
fingerprint и re-verify перед rename; идемпотентность повторного запуска — daemon.json уже
существует → restart не выполняется → readmit не вызывается.

**BLOCKED (без изменений):** реальный Docker acceptance перехода (настоящий restart/recreate,
PID reuse, reboot) — disposable VPS.

**BLOCKED (требует disposable VPS / live):** реальный systemd override/drop-in ExecStart,
реальные Docker directory mounts, PID reuse, argv/cwd/config-правки между discovery и rename,
reboot; fixtures не доказывают поведение systemd/Docker/Mihomo (по семантике сверено с 1.19.31).
#20 остаётся открытым до disposable acceptance из RUNTIME_DISCOVERY_ACCEPTANCE.md.

## #22 — outer-AWG identity (приоритет 2)

**Риск подтверждён анализом правила:** mangle PREROUTING `-s <docker-subnet> -p udp --sport 39551
-j MARK 0x88` — признаки живут в общем namespace: любой процесс/контейнер той же подсети может
открыть UDP source port 39551 и получить main-таблицу (bypass tun-mihomo). Это анализ достижимого
правила; эксплуатационный packet proof в работе не получался.

**Сравнение признаков (дополнение к OUTER_AWG_IDENTITY_RESEARCH.md):**

| Признак | Применимость к PREROUTING forwarded-трафику | Вывод |
|---|---|---|
| subnet + sport (текущий) | да | необходимый транспортный признак, недостаточный: namespace общий |
| `-m owner` / `-m cgroup` | **нет** — работают только для локально созданных пакетов (OUTPUT path), forwarded bridge-трафик не имеет host-сокета | не кандидат |
| CONNMARK | да, но | сохраняет ПЕРВОЕ решение, не устанавливает identity; нельзя смешивать inner client flows с outer transport |
| `-m physdev --physdev-in <veth AWG>` | да (br_netfilter) | единственный точечный якорь в PREROUTING без смены архитектуры; veth живёт столько же, сколько контейнер — брать из runtime admission, не угадывать по имени |
| список peer endpoints | да | только дополнительное ограничение назначения: endpoints динамические (roaming/DNS/несколько), не критерий отправителя |
| отдельный transport namespace/bridge | — | структурное решение, требует реального Docker/AWG приёмки |

Рекомендация из research-документа остаётся: доказать ingress AWG veth (physdev) и сочетать его
с текущими транспортными признаками и lifecycle admission; peer-IP порт-хардкод не закреплять.

**Негативный тест:** `tests/lab-outer-awg-identity.py --run-isolated` (opt-in, изолированные
user/net/mnt namespaces; awg-суррогат 172.29.0.2 и attacker 172.29.0.3 оба шлют UDP sport 39551):
старый classifier пропускает обоих (утечка доказывается), кандидат с `physdev-in` пропускает только
AWG-veth и блокирует attacker **включая spoofed source IP**, отсутствие classifier блокирует
транспорт, ошибочная доставка = FAIL. Guards-набор (`test-outer-awg-lab-guards.py`) — PASS.

**Ограничение этого окружения (уточнение причины SKIP):** WSL запрещает чтение
`/proc/<pid>/ns/*` чужих процессов даже для root и даже для прямых детей — admission лаборатории
(сверка namespace'ов родителя и ребёнка) принципиально не выполнима; это свойство среды, а не
дефект AMG. Требуется disposable Linux-хост. **Доступность механизма physdev (read-only проверка,
WSL kernel 6.18.54.1-microsoft-standard-WSL2):** userspace-расширение `iptables -m physdev`
присутствует (nf_tables backend 1.8.11), модуль ядра `xt_physdev.ko` есть в модулях ядра,
`br_netfilter` загружен (`/proc/sys/net/bridge/bridge-nf-call-*` доступны) — то есть блокер
лаборатории именно в ns-admission, а не в отсутствии механизма; тем не менее правило-кандидат
требует packet proof на disposable стенде. **BLOCKED:** реальный AWG handshake/RX/TX/WAN-capture,
модель возможностей attacker, multiple peers/roaming/reconnect/recreate/reboot, окна при замене
правил, скорость/MTU/MSS. #22 остаётся открытым; только исследование/opt-in инструмент, не
production-изменение bypass identity.

## #21 — дополнение: негативный кейс «ошибка между созданием daemon.json и Docker restart»

Добавлен в `tests/test-ownership-rollback.sh` (реальный DNS-блок install.sh на fixture-путях,
stateful systemctl mock): первый прогон с `MOCK_SYSTEMCTL_FAIL='restart docker'` — установка
честно падает, daemon.json создан, ownership-записи (created/sha256) соответствуют диску; второй
прогон — ветка создания пропущена (файл существует), **ни повторного присвоения, ни повторного
`restart docker` в логе**, content и sha неизменны. Покрыт сценарий «ошибка между Docker restart
и state persistence» из матрицы #21: state не опережает диск, восстановление — повторный запуск +
операторский restart Docker вручную (это единственный restart-site). Остальные пункты матрицы
#21 (regular/symlink/missing/immutable resolv.conf, resolved active/enabled, admin-managed
daemon.json, внешние изменения, staging-ошибки) уже покрыты существующим набором; disposable-VPS
приёмка — BLOCKED.

## #21 — ownership-aware DNS (приоритет 3)

**Матрица ownership (сверена с кодом main; детальная таблица —
DNS_OWNERSHIP_ACCEPTANCE.md):**

| Ресурс / ситуация | Admission | Проверка |
|---|---|---|
| resolv.conf snapshot | ровно одна форма: regular/symlink/missing-marker; противоречивая → отказ DNS-мутации | `test-ownership-rollback.sh` PASS |
| systemd-resolved | новый host DNS change только при исходно active resolved + доказанный enabled/disabled-state; отключение требует успешной команды + свежих наблюдений | mocks; реальный systemd — BLOCKED |
| daemon.json | создание только при truly absent (`! -e && ! -L`); существующий файл (в т.ч. admin-managed) не присваивается; удаление owned — marker+checksum+regular+single-link; same-byte symlink/hardlink divergence сохраняется | fixture-набор PASS |
| rollback | восстановление только собственных изменений и только при доказуемом expected-current-state (checksum/type/immutable/resolved-state); staging → re-check → clear immutable → atomic rename → свежий readback; внешние изменения после install — preserve, не угадывать | PASS (включая admin-modified, edit-during-staging, failed-copy/restore, success-without-state-change) |
| ошибки | не объявлять полный успех: snapshot/state сохраняются, exit 2; частично восстановленное состояние требует ручного разбора | PASS |

**Границы (честно):** это не атомарная транзакция между filesystem/systemd/Docker; первичная
установка может остановить resolved до ошибки последующей записи; guards/readback — не блокировка
произвольных внешних root-writers; mocks не доказывают DNS reachability, реальные immutable
capabilities, сбои systemd и Docker/reboot-взаимодействие.

**BLOCKED (только disposable VPS):** 6-шаговая приёмка из DNS_OWNERSHIP_ACCEPTANCE.md
(clean baseline → install → gateway → reboot → admin-change scenarios → uninstall/purge →
exact before/after ownership validation). Host DNS/Docker/iptables/sysctl/маршрутизация рабочего
сервера не менялись.

## Статус

- Draft #45: корректен как candidate; остаётся draft до owner-решения по переходу (вариант A/C)
  и disposable acceptance. Этот PR добавляет только fixtures перехода и настоящий документ.
- Ни deploy, ни перезапусков Docker, ни network apply, ни merge, ни релизов; main/stable не тронуты.

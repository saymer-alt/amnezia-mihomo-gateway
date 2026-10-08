# Runtime-aware discovery: кандидат и границы приёмки (#20)

**Статус: draft; merge в main не разрешён до проверки полного installer-перехода.**

Кандидат заменяет поиск первого похожего YAML на read-only binding к одному запущенному Mihomo. Discovery выполняется до создания installer state. Требуется Python 3.9+ — он доступен в целевых Debian 12 / Ubuntu 22.04+.

Авторитетные входы: `/proc/PID/cmdline`, start time, identity окружения, executable, root и cwd; systemd `MainPID`/`ActiveState`/`ExecStart` либо точный Docker ID, init PID, command arguments и mounts. Относительный `-f` разрешается от cwd процесса. `-d` задаёт `config.yaml` только при отсутствии `-f`. Backup-файлы и порядок обхода каталогов не выбирают конфиг. Directory bind должен указывать на тот же device/inode, который виден через `/proc/PID/root`. Единственный механизм изменения YAML — существующий atomic/scoped patcher.

Binding проверяется до создания state, перед backup/config-state и непосредственно перед atomic rename. Перед restart повторно проверяется controller; допускается только собственная замена inode/content конфига. Installer и генерируемый watchdog перезапускают выбранный service/container, не первый похожий по имени.

Fixtures покрывают systemd `-d`, абсолютный/относительный `-f`, повторный discovery, backup configs, Docker `-d`/`-f` с writable directory bind, смену runtime/config/controller и несовпадение devices при одинаковом inode. Неоднозначность, отсутствие runtime (включая первоначальную установку до запуска Mihomo), unbound/wrapper процессы, повторные/неизвестные flags, default-path guessing, environment/in-memory/encrypted/stdin configs, symlink/hardlink файлы, overlapping/read-only/volume/single-file mounts отвергаются. Mihomo нужно подготовить и запустить до gateway installer. Имена executable, отличные от `mihomo`/`mihomo-*`, не поддержаны.

## Почему PR остаётся draft

Installer может создать `daemon.json` и перезапустить Docker до config-фазы. Этот легитимный переход способен сменить PID Docker Mihomo; последующий guard откажется **после более ранних изменений sysctl/DNS/Docker**. Исходный ambiguous/no-runtime preflight ничего не пишет, но поздняя смена runtime не откатывает предыдущие фазы. Нельзя молча выполнить rediscovery и присвоить другой runtime. Нужна явно смоделированная и проверенная ownership-граница перехода до интеграции в main.

Привязка к точному container ID также означает, что recreate требует повторной установки. Watchdog не должен молча переключаться на replacement с недоказанным config. Устаревший ID останавливает recovery до нового admission. Это консервативный кандидат, не live acceptance.

## Disposable acceptance перед интеграцией / release

На отдельно разрешённом disposable host с console recovery и зафиксированным baseline проверить запущенный systemd service с `-d`, `-f`, cwd-relative `-f`, backup-файлами и override/drop-in ExecStart. Выполнить reinstall/uninstall, сравнить исходные YAML/ownership. Ввести restart, PID reuse, argv/cwd/config edits между discovery, первой записью и rename. Отказ должен сохранять выбранный config и честно сообщать уже выполненные ранние изменения.

Для Docker проверить реальные directory mounts и device/inode mapping через `/proc/PID/root`, custom command, отсутствие host mihomo.service, первоначально отсутствующий/существующий daemon.json, Docker restart, read-only/single-file/volume mounts, wrappers, replacement и reboot. До merge разрешить daemon-restart переход и покрыть его orchestration fixtures. Доказать, что после restart используется именно выбранный config; затем проверить fail-secure и rollback. #20 остаётся открыт до всех acceptance criteria.

Семантика сверена с Mihomo v1.19.31: [main.go](https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.31/main.go), [constant/path.go](https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.31/constant/path.go). Зелёные fixtures не доказывают реальное поведение systemd/Docker/Mihomo.

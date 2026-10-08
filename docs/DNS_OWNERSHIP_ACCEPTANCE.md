# DNS ownership: reconciliation и оставшаяся приёмка (#21)

Изменения ниже относятся к main после v2.0.1. Stable/tag/release v2.0.1 этим PR
не изменяются. Это узкое усиление admission/rollback, не новый DNS design.

## Что уже было в v2.0.1

Installer сохраняет исходный resolv.conf как symlink/regular/missing и marker
immutable, фиксирует исходную активность/enabled-state resolved до изменения.
Docker daemon.json создаётся только при отсутствии; uninstaller использует
ownership/checksum и сохраняет admin-modified содержимое. Полный DNS ownership
нельзя считать отсутствующим из-за старой формулировки Issue #21.

PR #4 предшествует v2.0.0, конфликтует и существенно перекрыт текущим кодом.
Его не нужно переносить целиком; остаточные требования сверяются с main отдельно.

## Минимальная модель и реализованное усиление

| Ресурс/ситуация | Admission / действие |
|---|---|
| Новый host DNS change | Только исходно active resolved, доказанный enabled/disabled-state и поддержанный тип resolver. Для regular file immutable probe должен быть доступен. Partial metadata без recorded marker → refusal/manual review. |
| Recorded DNS + resolved снова active | Это новое внешнее состояние: reinstall отказывается его переписывать. При inactive resolved DNS branch ничего не присваивает и не переписывает. |
| Отключение resolved | Успешная команда и свежие inactive/disabled observations обязательны до замены resolver. |
| Новый Docker daemon.json | Только truly absent path (`! -e && ! -L`); существующие symlink/dir/file сохраняются. Исчезнувший ранее owned файл не присваивается заново. |
| Удаление owned daemon.json | Marker + checksum + regular non-symlink single-link file. Same-byte symlink/hardlink divergence сохраняется. |
| DNS rollback admission | Managed checksum/type/single-link/immutable и inactive/disabled resolved должны совпадать. Snapshot обязан иметь ровно одну форму: regular/symlink ИЛИ missing marker; неподдержанные/противоречивые формы → no DNS mutation. |
| Восстановление | Сначала snapshot staging, затем повторная проверка current content/type/service state, clear immutable и atomic rename (или доказанное original missing). Исходные attributes/service state проверяются свежим readback. |
| Ошибка копирования/атрибутов/service/readback | Не объявлять полный успех: сохранять snapshot/state и exit 2. Ошибка после успешного rename может оставить частично восстановленное состояние; оно требует ручного разбора. |

Обычные DNS адреса и выбор host/container resolver не изменены. Нормальная успешная
ветка выполняет прежние действия; дополнительные проверки ограничивают недоказанные
состояния. Это не атомарная транзакция между filesystem/systemd/Docker. Первичная
установка может уже остановить resolved, если последующая запись/chattr завершится
ошибкой. Не запускать install/uninstall одновременно с администраторскими изменениями;
guards/readback не являются блокировкой произвольных внешних root writers.

## Автоматизированная проверка

`bash tests/test-ownership-rollback.sh`: extracted production DNS block с двумя
перенаправленными constant paths; настоящий uninstaller на fixture paths; stateful
systemctl/chattr/lsattr mocks. Покрыты missing/invalid/contradictory snapshot,
regular/symlink/missing/immutable originals, same-byte Docker links, admin content/
service/attribute changes, edit during staging, failed copy/disable/restore и
success-without-state-change. До исправления v2.0.1 удаляет managed resolver при
неполном original snapshot; regression воспроизводит это на старом uninstaller.

Mocks доказывают только admission/control flow и смоделированный rollback. Они не
доказывают DNS reachability, реальные filesystem immutable capabilities, systemd
сбои и взаимодействие Docker/reboot. Issue #21 остаётся открытым.

## Disposable VPS acceptance procedure (не выполнена)

1. Выделить disposable Ubuntu/Debian VPS с консолью recovery, не production host.
   Снять OS/kernel/Docker/Mihomo versions, exact source commit/SHA256 и независимый
   baseline: resolver type/link target/bytes/mode/owner/immutable, resolved active/
   enabled-state, daemon.json type/bytes, host/container DNS probes, routes/sysctl.
2. Подготовить отдельные чистые cases: regular mutable/immutable resolver;
   symlink resolver (target отдельно hash-фиксируется); missing resolver;
   absent и pre-existing daemon.json. Partial/unknown ownership cases не лечить
   автоматически — проверить refusal и сохранность внешнего состояния.
3. На disposable host проверить initial install, host DNS и DNS из настоящего AWG
   container, gateway/DDP/fail-secure и Docker restart effects. Reinstall не должен
   изменять first snapshot; reboot должен сохранить рабочий DNS и gateway.
4. В отдельных cases изменить resolver content/type/attribute, re-enable/start
   resolved, заменить daemon.json symlink/hardlink. Повторный install/uninstall
   должен сохранять admin state и сообщать отказ/exit 2, когда ownership не доказан.
5. Проверить successful uninstall: exact before/after resolver semantics/attributes,
   resolved state, daemon.json ownership и target-file preservation. Проверить
   failure recovery через консоль: incomplete state сохраняется, сообщения не
   заявляют полный rollback. Не моделировать outage на единственном рабочем VPS.
6. Сохранить evidence каждого case и явно отделить runtime DNS transport от mocks.

Текущий live-kit загружает только pinned public stable v2.0.1, поэтому его успешный
запуск не был бы приёмкой нового main. Нельзя подменять скачанный installer внутри
кита. Для main-кандидата нужен отдельный согласованный guarded acceptance run с
точно зафиксированным source SHA; продвижение/repin stable требует отдельного задания.

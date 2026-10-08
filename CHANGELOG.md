# Changelog

## [2.0.1] - 2026-10-08

### Исправлено

- AMG-01: повторная установка сохраняет принадлежащие installer persistent sysctl directives для BBR, fq и forwarding. Каждый directive требует собственного ownership marker; исходный snapshot сохраняется, внешние настройки не присваиваются проектом.
- Сохранена совместимость с ownership-aware uninstall/rollback и текущим production stable, включая существующее поведение `profile.store-fake-ip`.
- Контрольная сумма installer в live-acceptance kit привязана к файлу версии 2.0.1; fixture regression проверяет обе product pins до будущего запуска на VPS.

### Границы проверки

- Проверены автоматизированные sysctl reinstall/simulated reboot, ownership rollback, config patch, fail-secure lifecycle, routing/watchdog и fixtures live-acceptance kit.
- Реальная disposable VPS acceptance версии 2.0.1 ещё не проводилась. Выпуск до неё разрешён владельцем; CI и fixtures не заменяют проверку kernel networking, Docker/WARP и reboot на VPS.
- Публикация релиза не обновляет уже установленные системы автоматически.

## [2.0.0] - 2026-09-29

Предыдущий опубликованный release: [v2.0.0](https://github.com/saymer-alt/amnezia-mihomo-gateway/releases/tag/v2.0.0). Исторический tag сохраняется; последующие production stable commits не переписываются.

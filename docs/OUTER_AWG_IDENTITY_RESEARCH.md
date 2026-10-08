# Идентификация outer-AWG: исследование и границы доказательства (#22)

**Статус: риск открыт; production routing не изменён.**

В `install.sh` генерируемые routing/watchdog правила распознают outer transport по исходной Docker-подсети, UDP и source port WG_PORT. MARK `0x88` получает исключение priority 40 через main и разрешение в AMG_FAILSECURE. Эти признаки доступны другому контейнеру в той же подсети. Поэтому совпадение source port не доказывает принадлежность пакета AWG. Это анализ достижимого правила; настоящий attacker packet proof в этой работе не получен.

## Сравнение вариантов

| Признак | Что сужает | Чего не доказывает / эксплуатационный gate |
|---|---|---|
| Source IP AWG-контейнера + UDP port | Обычный соседний контейнер с другим адресом | NET_RAW/подмена адреса и процессы внутри AWG-контейнера; адрес меняется при recreate |
| Реальный ingress veth / `physdev-in` + текущие признаки | При доказанном bridge ingress привязывает к конкретному порту контейнера; сосед не проходит только за счёт source spoofing | Нужны br_netfilter, совместимый backend и проверка routed path. Veth меняется при recreate; нельзя привязываться по первым похожим именам |
| Conntrack mark | Сохраняет уже принятое решение между пакетами | Не устанавливает исходную identity; ошибочное первое решение сохраняется. Нельзя смешивать inner client flows с outer transport |
| `owner` / PID / socket | Подходит для локально создаваемых host пакетов | Forwarded container traffic не становится host socket AWG; это не универсальная замена для Docker bridge |
| Отдельный transport namespace / bridge | Структурно отделяет доверенный transport от соседей | Меняет архитектуру и требует реального Docker/AWG, multiple peers, reconnect, reboot и замеров |
| Список peer endpoints | Может дополнительно ограничить назначения | Не считать постоянным: roaming/dynamic peers, DNS и несколько endpoints; отсутствие обновления ломает handshake, чрезмерно широкий список не доказывает отправителя |

Рекомендуемый следующий эксперимент — доказать реальный ingress AWG veth, затем сочетать его с текущими транспортными признаками и lifecycle admission. Это исследовательский кандидат, не утверждённая production замена. Нельзя заменять установленный iptables baseline на nftables только ради новизны.

Основания: [документация Linux bridge](https://cdn.kernel.org/doc/html/latest/networking/bridge.html) описывает связь br_netfilter и physdev; [iptables-extensions](https://man7.org/linux/man-pages/man8/iptables-extensions.8.html) определяет physdev-in, owner и CONNMARK. Выводы о применимости к AMG выше — инженерная оценка, требующая packet proof.

## Изолированный локальный стенд

`tests/lab-outer-awg-identity.py --run-isolated` — opt-in эксперимент с UDP-суррогатом, **не настоящий AWG**. Запускатель проверяет зависимости и создаёт отдельные user, network и mount namespaces. До изменения сети дочерний процесс проверяет отличие всех трёх namespace identities от родителя. Mount propagation отключается только в частном mount namespace; `/run` получает tmpfs, чтобы xtables lock не создавался у вызывающего процесса. Ip forwarding меняется только в изолированном network namespace. Модули через modprobe не загружаются; зависимости автоматически не устанавливаются.

Внутри создаются bridge, veth и три дочерних network namespaces: AWG-суррогат, attacker и WAN-приёмник. При доступном backend стенд требует: старый classifier пропускает оба контейнера с одинаковым source port; кандидат physdev пропускает AWG-суррогат и блокирует attacker, включая spoofed source IP; второй endpoint и повторный reconcile работают; отсутствие classifier блокирует передачу. Ошибочная доставка означает FAIL. Недоступный инструмент/kernel/backend означает SKIP (77), а не PASS. Процессы стенда завершаются в finally; namespace rules/devices исчезают вместе с namespace. Launcher не вызывает host iptables, ip или sysctl.

Обычный CI запускает только `tests/test-outer-awg-lab-guards.py`: отказ без флага, при отсутствии зависимостей и при общих namespaces. Он не запускает сетевой эксперимент. Возможен `AMG_LAB_IPTABLES` для явно выбранного локального бинарника; он выполняется лишь после namespace admission.

### Результат текущего окружения

В WSL создание namespace доступно. Для эксперимента пакеты iptables и библиотек были только скачаны и распакованы в рабочую директорию; системная установка не выполнялась. Legacy и nf_tables попытки завершились SKIP: изолированный backend не принял `--set-mark`. Причина доступности extension/kernel не установлена; это не доказательство дефекта AMG. Положительные/отрицательные classifier пробы не завершены, реальный AWG не запускался. Повторить на подходящем disposable Linux стенде; не загружать host modules ради обхода ограничения текущего окружения.

## Обязательная приёмка перед production изменением

1. Настоящий AmneziaWG transport: handshake, RX/TX, WAN packet capture и route/mark evidence; действительные endpoints из runtime, не заранее выбранный один адрес.
2. Соседний attacker с тем же UDP source port: обычный адрес, source spoofing и заявленная модель capabilities. Его пакеты не получают WAN bypass. Отдельно определить доверие к процессам внутри самого AWG-контейнера.
3. Несколько peers, roaming/dynamic endpoints, reconnect, recreate контейнера/bridge/veth, Docker restart, reboot и watchdog/reconcile. Новая identity допускается явно; потеря identity блокирует bypass.
4. Потеря TUN, source rule, route, mark и classifier: подтверждённый fail-secure без прямого fallback; никаких окон при замене правил.
5. Сравнение скорости/MTU/MSS и сохранение SSH/host routing. Только после review packet evidence обсуждать production PR и отдельную stable promotion.

#22 остаётся открытым. Из этого PR в будущий patch release допустимы только исследование/opt-in инструмент, а не production изменение bypass identity.

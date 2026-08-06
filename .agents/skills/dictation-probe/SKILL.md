---
name: dictation-probe
description: Проверить диктовку живьём без выдачи разрешений — слышен ли хоткей, поднимается ли воркер, что он распознаёт и сколько памяти освобождает. Использовать после правок в диктовке или когда она перестала отзываться.
---

# Проверка диктовки

Всё проверяется на настоящих данных, ничего не изменяя. Разрешения не выдавать —
их даёт только владелец.

## Слышит ли приложение клавишу

Хоткей глобальный, поэтому его можно проверить, не нажимая ничего руками: послать
системе событие правого Option и посмотреть, поднялся ли воркер.

```swift
// rightopt.swift — запускать `swift rightopt.swift`
import CoreGraphics
import Foundation

func post(down: Bool) {
    guard let e = CGEvent(source: nil) else { return }
    e.type = .flagsChanged
    e.setIntegerValueField(.keyboardEventKeycode, value: 61)   // правый Option
    e.flags = down ? CGEventFlags(rawValue: 0x80040) : CGEventFlags(rawValue: 0)
    e.post(tap: .cghidEventTap)
}

post(down: true)
Thread.sleep(forTimeInterval: 3)
post(down: false)
```

```bash
pgrep -fl cyclop_worker   # поднялся — значит клавиша слышна и запись пошла
```

Пусто — разрешение на Универсальный доступ не действует. Частая причина: приложение
пересобрали ad-hoc, и macOS считает его новым. Лечится
`tccutil reset Accessibility com.cyclop.app`, перезапуском и повторной выдачей.

## Что распознаёт воркер

```bash
PY=.runtime/bin/python3.11   # или /Applications/Cyclop.app/Contents/Resources/runtime/bin/python3.11
WAV=$(ls ~/Library/Application\ Support/Cyclop/Recordings/*.wav | head -1)
printf '{"cmd":"transcribe","path":"%s"}\n{"cmd":"unload"}\n' "$WAV" | "$PY" Resources/worker/cyclop_worker.py
```

Нет `.runtime` — собрать `./Scripts/runtime.sh`, это занимает минуту и
полгигабайта. Записи пользователя не трогать: читать можно, писать в ту папку
нельзя, для опытов копировать во временную.

Первая строка ответа — распознанный текст и `freed_mb`, вторая — отчёт о выгрузке.
Посторонний вывод на stdout недопустим: Swift читает его как ответы. Диагностика
идёт в stderr.

Сверить качество можно с историей: в
`~/Library/Application Support/Cyclop/dictation-history.jsonl` лежат расшифровки
тех же записей, сделанные прежним приложением. Найти запись с тем же именем в поле
`audio` и сравнить тексты — они должны совпадать посимвольно.

## Сколько памяти

```bash
footprint -p $(pgrep -f cyclop_worker | head -1) | tail -3
```

Ориентиры (замерено): 8 МБ сразу после запуска, около 1780 МБ во время
распознавания, 165–171 МБ после выгрузки. Больше 200 МБ в покое через десять минут
— выгрузка по простою не сработала.

## Логи

```bash
log stream --predicate 'process == "Cyclop"'
```

Туда же попадает stderr воркера — ошибки установки рантайма видно там и только там.

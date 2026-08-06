# Уборка хвостов после диктовки

Ветка `dictation`. Девять пунктов, сделаны все девять.

## 1. Диктовки слипались друг с другом

`Resources/worker/cyclop_worker.py`, `Engine.transcribe()`: убрал `.strip()` после
`clean_text(raw, self._cleaner_config)` — он срезал хвостовой пробел, который
`clean_text` намеренно добавляет при `trailing_space=True`.

Проверил ветку пустого текста в `DictationController.handle(_:)`
(`guard !text.isEmpty else { ... }`): она не ломается. `clean_text()` возвращает
`""` для пустого/пробельного входа *до* того, как добавляет хвостовой пробел
(`if not text: return ""` идёт раньше `if cfg.trailing_space...`), так что
результат либо честно пустой, либо непустой плюс, может быть, один пробел в
конце — строки из одних пробелов на выходе не бывает. Убедился явным вызовом
`clean_text('', ...)`, `clean_text('   ', ...)`, `clean_text('\n\n', ...)` —
всё даёт `''`.

Фактическая проверка живым воркером (`~/Library/Application Support/WhisperDictation/runtime/.venv/bin/python`)
на настоящей записи из `~/Library/Application Support/WhisperDictation/recordings/`:
до фикса ответ оканчивался на `...поражений.` (без пробела), после фикса —
на `...поражений. ` (с пробелом, `text.endswith(' ') == True`).

## 2. Терялось нажатие после повторной выдачи микрофона

`Sources/Cyclop/Dictation/HotkeyMonitor.swift`, `stop()`: добавил сброс
`gesture = HoldGesture(minimumHold: 0.25)`, как и в ветке
`tapDisabledByTimeout`/`tapDisabledByUserInput`. Теперь к моменту, когда
`start()` перевзводит слежение, жест гарантированно чист, независимо от того,
где именно между `stop()` и `start()` был потерян релиз.

## 3. Кнопка «+» в заготовках перехватывала клавиатуру во время диктовки

Провёл присваивание через тот же гейт, что и `select(_:)`/`panel.onPress`:
- `NotchViewModel`: новый метод `claimKeyboardIfAvailable()` — `if tabHasField { claimKeyboard() }`.
- `SnippetsPane`: вместо `@Binding var wantsKeyboard` для записи — новый параметр
  `let claimKeyboard: () -> Void`; `beginAdding()` теперь зовёт его вместо
  `wantsKeyboard = true`.
- `NotchContentView`: передаёт `vm.claimKeyboardIfAvailable` в `SnippetsPane`.

Обычное добавление (диктовка не идёт): `tabHasField` для вкладки snippets вне
диктовки всегда `true`, так что `claimKeyboardIfAvailable()` ведёт себя как
раньше — поле появляется и сразу получает фокус. Во время диктовки
`tabHasField` возвращает `false` (`dictation.isBusy`), клавиатура не
захватывается, редактор всё ещё открывается визуально, но `panel.acceptsKeyboard`
не взводится — синтетическое ⌘V больше не попадёт в черновик.

## 4. История могла врать про модель

- `Resources/worker/cyclop_worker.py`: `Engine.transcribe()` теперь кладёт в
  ответ `"model": self._config.whisper.model` (или `None`, если движок собран
  вокруг тестового транскрайбера напрямую, минуя `_ensure()`).
- `Sources/CyclopDictation/WorkerProtocol.swift`: у `WorkerResponse` заменил
  `language` на `model: String?` (см. пункт 9).
- `Sources/Cyclop/Dictation/TranscriberBridge.swift`: `onResult` теперь несёт
  `Result<Transcription, Error>` (`struct Transcription { text, model }`)
  вместо голого `Result<String, Error>`.
- `Sources/Cyclop/Dictation/DictationController.swift`: `handle(_:)` пишет в
  историю `transcription.model ?? Self.fallbackModel` — старая константа
  переименована в `fallbackModel` и задокументирована как запасной вариант,
  а не источник истины.

Покрыто тестами: `Tests/CyclopDictationTests/WorkerProtocolTests.swift`
(`testDecodesTranscription`, `testDecodesTranscriptionWithoutModel`) и
`Resources/worker/test_cyclop_worker.py`
(`test_transcribe_reports_the_actual_model`,
`test_transcribe_reports_none_model_without_real_config`).

## 5. Тестовый файл уезжал в бандл

`Scripts/bundle.sh`: вместо `cp .../worker/*.py` — `cp .../worker/cyclop_worker.py`.
Проверил `./Scripts/bundle.sh release`: в `build/Cyclop.app/Contents/Resources/worker/`
лежит только `cyclop_worker.py`.

## 6. Приложение воссоздавало папку старого приложения

`Resources/worker/cyclop_worker.py`, `Engine._ensure()`: перед вызовом
`load_config()` подменяю `AppConfig.ensure_dirs = lambda self: None` —
только в памяти этого процесса, файл `whisper_dictation/config.py`
(принадлежащий старому приложению) не трогал. `load_config()` по-прежнему
читает модель и настройки очистки из `preferences.json` — это нужно для
пункта 4, — просто больше не создаёт
`~/Library/Application Support/WhisperDictation/recordings`.

Проверил живьём: временно убрал `recordings/` из
`~/Library/Application Support/WhisperDictation/`, прогнал воркер (`ping` +
`transcribe` с несуществующим файлом — чтобы дойти до `_ensure()`, не гоняя
саму модель), убедился, что папка не появилась обратно, и вернул исходную
`recordings/` (155 файлов) на место.

## 7. Дозапись не проверяла конец файла

`Sources/CyclopDictation/DictationHistoryStore.swift`, `persist(...)`, ветка
обычного append: открываю файл `O_RDWR` (было `O_WRONLY` — нужно читать,
чтобы проверить последний байт), через `lseek`/`read` смотрю, оканчивается ли
файл на `\n`; если нет — приписываю `\n` перед новой строкой.

Тест: `Tests/CyclopDictationTests/DictationHistoryStoreTests.swift` →
`testAppendAfterMissingTrailingNewlineKeepsBothRecords` — пишет файл без
финального перевода строки, делает `append`, перечитывает и проверяет, что
обе записи на месте.

## 8. Мёртвый код в мосте — `TranscriberBridge.start()`/`unload()`

Убрал оба метода, не стал начинать их использовать. Обоснование:

- **`start()`** никогда не вызывается: `DictationController.start()` не зовёт
  `bridge.start()`, воркер поднимается лениво из `transcribe(path:)` — задача
  сама называет это правильным поведением. Побочные эффекты внутри `start()`
  (`failures = 0`, `buffer.removeAll()`, `stopped = false`, `generation += 1`)
  проверил на потерю:
  - `buffer.removeAll()` дублирует то, что и так делает `launch()` первой
    же строкой — при удалении `start()` это не теряется, оно уже есть в
    `launch()`.
  - `failures = 0` уже сбрасывается на каждый успешно распарсенный ответ
    воркера внутри `handle(line:)` — счётчик самовосстанавливается без
    участия `start()`.
  - `stopped = false` и `generation += 1` были нужны только для сценария
    «`stop()`, потом `start()` на том же экземпляре» — такого сценария в
    коде нет и не было: `NotchController.rebuild()`/`teardown()` после
    `stop()` всегда пересоздают `NotchViewModel` → `DictationController` →
    `TranscriberBridge` целиком, а не переиспользуют старый. `start()` был
    уже фактически недостижим и до этой уборки (я проверил это по истории
    коммитов и по `grep` — вызовов не было).
- **`unload()`** тоже нигде не вызывается, и вызывать его не нужно: сторож
  простоя внутри воркера (`_idle_watch`/`maybe_unload_idle`, `IDLE_SECONDS`)
  сам выгружает модель — это то самое поведение, которое задача просит
  считать проверенным (629 с ожидания → 171 МБ). Явный вызов с Swift-стороны
  только гонялся бы за решением, которое воркер и так принимает сам.

Задокументировал оба решения в doc-комментарии класса. Оставил в покое
`WorkerRequest.unload` (протокольный кейс) и python-обработчик команды
`"unload"` в `cyclop_worker.py` — это не то, что просил пункт 8, у них
своя польза (описывают протокол воркера, покрыты собственными тестами:
`WorkerProtocolTests.testUnloadRequest`,
`test_cyclop_worker.py::test_unload_reports_and_forgets_the_model`), и
трогать их значило бы расширять пункт 8 за его границы.

Побочное наблюдение, не в рамках этого пункта: поле `generation` в
`TranscriberBridge` теперь (как и до уборки, раз `start()` не вызывался)
навсегда остаётся `0` — весь механизм защиты от гонки «`stop()` +
`start()`» через `generation` фактически не работает ни до, ни после моих
правок. Не трогал: это отдельный, самостоятельный вопрос, не входящий в
список.

## 9. `WorkerResponse.language` — поле, которое никто не заполнял

Убрал поле. Обоснование: чтобы оно значило что-то настоящее, пришлось бы
доставать `language` из `mlx_whisper.transcribe()` — но
`WhisperTranscriber.transcribe()` (в
`~/Library/Application Support/WhisperDictation/runtime/.venv/.../whisper_dictation/transcriber.py`)
выбрасывает всё, кроме `text`, и это файл старого приложения — общий venv,
трогать нельзя (та же логика, что и в пункте 6: не редактировать чужой
пакет). Дублировать вызов `mlx_whisper.transcribe()` в воркере в обход
`WhisperTranscriber` — значит завести собственную копию decoding-параметров
рядом с `whisper_dictation.config`, что прямо противоречит заявленной цели
воркера («модель, промпт и параметры распознавания приходят из
`whisper_dictation.config` нетронутыми»). Поле нигде не читалось на Swift-
стороне (только парсилось и тестировалось), так что удаление ничего не
ломает. Тест `testDecodesTranscription` обновлён под `model` вместо
`language`.

## Проверки

- `swift build` — чисто, без предупреждений.
- `swift test` — 41 зелёный (было 39 + мои 2 новых: append-без-newline и
  decode-без-model).
- `python3 Resources/worker/test_cyclop_worker.py` — 10 зелёных (было 8 +
  мои 2 новых: model из реального конфига / model отсутствует без него).
- `./Scripts/bundle.sh release` — собирается, `worker/` внутри бандла
  содержит только `cyclop_worker.py`.
- Не трогал `/Applications/Cyclop.app`, `/Applications/WhisperDictation.app`,
  работающие процессы, `~/Library/Application Support/Cyclop/dictation-history.jsonl`.
  Разрешений не выдавал.

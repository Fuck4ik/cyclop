---
name: localization-check
description: Сверить строки локализации с кодом — что каждый литерал есть в обоих языках и совпадает дословно. Использовать после добавления любого видимого текста.
---

# Проверка локализации

Ключ локализации — сам английский текст. Расхождение в один символ ломает перевод
молча: строка просто останется английской, ошибки не будет. Проверка ловит это
раньше, чем человек увидит непереведённое слово в панели.

## Что сверять

```bash
cd ~/www/cyclop
python3 - <<'PY'
import re, pathlib

def keys(path):
    text = pathlib.Path(path).read_text()
    return {m.group(1) for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M)}

ru = keys("Resources/ru.lproj/Localizable.strings")
en = keys("Resources/en.lproj/Localizable.strings")

# Литералы из кода: localized("…"), Text("…"), Button("…")
used = set()
for swift in pathlib.Path("Sources").rglob("*.swift"):
    src = swift.read_text()
    for pattern in (r'localized\(\s*"((?:[^"\\]|\\.)*)"',
                    r'Text\(\s*"((?:[^"\\]|\\.)*)"',
                    r'Button\(\s*"((?:[^"\\]|\\.)*)"'):
        used |= {m.group(1) for m in re.finditer(pattern, src)}

print(f"ключей: ru {len(ru)}, en {len(en)}, литералов в коде {len(used)}")
for name, missing in (("нет в ru", used - ru), ("нет в en", used - en),
                      ("ru без en", ru - en), ("en без ru", en - ru)):
    if missing:
        print(f"\n{name}:")
        for key in sorted(missing):
            print(f"  {key!r}")
PY
plutil -lint Resources/*.lproj/Localizable.strings
```

## Что считать нормой

Наборы ключей в обоих файлах совпадают, а каждый литерал из кода есть в обоих.
В английском файле значение равно ключу — это осознанно: строка без перевода
останется английской фразой, а не превратится в идентификатор.

Литералы, которые формируются из значений (`localized("in %d min", count)`),
попадают в проверку по своему шаблону — сверять надо шаблон целиком, вместе с
`%d` и `%@`.

Ложные срабатывания возможны на `Text` с переменной внутри — такие строки
локализуются не здесь, их можно пропускать.

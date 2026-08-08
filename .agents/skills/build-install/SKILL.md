---
name: build-install
description: Собрать Cyclop, подписать, заменить установленное приложение в /Applications и запустить. Использовать, когда нужно проверить правки вживую.
disable-model-invocation: true
---

# Собрать и установить

Заменяет работающее приложение пользователя — поэтому вызывается только человеком,
не по инициативе агента.

## Что делать

```bash
cd ~/www/cyclop
swift build 2>&1 | grep -E "error|warning" ; swift build 2>&1 | tail -1
swift test 2>&1 | grep -E "Executed .* tests" | tail -1
python3 Resources/worker/test_cyclop_worker.py 2>&1 | tail -1

pkill -f 'Cyclop.app/Contents/MacOS/Cyclop'
rm -rf build && ./Scripts/bundle.sh release 2>&1 | grep -E "signing|Apple Development|ad-hoc|done"
rm -rf /Applications/Cyclop.app && cp -R build/Cyclop.app /Applications/ && rm -rf build
open -a /Applications/Cyclop.app && sleep 3
ps -Ao pid,rss,comm | grep 'Cyclop.app' | grep -v grep
```

## На что смотреть

**Подпись.** В выводе сборки должно быть `Apple Development: …`. Если там `ad-hoc`,
сертификат не нашёлся — выданные разрешения слетят, и диктовка перестанет
отзываться на клавишу до повторной выдачи.

**Процесс.** После запуска в списке должен быть `Cyclop` (около 50 МБ) и `perl`
(хелпер Now Playing, около 17 МБ). Python-воркер не поднимается до первой
диктовки — это правильно, он ленивый.

**Предупреждения сборки.** Их не должно быть ни одного: проект собирается чисто,
и новое предупреждение — это регресс.

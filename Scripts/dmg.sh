#!/bin/bash
# Packs the built app into a disk image — the form a Mac app is handed over in.
# Собирает приложение, если его еще нет, и кладет рядом ярлык /Applications,
# чтобы установка была одним перетаскиванием.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Cyclop.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"
DMG="$ROOT/build/Cyclop-$VERSION.dmg"

# Всегда, а не только когда приложения нет. Иначе образ уносит то, что лежало в
# build с прошлого раза: номер на образе новый, приложение внутри старое, и
# заметить это можно лишь запустив его.
"$ROOT/Scripts/bundle.sh" release

echo "==> раскладка образа"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Cyclop.app"
ln -s /Applications "$STAGE/Applications"

echo "==> сборка $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "Cyclop $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$DMG"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "==> готово: $DMG ($SIZE)"

# Имя образа обещает версию, и обещание стоит проверить: расходятся они молча.
INSIDE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
if [ "$INSIDE" != "$VERSION" ]; then
    echo "!!! в образе лежит версия $INSIDE, а имя обещает $VERSION" >&2
    exit 1
fi
echo "==> версия внутри совпадает: $INSIDE"

# Нотаризация: Apple проверяет образ и выдаёт билет, который stapler
# прикрепляет прямо к файлу — после этого Gatekeeper пускает приложение на
# чужой машине без единого вопроса и не спрашивая интернет.
#
# Идёт только с Developer ID: подпись Apple Development нотаризацию не
# проходит, это сертификат для разработки. Учётные данные берутся из связки
# ключей, чтобы пароль не жил ни в скрипте, ни в истории команд:
#
#   xcrun notarytool store-credentials cyclop \
#       --apple-id <ваш Apple ID> --team-id <Team ID> --password <app-specific>
PROFILE="${CYCLOP_NOTARY_PROFILE:-cyclop}"
# --verbose=2, не -dv: на меньшей подробности codesign не печатает Authority
# вовсе, и проверка молча решает, что Developer ID нет — сборка уходит
# ненотаризованной, выглядя при этом совершенно успешной.
SIGNED_BY="$(codesign -d --verbose=2 "$APP" 2>&1 | awk -F'=' '/^Authority/ {print $2; exit}')"

case "$SIGNED_BY" in
"Developer ID Application"*)
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "==> нотаризация (полгигабайта, обычно 5–20 минут)"
        xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
        xcrun stapler staple "$DMG"
        echo "==> билет прикреплён"
        spctl -a -vv -t install "$DMG" 2>&1 | sed 's/^/    /'
    else
        echo "!!! есть Developer ID, но нет учётных данных для нотаризации." >&2
        echo "    xcrun notarytool store-credentials $PROFILE --apple-id … --team-id … --password …" >&2
    fi
    ;;
*)
    cat <<'NOTE'

    Внимание: сборка подписана без Developer ID и не нотаризована.
    На твоей машине она запускается, на любой другой Gatekeeper ее не пустит.
    Тому, кому отдаешь образ, придется один раз зайти в Системные настройки →
    Конфиденциальность и безопасность → "Все равно открыть". В macOS 15
    открытие через Control-клик для такого случая больше не работает.

    Чтобы этого не требовалось: сертификат Developer ID Application в связке
    ключей (Xcode → Settings → Accounts → Manage Certificates) и учётные
    данные нотаризации:

        xcrun notarytool store-credentials cyclop \
            --apple-id <Apple ID> --team-id <Team ID> --password <app-specific>

    Дальше этот скрипт всё сделает сам.
NOTE
    ;;
esac

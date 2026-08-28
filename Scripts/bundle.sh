#!/bin/bash
# Builds Cyclop.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and ad-hoc signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Cyclop.app"
EXT="$APP/Contents/PlugIns/CyclopFinderMenu.appex"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Cyclop" "$APP/Contents/MacOS/Cyclop"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Cyclop</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>ru</string></array>
    <key>CFBundleDisplayName</key><string>Cyclop</string>
    <key>CFBundleIdentifier</key><string>com.cyclop.app</string>
    <key>CFBundleExecutable</key><string>Cyclop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Cyclop читает название текущего трека и управляет воспроизведением в Apple Music и Spotify.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Cyclop записывает голос локально, чтобы превратить его в текст.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Cyclop показывает ближайшие встречи и кнопку подключения к ним.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Cyclop показывает ближайшие встречи и кнопку подключения к ним.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Cyclop записывает экран и звук встречи, чтобы расшифровать её.</string>
    <!-- Cloud dictation talks to a CLIProxyAPI instance, and the usual one
         runs on this same Mac over plain http. ATS blocks that by default and
         does it silently — the request simply fails. Only local networking is
         opened: a proxy on the far side of the internet still has to be https,
         which is what NSAllowsArbitraryLoads would have thrown away. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Таблицы строк кладутся прямо в бандл, а не через ресурсы SwiftPM: бандл здесь
# собирается вручную, и .lproj рядом с исполняемым файлом — то, где их ищет сама
# macOS. Язык она выбирает потом сама, по списку предпочитаемых у пользователя.
echo "==> локализации"
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
    echo "    $(basename "$lproj")"
done

# Расширение Finder — отдельный бандл внутри приложения. Пункт «Копировать
# полный путь» рисует именно он: это единственный способ попасть в контекстное
# меню Finder верхним пунктом, а не внутрь «Быстрых действий».
echo "==> расширение Finder"
mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
cp "$BIN_DIR/CyclopFinderMenu" "$EXT/Contents/MacOS/CyclopFinderMenu"

# CFBundleIdentifier расширения обязан начинаться с идентификатора приложения —
# иначе система его не примет. NSExtensionPrincipalClass ищется по строке, и это
# @objc-имя класса из FinderMenu.swift, а не имя типа в Swift.
cat > "$EXT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Cyclop</string>
    <key>CFBundleDisplayName</key><string>Cyclop</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>ru</string></array>
    <key>CFBundleIdentifier</key><string>com.cyclop.app.finder-menu</string>
    <key>CFBundleExecutable</key><string>CyclopFinderMenu</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
        <key>NSExtensionPrincipalClass</key><string>CyclopFinderMenu</string>
    </dict>
</dict>
</plist>
PLIST

# Те же таблицы строк, что у приложения. NSLocalizedString внутри расширения
# смотрит в его собственный бандл, так что без этой копии пункт меню всегда
# был бы английским.
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$EXT/Contents/Resources/"
done

echo "==> транскрайбер"
mkdir -p "$APP/Contents/Resources/worker"
# Only the worker itself — Resources/worker/*.py would also sweep up
# test_cyclop_worker.py, which has no business inside a shipped app bundle.
cp "$ROOT/Resources/worker/cyclop_worker.py" "$APP/Contents/Resources/worker/"
# The settings package the worker imports. It has to sit next to the worker:
# that is the only directory guaranteed to be on the interpreter's path.
rm -rf "$APP/Contents/Resources/worker/cyclop_dictation"
cp -R "$ROOT/Resources/worker/cyclop_dictation" "$APP/Contents/Resources/worker/"
rm -rf "$APP/Contents/Resources/worker/cyclop_dictation/__pycache__"

# The Python the worker runs on, if it has been built. Kept out of the default
# build because it is half a gigabyte and only changes when its package list
# does: Scripts/runtime.sh makes it, this copies whatever is there. A bundle
# without it still runs — dictation then asks for an interpreter instead.
RUNTIME="${CYCLOP_RUNTIME:-$ROOT/.runtime}"
if [ -d "$RUNTIME" ]; then
    echo "==> рантайм"
    rm -rf "$APP/Contents/Resources/runtime"
    cp -R "$RUNTIME" "$APP/Contents/Resources/runtime"
    # Bytecode has to be compiled here, before signing, and never at runtime:
    # Python caches it next to the source, and a .pyc appearing inside a
    # signed bundle invalidates the signature — `spctl` then rejects the app
    # on any Mac that did not build it. TranscriberBridge runs the worker with
    # -B so it cannot write these itself; this is where they legitimately
    # come from.
    "$APP/Contents/Resources/runtime/bin/python3.11" -m compileall -q \
        "$APP/Contents/Resources/worker" >/dev/null 2>&1 || true
    echo "    $(du -sh "$APP/Contents/Resources/runtime" | cut -f1)"
else
    echo "==> рантайм не собран (Scripts/runtime.sh) — приложение будет искать питон снаружи"
fi

# Now Playing helper. Built here rather than by SwiftPM because it is not linked
# into the app: it is loaded into /usr/bin/perl at runtime. See helper.m.
echo "==> building Now Playing helper"
clang -dynamiclib -fobjc-arc -O2 \
    -mmacosx-version-min=15.0 \
    -framework Foundation \
    -o "$APP/Contents/Resources/libcyclopmedia.dylib" \
    "$ROOT/Sources/CyclopMediaHelper/helper.m"

# A stable signing identity is what keeps granted permissions — Accessibility
# for the dictation hotkey, the microphone — across rebuilds. An ad-hoc
# signature is recomputed on every build, so macOS sees each build as a
# different app, asks for the permissions again, and leaves the old switch
# turned on while it does. Override with CYCLOP_SIGN_IDENTITY; falls back to
# ad-hoc where no identity exists, which is what CI and other machines get.
#
# Developer ID first, because that is the only kind of signature another Mac
# accepts: with Apple Development, Gatekeeper answers "rejected" no matter how
# correct the signature is.
echo "==> signing"
IDENTITY="${CYCLOP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Apple Development/ {print $2; exit}')}"

ENTITLEMENTS="$ROOT/Scripts/Cyclop.entitlements"
# The hardened runtime is what notarisation requires, and Cyclop.entitlements
# says why each hole in it is open. Only ever with a real certificate: an
# ad-hoc signature plus hardened runtime produces an app macOS will not launch
# at all, which is a worse local build than an unhardened one.
HARDENED=()
case "$IDENTITY" in
    "Developer ID Application"*) HARDENED=(--options runtime --timestamp --entitlements "$ENTITLEMENTS") ;;
esac

# Inside out: a bundle's signature seals what is already signed, so every
# nested binary has to be done first. `--deep` looks like it does this and is
# explicitly not supported by Apple for distribution — it cannot apply
# entitlements per binary and silently skips things it does not recognise.
sign_nested() {
    local count
    count=$(find "$APP/Contents/Resources" \( -name "*.so" -o -name "*.dylib" \) | wc -l | tr -d ' ')
    [ "$count" = "0" ] && return 0
    echo "    вложенных бинарников: $count"
    find "$APP/Contents/Resources" \( -name "*.so" -o -name "*.dylib" \) -print0 |
        xargs -0 -n 40 codesign --force ${HARDENED[@]:+"${HARDENED[@]}"} --sign "$1" 2>/dev/null || true
    # The interpreter is a Mach-O executable with no extension, so the find
    # above never sees it — and it is the one binary that must be signed.
    [ -f "$APP/Contents/Resources/runtime/bin/python3.11" ] &&
        codesign --force ${HARDENED[@]:+"${HARDENED[@]}"} --sign "$1" \
            "$APP/Contents/Resources/runtime/bin/python3.11" 2>/dev/null || true
}

# Расширение Finder — вложенный бандл со своими entitlements: оно в песочнице,
# приложение вокруг него — нет, и одной подписью на двоих это не описать.
# Поэтому у него отдельный вызов, и он раньше подписи приложения.
sign_extension() {
    [ -d "$EXT" ] || return 0
    local opts=(--force --sign "$1")
    case "$1" in
        "Developer ID Application"*) opts+=(--options runtime --timestamp) ;;
    esac
    # Entitlements ставятся при любой подписи, а не только при Developer ID:
    # ad-hoc-сборка тоже уважает песочницу, а расширение, запертое на одной
    # машине и свободное на другой, — это расширение, которое никто не проверял.
    opts+=(--entitlements "$ROOT/Scripts/CyclopFinderMenu.entitlements")
    codesign "${opts[@]}" "$EXT" 2>/dev/null
}

if [ -n "$IDENTITY" ] && sign_nested "$IDENTITY" && sign_extension "$IDENTITY" &&
    codesign --force ${HARDENED[@]:+"${HARDENED[@]}"} --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "    $IDENTITY"
    [ ${#HARDENED[@]} -gt 0 ] && echo "    hardened runtime + entitlements"
else
    [ -n "$IDENTITY" ] && echo "    (подпись сертификатом не удалась, откатываюсь на ad-hoc)"
    # Ad-hoc теперь тоже изнутри наружу, без --deep: --deep переподписал бы
    # расширение по дороге и снял бы с него entitlements — песочница пропала бы
    # в каждой сборке, сделанной без сертификата. И hardened runtime здесь не
    # к месту: ad-hoc с ним даёт приложение, которое macOS не запускает вовсе.
    HARDENED=()
    if sign_nested - && sign_extension - &&
        codesign --force --sign - "$APP" >/dev/null 2>&1; then
        echo "    ad-hoc — разрешения придётся выдавать заново после каждой пересборки"
    else
        echo "    (codesign failed — the app still runs, but TCC prompts may repeat)"
    fi
fi

echo "==> done: $APP"

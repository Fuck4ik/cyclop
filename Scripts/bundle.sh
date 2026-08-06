#!/bin/bash
# Builds Cyclop.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and ad-hoc signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Cyclop.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Cyclop"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cyclop"

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
echo "==> signing"
IDENTITY="${CYCLOP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}"

if [ -n "$IDENTITY" ] && codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "    $IDENTITY"
else
    [ -n "$IDENTITY" ] && echo "    (подпись сертификатом не удалась, откатываюсь на ad-hoc)"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 &&
        echo "    ad-hoc — разрешения придётся выдавать заново после каждой пересборки" ||
        echo "    (codesign failed — the app still runs, but TCC prompts may repeat)"
fi

echo "==> done: $APP"

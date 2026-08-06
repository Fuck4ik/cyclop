#!/bin/bash
# Builds the Python runtime the transcription worker runs on, as a directory
# that can be copied anywhere — the app bundle carries it, so dictation works
# on a Mac that has no Python, no venv and no ffmpeg.
#
# Not a virtualenv on purpose: `uv venv --relocatable` still records an
# absolute `home =` in pyvenv.cfg pointing at uv's own interpreter, which does
# not exist on anyone else's machine. A copy of the standalone distribution
# works out its own prefix from argv[0], so it runs from wherever it lands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Not under build/: that directory gets wiped before every release build, and
# half a gigabyte that takes a minute and a network to rebuild has no business
# being collateral damage of `rm -rf build`.
DEST="${1:-$ROOT/.runtime}"
PY_MINOR="3.11"

# mlx-whisper lists torch among its dependencies but never imports it —
# inference runs on MLX. Installing it with --no-deps and naming what it
# actually needs keeps 480 MB of unused CUDA-era tensors out of the bundle.
PACKAGES=(mlx numba numpy tqdm more-itertools tiktoken huggingface_hub scipy)

if ! command -v uv >/dev/null 2>&1; then
    echo "нужен uv: brew install uv" >&2
    exit 1
fi

echo "==> интерпретатор $PY_MINOR"
uv python install "$PY_MINOR" >/dev/null
# Resolved to the physical directory: uv keeps a version-less symlink next to
# the real one, and copying that would hand us a link to uv's own install —
# which then gets pip's packages instead of the bundle, and looks like it
# worked right up until the resulting "runtime" turns out to be 0 bytes.
SRC="$(cd "$(dirname "$(dirname "$(uv python find --managed-python "$PY_MINOR")")")" && pwd -P)"
echo "    $SRC"

echo "==> копирую в $DEST"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$SRC" "$DEST"
# uv marks its own interpreters as externally managed (PEP 668). This copy is
# ours to fill, and pip refuses to touch it while the marker is there.
rm -f "$DEST/lib/python$PY_MINOR/EXTERNALLY-MANAGED"

PYTHON="$DEST/bin/python$PY_MINOR"
PIP_FLAGS=(--quiet --no-input --no-warn-script-location --no-warn-conflicts)
echo "==> пакеты"
"$PYTHON" -m pip install "${PIP_FLAGS[@]}" --no-deps mlx-whisper
"$PYTHON" -m pip install "${PIP_FLAGS[@]}" "${PACKAGES[@]}"

echo "==> прополка"
# Test suites and C headers are most of what is left to save: nothing in the
# worker's path imports them. pip and setuptools go too — the runtime is built
# here, once, and never installs anything on the user's machine.
rm -rf "$DEST/include" "$DEST/lib/python$PY_MINOR/test"
rm -rf "$DEST/lib/python$PY_MINOR/site-packages/pip" \
       "$DEST/lib/python$PY_MINOR/site-packages/setuptools" \
       "$DEST/lib/python$PY_MINOR/site-packages/pkg_resources"
find "$DEST/lib/python$PY_MINOR/site-packages" -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> проверка"
# sys.prefix has to land inside DEST: that is what says the interpreter works
# out its own location rather than pointing back at where it was built.
"$PYTHON" - "$DEST" <<'PY' || { echo "рантайм непригоден" >&2; exit 1; }
import sys
import mlx_whisper, mlx.core, numpy, scipy.signal, numba  # noqa: F401
assert sys.prefix == sys.argv[1], f"prefix {sys.prefix} вне рантайма {sys.argv[1]}"
PY
echo "    $(du -sh "$DEST" | cut -f1), python $("$PYTHON" -V | cut -d' ' -f2)"
echo "==> готово: $DEST"

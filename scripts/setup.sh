#!/bin/bash
# One-time setup: builds the vendored speech engine, then the app.
# Safe to re-run; skips work that is already done.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f vendor/whisper.cpp/CMakeLists.txt ]; then
    echo "==> Fetching the speech engine"
    git submodule update --init --recursive
fi

if [ ! -f vendor/whisper.cpp/build/src/libwhisper.a ]; then
    echo "==> Building whisper.cpp + Parakeet with Metal (a few minutes, once)"
    cd vendor/whisper.cpp
    cmake -B build -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON \
          -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_EXAMPLES=OFF \
          -DWHISPER_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j "$(sysctl -n hw.ncpu)"
    cd ../..
else
    echo "==> Speech engine already built"
fi

echo "==> Building Murmur.app"
scripts/build-app.sh

cat <<'DONE'

Done. Open the app with:

    open build/Murmur.app

On first launch Murmur asks for Accessibility (so it can type for you) and
Microphone. Then open Settings and download a speech model — Parakeet v3 is
the recommended one.
DONE

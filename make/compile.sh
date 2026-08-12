#!/bin/sh
# Compile guest inject dylibs and the GPU probe into out/.
set -eu

MAKE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname "$MAKE_DIR")
OUT_DIR=${1:-"$ROOT_DIR/out"}
GUEST_DIR="$ROOT_DIR/guest"
PROBE_SRC="$ROOT_DIR/bin/anka-gpu-probe.m"

mkdir -p "$OUT_DIR"

GUEST_SOURCES="
$GUEST_DIR/config.m
$GUEST_DIR/hooks.m
$GUEST_DIR/anka_gpu_family_boost.m
"

compile_dylib() {
  architecture=$1
  output=$2

  # shellcheck disable=SC2086
  xcrun clang \
    -arch "$architecture" \
    -O3 \
    -Wall \
    -Wextra \
    -Werror \
    -fobjc-arc \
    -fblocks \
    -fvisibility=hidden \
    -I"$GUEST_DIR" \
    -dynamiclib \
    -install_name @rpath/libAnkaGpuFamilyBoost.dylib \
    -mmacosx-version-min=13.0 \
    -framework Foundation \
    -framework Metal \
    $GUEST_SOURCES \
    -o "$output"

  codesign --force --sign - "$output"
}

compile_dylib arm64 "$OUT_DIR/libAnkaGpuFamilyBoost-arm64.dylib"
compile_dylib arm64e "$OUT_DIR/libAnkaGpuFamilyBoost-arm64e.dylib"

xcrun clang \
  -arch arm64 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -fobjc-arc \
  -framework Foundation \
  -framework Metal \
  "$PROBE_SRC" \
  -o "$OUT_DIR/anka-gpu-probe"

codesign --force --sign - "$OUT_DIR/anka-gpu-probe"

(
  cd "$OUT_DIR"
  shasum -a 256 \
    libAnkaGpuFamilyBoost-arm64.dylib \
    libAnkaGpuFamilyBoost-arm64e.dylib \
    anka-gpu-probe \
    > CHECKSUMS.sha256
)

printf 'Artifacts written under %s\n' "$OUT_DIR"

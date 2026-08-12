#!/bin/sh
# Confirm out/ artifacts exist and match CHECKSUMS.sha256.
set -eu

MAKE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname "$MAKE_DIR")
OUT_DIR=${1:-"$ROOT_DIR/out"}

if [ ! -f "$OUT_DIR/CHECKSUMS.sha256" ]; then
  "$MAKE_DIR/compile.sh" "$OUT_DIR"
fi

(
  cd "$OUT_DIR"
  shasum -a 256 -c CHECKSUMS.sha256
)

for artifact in \
  libAnkaGpuFamilyBoost-arm64.dylib \
  libAnkaGpuFamilyBoost-arm64e.dylib \
  anka-gpu-probe
do
  path="$OUT_DIR/$artifact"
  if [ ! -e "$path" ]; then
    printf 'missing artifact: %s\n' "$path" >&2
    exit 1
  fi
  file "$path"
done

printf 'artifact check passed\n'

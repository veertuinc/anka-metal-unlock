#!/bin/sh
# Copy probe + dylib into an Anka VM and print stock vs boosted JSON.
#
# Usage:
#   host/compare-vm-probe.sh <vm-name-or-uuid> [guest-dir]
set -eu

HOST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname "$HOST_DIR")
OUT_DIR="$ROOT_DIR/out"

VM_ID=${1:-}
GUEST_DIR=${2:-/Users/anka/anka-metal-unlock}
APPLE_FAMILY_MAX=${VEERTU_ANKA_GPU_APPLE_FAMILY_MAX:-1009}
DYLIB=libAnkaGpuFamilyBoost-arm64.dylib
PROBE=anka-gpu-probe

if [ -z "$VM_ID" ]; then
  printf 'usage: %s <vm-name-or-uuid> [guest-dir]\n' "$0" >&2
  exit 2
fi

if [ ! -x "$OUT_DIR/$PROBE" ] || [ ! -f "$OUT_DIR/$DYLIB" ]; then
  "$ROOT_DIR/make/compile.sh" "$OUT_DIR"
fi

anka start "$VM_ID" >/dev/null
anka run "$VM_ID" mkdir -p "$GUEST_DIR"
anka cp "$OUT_DIR/$DYLIB" "${VM_ID}:${GUEST_DIR}/"
anka cp "$OUT_DIR/$PROBE" "${VM_ID}:${GUEST_DIR}/"
anka run "$VM_ID" chmod +x \
  "${GUEST_DIR}/${PROBE}" \
  "${GUEST_DIR}/${DYLIB}"

printf '===== STOCK =====\n'
anka run "$VM_ID" "${GUEST_DIR}/${PROBE}" "$APPLE_FAMILY_MAX"

printf '===== BOOSTED =====\n'
anka run \
  -e "DYLD_INSERT_LIBRARIES=${GUEST_DIR}/${DYLIB}" \
  -e "VEERTU_ANKA_GPU_APPLE_FAMILY_MAX=${APPLE_FAMILY_MAX}" \
  "$VM_ID" "${GUEST_DIR}/${PROBE}" "$APPLE_FAMILY_MAX"

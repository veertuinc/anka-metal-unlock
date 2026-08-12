# anka-metal-unlock

Veertu research tooling for Anka on Apple Silicon. It raises selected Metal
capability answers inside one guest process so Metal apps can pick newer kernel
paths on the stock paravirtual GPU.

This is not physical GPU passthrough. Work still goes through
`Virtualization.framework` graphics.

## Layout

| Path | Role |
| --- | --- |
| `guest/` | Inject library sources (`libAnkaGpuFamilyBoost`) |
| `bin/anka-gpu-probe.m` | Guest probe that prints JSON capability answers |
| `host/` | Host preference helpers and Anka compare script |
| `make/` | Compile and checksum check |
| `out/` | Build output (not committed) |

## Requirements

- Apple Silicon host with Anka
- macOS guest (Tahoe-class guests used in testing)
- Xcode Command Line Tools
- Host preference `ForceUnrestrictedDeviceFeatureLevel` for the macOS user that starts VMs

## Compile

```bash
./make/compile.sh
./make/check.sh
```

`out/` then holds:

| File | Role |
| --- | --- |
| `libAnkaGpuFamilyBoost-arm64.dylib` | Guest inject library (typical Anka guest) |
| `libAnkaGpuFamilyBoost-arm64e.dylib` | arm64e variant |
| `anka-gpu-probe` | JSON probe |
| `CHECKSUMS.sha256` | Digests |

## Host preference

```bash
./host/enable-pv-feature-level.sh
```

Clear it with:

```bash
./host/disable-pv-feature-level.sh
```

Both wrap:

```bash
defaults write com.apple.gpusw.ParavirtualizedGraphics \
  ForceUnrestrictedDeviceFeatureLevel -bool true
```

Stop and start Anka VMs after you change the preference.

## Compare stock vs boosted in a VM

```bash
./host/enable-pv-feature-level.sh
anka stop my-vm
anka start my-vm
./host/compare-vm-probe.sh my-vm
```

Expected shape:

```text
===== STOCK =====
{"device":"Apple Paravirtual device","family":1009,"supports_family":false,"max_threadgroup_memory":32768}
===== BOOSTED =====
{"device":"Apple Paravirtual device","family":1009,"supports_family":true,"max_threadgroup_memory":65536}
```

## Boost one guest workload

Copy `out/libAnkaGpuFamilyBoost-arm64.dylib` into the guest, then start the app with:

```bash
DYLD_INSERT_LIBRARIES=/path/to/libAnkaGpuFamilyBoost-arm64.dylib \
VEERTU_ANKA_GPU_APPLE_FAMILY_MAX=1009 \
/path/to/your-metal-app
```

With `anka run`:

```bash
anka run \
  -e DYLD_INSERT_LIBRARIES=/Users/anka/anka-metal-unlock/libAnkaGpuFamilyBoost-arm64.dylib \
  -e VEERTU_ANKA_GPU_APPLE_FAMILY_MAX=1009 \
  my-vm \
  /path/to/your-metal-app
```

### Environment variables

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `VEERTU_ANKA_GPU_APPLE_FAMILY_MAX` | yes | (none) | Apple-family ceiling (`1001`–`1999`). Missing or invalid values leave the process stock. |
| `VEERTU_ANKA_GPU_THREADGROUP_MEMORY_MIN` | no | `65536` | Minimum reported threadgroup memory (bytes). |
| `VEERTU_ANKA_GPU_WORKING_SET_MIN` | no | unchanged | Raise recommended working-set size only when set. |

Do not advertise `MTLGPUFamilyMetal3` with this tool. Some frameworks use that
answer to select residency paths that the paravirtual device may not support.

## Limits

- Experimental. Relies on private, version-sensitive Metal guest details.
- Per process. Hardened runtime binaries may reject inject.
- Still a VM. Existing `Virtualization.framework` limits remain.
- Validate each host chip, host macOS, guest macOS, and workload yourself.

## Support stance

Veertu provides this repository so Anka customers can reproduce and test Metal
capability boost. Treat it as research tooling unless your Anka support
agreement says otherwise.

## License

MIT. See [LICENSE](LICENSE).

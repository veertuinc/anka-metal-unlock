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
- Xcode Command Line Tools
- Host preference `ForceUnrestrictedDeviceFeatureLevel` for the macOS user that starts VMs

### Tested guest macOS versions

| Guest macOS | Probe result |
| --- | --- |
| 15.5 (Sequoia) | Stock → boosted (`supports_family` false→true, threadgroup 32 KB → 64 KB) |
| 26.4.1 (Tahoe) | Same as above |

Newer guest macOS versions may work. Apple can change private Metal details in any release, so you must run `./host/compare-vm-probe.sh` on your guest before you rely on it. Untested versions are unsupported until you confirm them.

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

## Example results (llama-bench)

Same short command on an Apple M3 Pro host and a macOS 26.4.1 Anka guest.
Model: `tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf`. Homebrew `llama.cpp` 10360.

```bash
llama-bench -m tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf \
  -p 64 -n 32 -r 1 -t 8 -o json
```

### Bare metal (host)

| Mode | ggml Metal family | pp64 (t/s) | tg32 (t/s) |
| --- | --- | ---: | ---: |
| CPU (`-ngl 0`) | Apple9 (1009) | 209.57 | 67.05 |
| Metal (`-ngl -1`) | Apple9 (1009) | 1981.53 | 151.02 |

### Anka guest (macOS 26.4.1)

| Mode | ggml Metal family | pp64 (t/s) | tg32 (t/s) |
| --- | --- | ---: | ---: |
| CPU (`-ngl 0`) | Apple5 (1005) | 13.33 | 0.22 |
| Anka default Metal (`-ngl -1`) | Apple5 (1005) | 9.26 | 0.14 |
| Metal unlock (`-ngl -1` + inject) | Apple9 (1009) | 1921.75 | 139.59 |

Guest unlock lands close to bare-metal Metal on this short TinyLlama run (prompt
~1922 vs ~1982 t/s, gen ~140 vs ~151 t/s). Stock guest Metal stayed on Apple5
with simdgroup reduction, simdgroup matrix multiply, and bfloat off. Unlock
turned those on and reported Apple9.

Numbers are from one short run on one host/guest pair. Re-run on your hardware
before you treat them as a baseline. Longer runs (`-p 512 -n 128 -r 10`) are
valid but CPU token generation is very slow in the guest.

## Example results (PyTorch MPS)

Same Apple M3 Pro host and macOS 26.4.1 Anka guest. Workload:
`bin/pytorch_infer_bench.py` — 8-layer MLP, batch 64, features 2048, hidden
4096, 5 warmups + 20 timed reps.

```bash
python3 bin/pytorch_infer_bench.py --device cpu   # or mps
```

Guest unlock with system Python needs the **arm64e** dylib (CLT `python3` is
arm64e-capable at inject time even when `file` reports arm64 slices):

```bash
DYLD_INSERT_LIBRARIES=/path/to/libAnkaGpuFamilyBoost-arm64e.dylib \
VEERTU_ANKA_GPU_APPLE_FAMILY_MAX=1009 \
python3 bin/pytorch_infer_bench.py --device mps
```

| Scenario | Device | samples/s | mean ms/batch |
| --- | --- | ---: | ---: |
| Host CPU | cpu | 1873.82 | 34.15 |
| Host MPS | mps | 8857.47 | 7.23 |
| Anka guest CPU | cpu | 1463.06 | 43.74 |
| Anka guest MPS (default) | mps | 7194.56 | 8.90 |
| Anka guest MPS (unlock) | mps | 8967.05 | 7.14 |

Host used PyTorch 2.13.0 (Python 3.11). Guest used PyTorch 2.8.0 (Python 3.9).
Unlike the TinyLlama Metal path, stock guest MPS already ran this MLP well;
unlock closed the remaining gap to bare-metal MPS (and slightly beat it on this
short run).

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

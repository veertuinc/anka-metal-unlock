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

| Scenario | ngl | ggml Metal family | pp64 (t/s) | tg32 (t/s) |
| --- | ---: | --- | ---: | ---: |
| Host CPU | 0 | Apple9 (1009) | 209.57 | 67.05 |
| Host Metal | -1 | Apple9 (1009) | 1981.53 | 151.02 |
| Anka guest CPU | 0 | Apple5 (1005) | 13.33 | 0.22 |
| Anka guest Metal (default) | -1 | Apple5 (1005) | 9.26 | 0.14 |
| Anka guest Metal (unlock) | -1 | Apple9 (1009) | 1921.75 | 139.59 |

Guest unlock lands close to host Metal on this short TinyLlama run (prompt
~1922 vs ~1982 t/s, gen ~140 vs ~151 t/s). Stock guest Metal stayed on Apple5
with simdgroup reduction, simdgroup matrix multiply, and bfloat off. Unlock
turned those on and reported Apple9.

Numbers are from one short run on one host/guest pair. Re-run on your hardware
before you treat them as a baseline. Longer runs (`-p 512 -n 128 -r 10`) are
valid but CPU token generation is very slow in the guest.

## Example results (PyTorch MPS)

Same Apple M3 Pro host and macOS 26.4.1 Anka guest. One-shot MLP forward
(host PyTorch 2.13 / Python 3.11; guest PyTorch 2.8 / Python 3.9):

| Scenario | Device | samples/s | mean ms/batch |
| --- | --- | ---: | ---: |
| Host CPU | cpu | 1873.82 | 34.15 |
| Host MPS | mps | 8857.47 | 7.23 |
| Anka guest CPU | cpu | 1463.06 | 43.74 |
| Anka guest MPS (default) | mps | 7194.56 | 8.90 |
| Anka guest MPS (unlock) | mps | 8967.05 | 7.14 |

Repeated guest MPS default vs unlock (5 MLP runs): default mean 9423 samples/s,
unlock 9481 (**+0.6%**). Other guest MPS workloads (mlp / gemm_fp16 / gemm_bf16 /
conv / attn, 3 runs each) stayed within about ±3% — noise, not a clear unlock
win. Use the **arm64e** dylib if you inject into CLT/system Python.

**Takeaway:** PyTorch MPS is roughly neutral for this unlock on the tested
paths. llama-bench (above) is the clear Metal-family win.

## Example results (OpenSubdiv Metal)

[OpenSubdiv](https://github.com/PixarAnimationStudios/OpenSubdiv) Metal
`EvalStencils` on a Catmark cube (refine level 7 → 98,306 refined verts,
8 warmups + 40 timed evals, **7 process runs**):

| Scenario | supports family 1009 | evals/s mean | median | stdev |
| --- | --- | ---: | ---: | ---: |
| Host Metal | true | 3313.76 | 3386.88 | 155.59 |
| Anka guest Metal (default) | false | 1765.86 | 1919.25 | 423.88 |
| Anka guest Metal (unlock) | true | 1868.17 | 1871.40 | 216.94 |

Guest default had one slow outlier (816 evals/s). After dropping values below
70% of the median, unlock was about **-2.9%** vs default (median **-2.5%**).
All-runs mean showed unlock +5.8% only because of that outlier. Unlock still
flips `supportsFamily(1009)` every run. Host Metal stays ~1.8× guest.

**Takeaway:** OpenSubdiv Metal runs either way; unlock changes the reported
family without a clear throughput win on this path.

## Testing summary: what works and what does not

Results below are from an Apple M3 Pro host and Anka macOS 15.5 / 26.4.1 guests.
Your machine may differ. Always re-check with `./host/compare-vm-probe.sh` and
your real workload.

### Works

| Area | What we saw |
| --- | --- |
| Capability probe | Stock guest reports Apple family support false and 32 KB threadgroup memory; with inject, family support becomes true and threadgroup memory rises to 64 KB (15.5 and 26.4.1). |
| Host preference | `ForceUnrestrictedDeviceFeatureLevel` is required so the guest can use unrestricted feature levels after VM restart. |
| llama.cpp / TinyLlama (Metal) | Large win. Guest unlock approached bare-metal Metal on a short `llama-bench` (pp64 ~1922 vs host ~1982 t/s; tg32 ~140 vs ~151). Stock guest Metal was slower than guest CPU. |
| Process scope | Only the injected process (and children that inherit the env) change. Remove `DYLD_INSERT_LIBRARIES` / `VEERTU_ANKA_GPU_*` to go back to stock. |
| arm64 vs arm64e | Use `libAnkaGpuFamilyBoost-arm64.dylib` for most apps; use the **arm64e** dylib for CLT/system Python and other arm64e binaries. |

### Does not work well / no clear gain

| Area | What we saw |
| --- | --- |
| PyTorch MPS (mlp, gemm, conv, attn) | Stock guest MPS already fast. Repeated runs: unlock within a few percent of default (noise). Not a reliable speedup path. |
| OpenSubdiv Metal `EvalStencils` | Unlock flips `supportsFamily(1009)` to true, but cleaned/median throughput was flat to slightly worse (~−2.5% to −2.9%). Host still ~1.8× guest. |
| `system_profiler SPDisplaysDataType` | Empty in the Anka guest with or without unlock. Unlock does not create a Displays GPU entry; it only changes Metal answers inside the injected process. |
| Physical GPU passthrough | Not provided. Work stays on Apple’s paravirtual graphics path. |
| Advertising `MTLGPUFamilyMetal3` | Avoid. Some stacks use that answer for residency paths the paravirtual device may not support. |
| Hardened-runtime / non-injectable apps | Inject may be rejected; those processes stay stock. |
| QEMU / nested VMs (expected) | Unlock does not change TCG/HVF/CPU emulation. Only a QEMU build that actually calls Metal *and* is injected could see different Metal answers; do not expect nested-VM speedups from this tool. |

### Practical guidance

1. Enable the host preference, restart the VM, confirm with `./host/compare-vm-probe.sh`.
2. Prefer workloads that branch on Apple GPU family / threadgroup size (llama.cpp Metal was the clear case).
3. Do not assume PyTorch MPS, OpenSubdiv stencil eval, or UI/system_profiler will get faster.
4. Match dylib arch to the target process (`arm64` vs `arm64e`).
5. Re-validate on each host chip, host macOS, guest macOS, and app build before production use.

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

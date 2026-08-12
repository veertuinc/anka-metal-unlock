# anka-metal-unlock

Use this with Anka on Apple Silicon when a guest Metal app reports an old GPU
family and then picks slow kernels (or crashes). The inject library changes
Metal capability answers **inside one guest process**. The VM still uses Apple
paravirtual graphics. This is not physical GPU passthrough.

Typical case: llama.cpp, whisper.cpp, Ollama, and other apps that use ggml's
Metal backend. ggml is the tensor library behind those tools. On Apple Silicon
it asks Metal for GPU family, threadgroup size, and simdgroup support, then
picks shaders from that answer. In the guest they often report
`MTLGPUFamilyApple5`. After inject they report Apple9, turn on simdgroup
features, and run much closer to the host.

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

Confirmed on Anka guests **macOS 15.5** and **26.4.1**: stock probe shows
`supports_family` false and 32 KB threadgroup memory; after inject, family
support is true and threadgroup memory is 64 KB.

Apple can change private Metal details in any guest release. Run
`./host/compare-vm-probe.sh` on your VM before you rely on it.

## Compile

```bash
./make/compile.sh
./make/check.sh
```

`out/` then holds:

| File | Role |
| --- | --- |
| `libAnkaGpuFamilyBoost-arm64.dylib` | Guest inject library (most Anka guest apps) |
| `libAnkaGpuFamilyBoost-arm64e.dylib` | arm64e variant (CLT/system Python, some brew Python) |
| `anka-gpu-probe` | JSON probe |
| `CHECKSUMS.sha256` | Digests |

## Enable the host preference

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

## Confirm stock vs boosted in a VM

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

Only that process (and children that inherit the environment) change. Remove
the two variables to go back to stock.

Match the dylib to the binary: `arm64` for most apps, `arm64e` for CLT/system
Python and some Homebrew Python processes (including MLX). If dyld reports
`have 'arm64', need 'arm64e'`, switch dylib.

For Ollama, inject `ollama serve`. Inject on `ollama run` alone does not
change the server.

Do not advertise `MTLGPUFamilyMetal3` with this tool. Some frameworks use that
answer to select residency paths that the paravirtual device may not support.

### Environment variables

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `VEERTU_ANKA_GPU_APPLE_FAMILY_MAX` | yes | (none) | Apple-family ceiling (`1001`–`1999`). Missing or invalid values leave the process stock. |
| `VEERTU_ANKA_GPU_THREADGROUP_MEMORY_MIN` | no | `65536` | Minimum reported threadgroup memory (bytes). |
| `VEERTU_ANKA_GPU_WORKING_SET_MIN` | no | unchanged | Raise recommended working-set size only when set. |

## What to expect

Numbers below are from one Apple M3 Pro host and Anka macOS 26.4.1 (and 15.5
for the probe). Your chip, host macOS, guest macOS, and app build will differ.
Measure your own workload.

### Apps that use ggml Metal

ggml-based tools (llama.cpp, whisper.cpp, Ollama, stable-diffusion.cpp) choose
Metal kernels from the reported GPU family. That is the reason to use this
tool. Stock guest Metal stays on Apple5 with
simdgroup reduction, simdgroup matrix multiply, and bfloat off. After inject
the same process reports Apple9 and turns those on.

llama.cpp (`llama-bench`, Homebrew 10360), TinyLlama Q4_K_M, short run
`-p 64 -n 32 -r 1 -t 8`:

| Scenario | ngl | ggml Metal family | pp64 (t/s) | tg32 (t/s) |
| --- | ---: | --- | ---: | ---: |
| Host CPU | 0 | Apple9 (1009) | 209.57 | 67.05 |
| Host Metal | -1 | Apple9 (1009) | 1981.53 | 151.02 |
| Anka guest CPU | 0 | Apple5 (1005) | 13.33 | 0.22 |
| Anka guest Metal (default) | -1 | Apple5 (1005) | 9.26 | 0.14 |
| Anka guest Metal (boost) | -1 | Apple9 (1009) | 1921.75 | 139.59 |

On that short TinyLlama run, guest boost is close to host Metal. Stock guest
Metal is slower than guest CPU.

Qwen2.5-1.5B Instruct Q4_K_M, same short `llama-bench`: stock pp64 ~6.6 /
tg32 ~0.10 t/s; boost pp64 ~1356 / tg32 ~86 t/s.

whisper.cpp `whisper-cli` with `ggml-tiny` and the sample jfk.wav: stock
total ~60 s; boost ~0.74–0.89 s. The `whisper-bench` `mul_mat` microbench
stays close to stock; the gain shows up in full transcription.

Ollama: inject `ollama serve`. Eval rate on a small model: stock ~14–17 t/s;
boost ~138–149 t/s.

stable-diffusion.cpp (SD 1.5 Q4_0, 256², 4 steps): stock Metal aborted or
segfaulted during CLIP encode on Apple5. With boost, Apple9, the same command
wrote a PNG (~7.5 s on a warm run).

### Apps that already run well on stock guest Metal

Do not expect a similar jump.

PyTorch MPS (MLP, GEMM, conv, attention): stock guest MPS is already fast.
Repeated default vs boost stayed within a few percent. Use the arm64e dylib
if you inject into CLT/system Python.

MLX-LM (SmolLM-135M-4bit): stock already ~300+ gen t/s. Boost stayed in the
same band. Use the arm64e dylib with brew Python.

Candle Metal F16 2048² matmul: about +10% GFLOPS. Not a llama.cpp-class
change.

OpenSubdiv Metal `EvalStencils` (Catmark cube, refine level 7): boost flips
`supportsFamily(1009)` to true. Median throughput was flat to slightly worse
(~−2.5%). Host Metal stayed about 1.8× the guest.

`system_profiler SPDisplaysDataType` stays empty in the Anka guest. Boost
does not add a Displays GPU entry. It only changes Metal answers inside the
injected process.

Hardened-runtime binaries may reject inject and stay stock. Nested QEMU /
CPU emulation does not get faster unless that process actually calls Metal
and you inject it.

## Limits

- Experimental. Relies on private, version-sensitive Metal guest details.
- Per process. Hardened runtime binaries may reject inject.
- Still a VM. Existing `Virtualization.framework` limits remain.
- Confirm on your host chip, host macOS, guest macOS, and workload.

## Support

Veertu provides this repository so Anka customers can reproduce and test Metal
capability boost. Treat it as research tooling unless your Anka support
agreement says otherwise.

## License

MIT. See [LICENSE](LICENSE).

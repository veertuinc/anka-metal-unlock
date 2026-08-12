#!/usr/bin/env python3
# Copyright (c) 2026 Veertu Inc.
# SPDX-License-Identifier: MIT
"""
Timed PyTorch MPS/CPU workloads for capability-unlock comparisons.

Workloads:
  mlp       - dense Linear stack (fp32)
  gemm_fp16 - large batched GEMM in float16
  gemm_bf16 - large batched GEMM in bfloat16 (falls back if unsupported)
  conv      - Conv2d tower (fp32)
  attn      - multi-head self-attention block (fp16)
"""

from __future__ import annotations

import argparse
import json
import platform
import statistics
import sys
import time


WORKLOADS = ("mlp", "gemm_fp16", "gemm_bf16", "conv", "attn")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", choices=("cpu", "mps"), required=True)
    parser.add_argument("--workload", choices=WORKLOADS, default="mlp")
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--features", type=int, default=2048)
    parser.add_argument("--hidden", type=int, default=4096)
    parser.add_argument("--layers", type=int, default=8)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--reps", type=int, default=20)
    parser.add_argument("--label", default="")
    return parser.parse_args()


def pick_device(name: str):
    import torch

    if name == "cpu":
        return torch.device("cpu")
    if not torch.backends.mps.is_available():
        raise SystemExit("MPS is not available in this PyTorch build/runtime")
    if not torch.backends.mps.is_built():
        raise SystemExit("This PyTorch build was compiled without MPS")
    return torch.device("mps")


def sync(device) -> None:
    import torch

    if device.type == "mps":
        torch.mps.synchronize()


def dtype_supported(device, dtype) -> bool:
    import torch

    try:
        x = torch.ones((2, 2), device=device, dtype=dtype)
        y = x @ x
        sync(device)
        return bool(y[0, 0].item() == 2.0)
    except Exception:
        return False


def build_mlp(args, device):
    from torch import nn

    blocks = [nn.Linear(args.features, args.hidden), nn.ReLU()]
    for _ in range(max(0, args.layers - 1)):
        blocks.extend([nn.Linear(args.hidden, args.hidden), nn.ReLU()])
    blocks.append(nn.Linear(args.hidden, args.features))
    model = nn.Sequential(*blocks).to(device).eval()

    import torch

    x = torch.randn(args.batch, args.features, device=device)
    return model, x, "samples"


def build_gemm(args, device, dtype):
    import torch

    # Large GEMMs tend to exercise simdgroup/matrix paths more than a tiny MLP.
    m = max(512, args.batch * 8)
    k = max(2048, args.features)
    n = max(2048, args.hidden)
    a = torch.randn(m, k, device=device, dtype=dtype)
    b = torch.randn(k, n, device=device, dtype=dtype)

    def run():
        return a @ b

    meta = {"m": m, "k": k, "n": n, "dtype": str(dtype).replace("torch.", "")}
    return run, meta, float(m)


def build_conv(args, device):
    from torch import nn
    import torch

    channels = 64
    layers = []
    in_ch = 3
    for _ in range(max(4, args.layers)):
        layers.extend(
            [
                nn.Conv2d(in_ch, channels, kernel_size=3, padding=1),
                nn.ReLU(inplace=True),
            ]
        )
        in_ch = channels
    model = nn.Sequential(*layers).to(device).eval()
    # 224-ish spatial size keeps memory reasonable in a 6G guest.
    spatial = 128
    x = torch.randn(args.batch // 4 or 1, 3, spatial, spatial, device=device)
    return model, x, "images"


def build_attn(args, device, dtype):
    import torch
    from torch import nn

    class AttnBlock(nn.Module):
        def __init__(self, dim: int, heads: int = 16):
            super().__init__()
            self.heads = heads
            self.dim = dim
            self.head_dim = dim // heads
            self.qkv = nn.Linear(dim, dim * 3, bias=False)
            self.proj = nn.Linear(dim, dim, bias=False)
            self.norm = nn.LayerNorm(dim)

        def forward(self, x):
            b, s, d = x.shape
            h = self.heads
            x_n = self.norm(x)
            qkv = self.qkv(x_n).reshape(b, s, 3, h, self.head_dim)
            qkv = qkv.permute(2, 0, 3, 1, 4)
            q, k, v = qkv[0], qkv[1], qkv[2]
            scale = self.head_dim ** -0.5
            attn = torch.matmul(q, k.transpose(-2, -1)) * scale
            attn = torch.softmax(attn, dim=-1)
            out = torch.matmul(attn, v)
            out = out.transpose(1, 2).reshape(b, s, d)
            return self.proj(out) + x

    dim = max(512, args.features // 2)
    # Keep dim divisible by heads.
    heads = 16
    dim = (dim // heads) * heads
    seq = 256
    batch = max(1, args.batch // 8)
    model = AttnBlock(dim, heads=heads).to(device=device, dtype=dtype).eval()
    x = torch.randn(batch, seq, dim, device=device, dtype=dtype)
    meta = {
        "seq": seq,
        "dim": dim,
        "heads": heads,
        "batch": batch,
        "dtype": str(dtype).replace("torch.", ""),
    }
    return model, x, "tokens", meta, float(batch * seq)


def make_runner(args, device):
    import torch

    if args.workload == "mlp":
        model, x, unit = build_mlp(args, device)
        return (lambda: model(x)), {"unit": unit}, float(args.batch)

    if args.workload == "gemm_fp16":
        if not dtype_supported(device, torch.float16):
            raise SystemExit("float16 GEMM unsupported on this device")
        run, meta, work = build_gemm(args, device, torch.float16)
        meta["unit"] = "rows"
        return run, meta, work

    if args.workload == "gemm_bf16":
        if not dtype_supported(device, torch.bfloat16):
            raise SystemExit("bfloat16 GEMM unsupported on this device")
        run, meta, work = build_gemm(args, device, torch.bfloat16)
        meta["unit"] = "rows"
        return run, meta, work

    if args.workload == "conv":
        model, x, unit = build_conv(args, device)
        return (lambda: model(x)), {"unit": unit, "images": int(x.shape[0])}, float(
            x.shape[0]
        )

    if args.workload == "attn":
        dtype = torch.float16
        if not dtype_supported(device, dtype):
            dtype = torch.float32
        model, x, unit, meta, work = build_attn(args, device, dtype)
        meta["unit"] = unit
        return (lambda: model(x)), meta, work

    raise SystemExit("unknown workload: %s" % args.workload)


def main() -> int:
    args = parse_args()
    try:
        import torch
    except ImportError:
        print("torch is not installed", file=sys.stderr)
        return 2

    device = pick_device(args.device)
    torch.set_num_threads(max(1, torch.get_num_threads()))

    try:
        run, meta, work_items = make_runner(args, device)
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        return 3

    with torch.inference_mode():
        for _ in range(args.warmup):
            y = run()
            sync(device)

        times_s = []
        for _ in range(args.reps):
            sync(device)
            start = time.perf_counter()
            y = run()
            sync(device)
            times_s.append(time.perf_counter() - start)
            # Keep result live.
            if hasattr(y, "reshape"):
                _ = y.reshape(-1)[0]

    mean_s = statistics.fmean(times_s)
    stdev_s = statistics.stdev(times_s) if len(times_s) > 1 else 0.0
    throughput = work_items / mean_s

    result = {
        "label": args.label,
        "workload": args.workload,
        "host": platform.node(),
        "platform": platform.platform(),
        "python": sys.version.split()[0],
        "torch": torch.__version__,
        "device": str(device),
        "mps_available": torch.backends.mps.is_available(),
        "batch": args.batch,
        "features": args.features,
        "hidden": args.hidden,
        "layers": args.layers,
        "warmup": args.warmup,
        "reps": args.reps,
        "mean_ms": mean_s * 1000.0,
        "stdev_ms": stdev_s * 1000.0,
        "throughput": throughput,
        "throughput_unit": meta.get("unit", "items") + "_per_s",
        "meta": meta,
        "times_ms": [t * 1000.0 for t in times_s],
    }
    # Keep old key for mlp compatibility with prior README tooling.
    if args.workload == "mlp":
        result["samples_per_s"] = throughput
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
# Copyright (c) 2026 Veertu Inc.
# SPDX-License-Identifier: MIT
"""
Timed PyTorch inference-style workload for CPU vs MPS comparison.

Runs a small MLP forward pass over random batches and prints JSON stats.
"""

from __future__ import annotations

import argparse
import json
import platform
import statistics
import sys
import time


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--device",
        choices=("cpu", "mps"),
        required=True,
        help="Torch device to use",
    )
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--features", type=int, default=2048)
    parser.add_argument("--hidden", type=int, default=4096)
    parser.add_argument("--layers", type=int, default=8)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--reps", type=int, default=20)
    parser.add_argument(
        "--label",
        default="",
        help="Optional scenario label included in JSON output",
    )
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


def build_model(features: int, hidden: int, layers: int, device):
    import torch
    from torch import nn

    blocks = [nn.Linear(features, hidden), nn.ReLU()]
    for _ in range(max(0, layers - 1)):
        blocks.extend([nn.Linear(hidden, hidden), nn.ReLU()])
    blocks.append(nn.Linear(hidden, features))
    model = nn.Sequential(*blocks).to(device)
    model.eval()
    return model


def main() -> int:
    args = parse_args()
    try:
        import torch
    except ImportError:
        print("torch is not installed", file=sys.stderr)
        return 2

    device = pick_device(args.device)
    torch.set_num_threads(max(1, torch.get_num_threads()))
    model = build_model(args.features, args.hidden, args.layers, device)
    x = torch.randn(args.batch, args.features, device=device)

    with torch.inference_mode():
        for _ in range(args.warmup):
            _ = model(x)
            sync(device)

        times_s = []
        for _ in range(args.reps):
            sync(device)
            start = time.perf_counter()
            y = model(x)
            sync(device)
            times_s.append(time.perf_counter() - start)
            # Keep the graph live so the compiler cannot drop the work.
            if float(y[0, 0]) == float("inf"):
                raise RuntimeError("unexpected output")

    mean_s = statistics.fmean(times_s)
    stdev_s = statistics.stdev(times_s) if len(times_s) > 1 else 0.0
    samples_per_s = args.batch / mean_s

    result = {
        "label": args.label,
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
        "samples_per_s": samples_per_s,
        "times_ms": [t * 1000.0 for t in times_s],
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

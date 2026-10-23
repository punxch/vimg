"""Measure fresh-process, warm-file-cache static previews in paired ABBA order.

The baseline and candidate must support native preview. Give each executable its
own adjacent runtime DLLs, or put the common runtime on PATH. No cache purging.
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import time


def system_cpu():
    if os.name != "nt":
        return None
    values = [wintypes.FILETIME() for _ in range(3)]
    if not ctypes.windll.kernel32.GetSystemTimes(*(ctypes.byref(v) for v in values)):
        raise ctypes.WinError()
    idle, kernel, user = [(v.dwHighDateTime << 32) | v.dwLowDateTime for v in values]
    return kernel + user, kernel + user - idle


def distribution(values):
    values = sorted(values)
    return dict(median=statistics.median(values), p95=values[math.ceil(.95 * len(values)) - 1],
                minimum=values[0], maximum=values[-1])


def process_cpu_ms(process):
    if os.name != "nt":
        return None
    values = [wintypes.FILETIME() for _ in range(4)]
    if not ctypes.windll.kernel32.GetProcessTimes(wintypes.HANDLE(int(process._handle)),
                                                 *(ctypes.byref(v) for v in values)):
        raise ctypes.WinError()
    return sum((v.dwHighDateTime << 32) | v.dwLowDateTime for v in values[2:]) / 10_000


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--runs", type=int, default=12, help="Measured calls per arm, a positive multiple of four")
    parser.add_argument("--skip", type=int, default=0)
    parser.add_argument("--timings", action="store_true")
    args = parser.parse_args()
    if args.runs < 4 or args.runs % 4:
        parser.error("--runs must be a positive multiple of four")
    args.output_dir.mkdir(parents=True, exist_ok=False)
    executables = {arm: getattr(args, arm).resolve() for arm in ["baseline", "candidate"]}
    identities = {arm: hashlib.sha256(path.read_bytes()).hexdigest() for arm, path in executables.items()}
    order = ["baseline", "candidate"] * 2 + ["baseline", "candidate", "candidate", "baseline",
                                              "candidate", "baseline", "baseline", "candidate"] * (args.runs // 4)
    rows = []
    unique_images = {}
    for index, arm in enumerate(order):
        output = args.output_dir / f"{index}-{arm}.jpg"
        command = [str(executables[arm]), "preview", *(["--timings"] if args.timings else []),
                   "--output", str(output.resolve()), "--skip", str(args.skip),
                   "--max-width", "600", "--max-height", "900", "--quality", "75", "--", str(args.video.resolve())]
        before = system_cpu()
        started = time.perf_counter()
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            stdout, stderr = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise
        elapsed = (time.perf_counter() - started) * 1000
        after = system_cpu()
        assert process.returncode == 0 and json.loads(stdout)["preview_written"], stderr
        jpeg = output.read_bytes()
        assert jpeg.startswith(b"\xff\xd8") and jpeg.endswith(b"\xff\xd9"), output
        digest = hashlib.sha256(jpeg).hexdigest()
        unique_images[digest] = output
        timing = [json.loads(line.split(" ", 1)[1]) for line in stderr.decode(errors="replace").splitlines()
                  if line.startswith("vimg-preview-timing ")]
        assert len(timing) == int(args.timings)
        row = dict(index=index, arm=arm, warmup=index < 4, elapsed_ms=elapsed,
                   system_pct=100 * (after[1] - before[1]) / (after[0] - before[0]) if before and after[0] > before[0] else None,
                   cpu_ms=process_cpu_ms(process), sha256=digest, timing=timing[0] if timing else None)
        rows.append(row)
        (args.output_dir / "rows.json").write_text(json.dumps(rows, indent=2))
    # Validate distinct outputs after measurement, avoiding extra FFmpeg
    # processes/cache activity between paired timing samples.
    for output in unique_images.values():
        subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-err_detect", "explode", "-i", str(output),
                        "-frames:v", "1", "-f", "null", "-"], capture_output=True, check=True)
    summary = {}
    for arm in executables:
        selected = [r for r in rows if r["arm"] == arm and not r["warmup"]]
        summary[arm] = dict(n=len(selected), elapsed_ms=distribution([r["elapsed_ms"] for r in selected]))
        cpu = [r["system_pct"] for r in selected if r["system_pct"] is not None]
        if cpu:
            summary[arm]["system_pct"] = distribution(cpu)
            summary[arm]["cpu_ms"] = distribution([r["cpu_ms"] for r in selected])
        if args.timings:
            totals = []
            for row in selected:
                stages = {}
                for name, value in row["timing"]["stages_ms"]:
                    stages[name] = stages.get(name, 0) + value
                totals.append(stages)
            summary[arm]["stages_ms"] = {name: statistics.median(s.get(name, 0) for s in totals)
                                          for name in sorted(set().union(*totals))}
            summary[arm]["packets"] = [r["timing"]["packets"] for r in selected]
    result = dict(summary=summary, executable_sha256=identities, video=str(args.video.resolve()),
                  skip=args.skip, timings=args.timings, cache_state="OS-warm", rows=rows)
    (args.output_dir / "results.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()

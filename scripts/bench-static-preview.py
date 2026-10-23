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
import sys
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


def wait_for_idle(maximum, timeout):
    """Require four consecutive 250ms windows below the declared CPU limit."""
    samples = []
    deadline = time.monotonic() + timeout
    before = system_cpu()
    while time.monotonic() < deadline:
        time.sleep(.25)
        after = system_cpu()
        if after[0] > before[0]:
            samples.append(100 * (after[1] - before[1]) / (after[0] - before[0]))
        before = after
        if len(samples) >= 4 and max(samples[-4:]) <= maximum:
            return samples
    raise TimeoutError(f"CPU did not remain below {maximum}% for one second within {timeout}s")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--runs", type=int, default=12, help="Accepted measured calls per arm, a positive multiple of four")
    parser.add_argument("--skip", type=int, default=0)
    parser.add_argument("--timings", action="store_true")
    parser.add_argument("--max-system-cpu", type=float,
                        help="Windows: retain but repeat a whole ABBA/BAAB block if any measured call exceeds this CPU percentage")
    parser.add_argument("--idle-system-cpu", type=float, default=8,
                        help="With --max-system-cpu, wait for one second below this CPU percentage before each measured call (default: 8)")
    parser.add_argument("--idle-timeout", type=float, default=180,
                        help="Maximum seconds to wait for idle CPU before failing (default: 180)")
    parser.add_argument("--max-blocks", type=int,
                        help="Maximum attempted blocks, including busy blocks (default: four times the required block count)")
    args = parser.parse_args()
    if args.runs < 4 or args.runs % 4:
        parser.error("--runs must be a positive multiple of four")
    if not 0 < args.idle_system_cpu <= 100:
        parser.error("--idle-system-cpu must be between zero and 100")
    if not math.isfinite(args.idle_timeout) or args.idle_timeout < 1:
        parser.error("--idle-timeout must be finite and at least one second")
    if args.max_system_cpu is not None:
        if os.name != "nt":
            parser.error("CPU gating currently requires Windows")
        if not 0 < args.idle_system_cpu <= args.max_system_cpu <= 100:
            parser.error("Require 0 < --idle-system-cpu <= --max-system-cpu <= 100")
    max_blocks = args.max_blocks if args.max_blocks is not None else 2 * args.runs
    if max_blocks < args.runs // 2:
        parser.error("--max-blocks must allow at least --runs / 2 blocks")
    args.output_dir.mkdir(parents=True, exist_ok=False)
    executables = {arm: getattr(args, arm).resolve() for arm in ["baseline", "candidate"]}
    identities = {arm: hashlib.sha256(path.read_bytes()).hexdigest() for arm, path in executables.items()}
    cpu_policy = dict(max_system_cpu=args.max_system_cpu, idle_system_cpu=args.idle_system_cpu,
                      idle_timeout=args.idle_timeout, max_blocks=max_blocks)
    (args.output_dir / "run.json").write_text(json.dumps(dict(
        executables={arm: str(path) for arm, path in executables.items()}, executable_sha256=identities,
        video=str(args.video.resolve()), runs=args.runs, skip=args.skip, timings=args.timings,
        cpu_policy=cpu_policy), indent=2))
    rows = []
    unique_images = {}

    def calls():
        for arm in ["baseline", "candidate"] * 2:
            yield len(rows), arm, True, None
        accepted = 0
        for block in range(max_blocks):
            first = len(rows)
            order = ["baseline", "candidate", "candidate", "baseline"] if block % 2 == 0 else ["candidate", "baseline", "baseline", "candidate"]
            for arm in order:
                yield len(rows), arm, False, block
            batch = rows[first:]
            keep = args.max_system_cpu is None or all(r["system_pct"] is not None and r["system_pct"] <= args.max_system_cpu for r in batch)
            for row in batch:
                row["accepted"] = keep
            accepted += int(keep)
            if args.max_system_cpu is not None:
                (args.output_dir / "rows.json").write_text(json.dumps(rows, indent=2))
                print(f"Block {block + 1}: {'accepted' if keep else 'busy, retained'}; {accepted}/{args.runs // 2} accepted", file=sys.stderr)
            if accepted == args.runs // 2:
                return
        raise RuntimeError("Not enough quiet blocks; all completed samples are preserved in rows.json")

    for index, arm, warmup, block in calls():
        output = args.output_dir / f"{index}-{arm}.jpg"
        command = [str(executables[arm]), "preview", *(["--timings"] if args.timings else []),
                   "--output", str(output.resolve()), "--skip", str(args.skip),
                   "--max-width", "600", "--max-height", "900", "--quality", "75", "--", str(args.video.resolve())]
        idle = wait_for_idle(args.idle_system_cpu, args.idle_timeout) if args.max_system_cpu is not None and not warmup else []
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
        row = dict(index=index, arm=arm, warmup=warmup, block=block, accepted=None, idle_samples=idle, elapsed_ms=elapsed,
                   system_pct=100 * (after[1] - before[1]) / (after[0] - before[0]) if before and after[0] > before[0] else None,
                   cpu_ms=process_cpu_ms(process), sha256=digest, timing=timing[0] if timing else None)
        rows.append(row)
        (args.output_dir / "rows.json").write_text(json.dumps(rows, indent=2))
    (args.output_dir / "rows.json").write_text(json.dumps(rows, indent=2))
    # Validate distinct outputs after measurement, avoiding extra FFmpeg
    # processes/cache activity between paired timing samples.
    for output in unique_images.values():
        subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-err_detect", "explode", "-i", str(output),
                        "-frames:v", "1", "-f", "null", "-"], capture_output=True, check=True)
    def summarize(accepted_only):
        summary = {}
        for arm in executables:
            selected = [r for r in rows if r["arm"] == arm and not r["warmup"] and (not accepted_only or r["accepted"])]
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
                summary[arm]["stage_distributions_ms"] = {
                    name: distribution([s.get(name, 0) for s in totals])
                    for name in sorted(set().union(*totals))
                }
                summary[arm]["native_total_ms"] = distribution([r["timing"]["total_ms"] for r in selected])
                # Includes process creation/loading, CLI work, output and exit.
                # Use the native span, not the sum of individual stage marks.
                summary[arm]["outside_native_ms"] = distribution([
                    r["elapsed_ms"] - r["timing"]["total_ms"] for r in selected
                ])
                summary[arm]["packets"] = [r["timing"]["packets"] for r in selected]
        return summary

    summary = summarize(True)
    result = dict(summary=summary, executable_sha256=identities, video=str(args.video.resolve()),
                  all_samples_summary=summarize(False),
                  cpu_policy=cpu_policy,
                  skip=args.skip, timings=args.timings, cache_state="OS-warm", rows=rows)
    (args.output_dir / "results.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()

"""Compare immediate and delayed jobs in the real ignored service benchmark.

Windows, Python standard library only. Build the release tests first:
  cargo test --release --features in-process-decode --no-run
Then supply the test executable (not target/release/vimg.exe):
  python scripts/bench-service.py --test-exe target/release/deps/vimg-<hash>.exe \
      --dll-dir D:/ffmpeg-dev/libav-deploy --output-dir .scratch/service-age

Each process generates ten previews and checks ten cache hits. Alternates whole
fresh/aged processes in AB/BA order; no cache purge or DDS notification timing.
Exit 2 means a measured slowdown exceeds --max-slowdown, not a proven code bug.
Exit 0 does not imply the separate 1.3-second P95 performance target was met.
"""

import argparse
import ctypes as c
from ctypes import wintypes as w
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
from statistics import median
import subprocess
import threading
import time


def distribution(values):
    values = sorted(values)
    return dict(median=median(values), p95=values[math.ceil(.95 * len(values)) - 1],
                minimum=values[0], maximum=values[-1])


def summarize(runs, max_slowdown):
    """Compare first-three medians by round and last/first within each process."""
    comparisons = []
    for round_index in sorted({run['round'] for run in runs}):
        pair = {run['arm']: run for run in runs if run['round'] == round_index}
        fresh = median(job['render'] for job in pair['fresh']['jobs'][:3])
        aged = median(job['render'] for job in pair['aged']['jobs'][:3])
        comparisons.append(dict(round=round_index, fresh=fresh, aged=aged, ratio=aged / fresh))
    sequences = []
    for run in runs:
        first = median(job['render'] for job in run['jobs'][:3])
        last = median(job['render'] for job in run['jobs'][-3:])
        sequences.append(dict(round=run['round'], arm=run['arm'], first=first,
                              last=last, ratio=last / first))
    return dict(age_comparisons=comparisons, sequences=sequences,
                warm={arm: distribution([job['render'] for run in runs if run['arm'] == arm
                                         for job in run['jobs'][1:]]) for arm in ['fresh', 'aged']},
                slowdown_detected=any(row['ratio'] > max_slowdown for row in comparisons + sequences))


class WindowsCounters:
    def __init__(self):
        self.kernel = c.WinDLL('kernel32', use_last_error=True)
        self.kernel.GetSystemTimes.argtypes = [c.POINTER(w.FILETIME)] * 3
        self.kernel.GetSystemTimes.restype = w.BOOL
        self.kernel.GetProcessTimes.argtypes = [w.HANDLE] + [c.POINTER(w.FILETIME)] * 4
        self.kernel.GetProcessTimes.restype = w.BOOL
        self.psapi = c.WinDLL('psapi', use_last_error=True)
        self.psapi.GetProcessMemoryInfo.argtypes = [w.HANDLE, c.c_void_p, w.DWORD]
        self.psapi.GetProcessMemoryInfo.restype = w.BOOL

    def snapshot(self, process):
        system = [w.FILETIME() for _ in range(3)]
        own = [w.FILETIME() for _ in range(4)]
        if not self.kernel.GetSystemTimes(*(c.byref(value) for value in system)):
            raise c.WinError(c.get_last_error())
        if not self.kernel.GetProcessTimes(int(process._handle), *(c.byref(value) for value in own)):
            raise c.WinError(c.get_last_error())
        def seconds(value):
            return ((value.dwHighDateTime << 32) | value.dwLowDateTime) / 1e7
        idle, kernel, user = map(seconds, system)
        return dict(time=time.perf_counter(), total=kernel + user,
                    busy=kernel + user - idle, cpu=sum(map(seconds, own[2:])))

    def memory(self, process):
        class Memory(c.Structure):
            _fields_ = [('cb', w.DWORD), ('faults', w.DWORD)] + [(name, c.c_size_t) for name in
                ['peak_ws', 'ws', 'peak_paged', 'paged', 'peak_nonpaged', 'nonpaged', 'commit', 'peak_commit']]
        value = Memory()
        value.cb = c.sizeof(value)
        if not self.psapi.GetProcessMemoryInfo(int(process._handle), c.byref(value), value.cb):
            # The process can exit immediately after its last result line.
            if process.poll() is not None:
                return None
            raise c.WinError(c.get_last_error())
        return dict(peak_ws_mib=value.peak_ws / 1048576, ws_mib=value.ws / 1048576,
                    peak_commit_mib=value.peak_commit / 1048576)


def measure(args, round_index, arm, counters):
    env = {key: value for key, value in os.environ.items() if not key.startswith('VIMG_')}
    env.update(VIMG_BENCH_PACED='1', VIMG_BENCH_PROFILE='1', VIMG_BENCH_VIDEO=str(args.video))
    if args.dll_dir:
        env['PATH'] = str(args.dll_dir) + os.pathsep + env.get('PATH', '')
    log_path = args.output_dir / f'{round_index}-{arm}.log'
    lines = queue.Queue()
    jobs = []
    passed = False
    # Create the log before launching the child so path errors cannot strand it.
    with log_path.open('x', encoding='utf-8') as log:
        process = subprocess.Popen([str(args.test_exe),
            'command::serve::tests::repeated_service_jobs_and_cache_hits',
            '--exact', '--ignored', '--nocapture'], cwd=args.repo, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding='utf-8', errors='replace', creationflags=0x08000000)

        def pump():
            try:
                for line in process.stdout:
                    log.write(line)
                    lines.put(line)
            finally:
                lines.put(None)

        reader = threading.Thread(target=pump)
        reader.start()

        def next_line():
            line = lines.get(timeout=30)
            if line is None:
                raise RuntimeError(f'Premature process exit; see {log_path}')
            return line

        try:
            while '[service-bench] ready' not in next_line():
                pass
            ready = time.perf_counter()
            delay = args.idle_seconds if arm == 'aged' else 0
            print(f'round={round_index} {arm}: ready; idle={delay}s', flush=True)
            time.sleep(delay)
            for index in range(10):
                before = counters.snapshot(process)
                process.stdin.write('run\n')
                process.stdin.flush()
                phases = {}
                while True:
                    line = next_line()
                    if line.startswith('[profile] backend='):
                        phases = {key: float(value) for key, value in re.findall(r'(\w+)=([\d.]+)s', line)}
                    match = re.search(r'\[service-bench\] job=(\d+) render=([\d.]+)s cached=([\d.]+)s', line)
                    if match:
                        break
                if int(match[1]) != index or not phases:
                    raise RuntimeError(f'Unexpected benchmark output; see {log_path}')
                after = counters.snapshot(process)
                total = after['total'] - before['total']
                busy = after['busy'] - before['busy']
                cpu = after['cpu'] - before['cpu']
                if total <= 0:
                    raise RuntimeError('System CPU counter did not advance')
                row = dict(job=index, render=float(match[2]), cached=float(match[3]), phases=phases,
                           since_ready=before['time'] - ready, cpu=cpu,
                           system_pct=100 * busy / total, other_pct=max(0, 100 * (busy - cpu) / total),
                           memory=counters.memory(process))
                jobs.append(row)
                print(f'round={round_index} {arm} job={index}: {row["render"]:.3f}s '
                      f'CPU={cpu:.3f}s other~{row["other_pct"]:.1f}%', flush=True)
            while True:
                line = lines.get(timeout=30)
                if line is None:
                    break
                passed |= 'test result: ok. 1 passed;' in line
            if process.wait(timeout=5) != 0 or not passed:
                raise RuntimeError(f'Service assertions failed; see {log_path}')
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
            reader.join(timeout=5)
            process.stdin.close()
            process.stdout.close()
            if reader.is_alive():
                raise RuntimeError(f'Log reader did not stop; see {log_path}')
    result = dict(round=round_index, arm=arm, jobs=jobs)
    (args.output_dir / f'{round_index}-{arm}.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--test-exe', required=True, type=Path)
    parser.add_argument('--video', type=Path, default=Path('sample/input.mkv'))
    parser.add_argument('--dll-dir', type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--rounds', type=int, default=2)
    parser.add_argument('--idle-seconds', type=float, default=10)
    parser.add_argument('--max-slowdown', type=float, default=1.3)
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('Windows CPU/memory counters are required')
    if not 1 <= args.rounds <= 100:
        parser.error('--rounds must be between 1 and 100')
    if not math.isfinite(args.idle_seconds) or not 0 <= args.idle_seconds <= 3600:
        parser.error('--idle-seconds must be between 0 and 3600')
    if not math.isfinite(args.max_slowdown) or args.max_slowdown <= 1:
        parser.error('--max-slowdown must be greater than 1')
    args.repo = Path(__file__).resolve().parents[1]
    for field in ['test_exe', 'video']:
        path = getattr(args, field).resolve(strict=True)
        if not path.is_file():
            parser.error(f'{field} must be a file')
        setattr(args, field, path)
    if args.dll_dir:
        args.dll_dir = args.dll_dir.resolve(strict=True)
        if not args.dll_dir.is_dir():
            parser.error('--dll-dir must be a directory')
    args.output_dir = args.output_dir.resolve()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    metadata = dict(test_exe=str(args.test_exe),
                    test_sha256=hashlib.sha256(args.test_exe.read_bytes()).hexdigest(),
                    video=str(args.video), video_size=args.video.stat().st_size,
                    video_mtime_ns=args.video.stat().st_mtime_ns, rounds=args.rounds,
                    idle_seconds=args.idle_seconds, max_slowdown=args.max_slowdown,
                    logical_processors=os.cpu_count(),
                    active_power_scheme=subprocess.check_output(['powercfg', '/getactivescheme']).decode(errors='replace'))
    (args.output_dir / 'environment.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    counters = WindowsCounters()
    runs = []
    for round_index in range(args.rounds):
        for arm in (['fresh', 'aged'] if round_index % 2 == 0 else ['aged', 'fresh']):
            runs.append(measure(args, round_index, arm, counters))
    summary = summarize(runs, args.max_slowdown)
    (args.output_dir / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps(summary, indent=2))
    return 2 if summary['slowdown_detected'] else 0


if __name__ == '__main__':
    raise SystemExit(main())

"""Exercise Windows benchmark retries with real previews and injected CPU counters.

These runs test measurement bookkeeping, not performance. Requires a native
vimg executable and ffmpeg on PATH. Artifacts are kept in a new output directory.
"""
import argparse
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import statistics
import sys
from unittest.mock import patch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vimg", type=Path, required=True)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("preview_benchmark", Path(__file__).with_name("bench-static-preview.py"))
    bench = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bench)

    def counters():
        total = busy = 0
        # Four warmups, one busy block (only one of its calls is busy), then
        # two quiet blocks. Both arms of the busy block must be excluded.
        for percent in [0] * 4 + [0, 50, 0, 0] + [0] * 8:
            yield total, busy
            total += 100
            busy += percent
            yield total, busy

    for name, max_blocks, succeeds in [("repeat-block", 3, True), ("retry-limit", 2, False)]:
        output = args.output_dir / name
        command = ["bench-static-preview.py", "--baseline", str(args.vimg.resolve()),
                   "--candidate", str(args.vimg.resolve()), "--video", str(args.video.resolve()),
                   "--output-dir", str(output), "--runs", "4", "--max-system-cpu", "12",
                   "--max-blocks", str(max_blocks), "--timings"]
        log = io.StringIO()
        error = None
        with patch.object(sys, "argv", command), patch.object(bench, "system_cpu", side_effect=counters()), \
                patch.object(bench, "wait_for_idle", return_value=[0] * 4), redirect_stdout(log), redirect_stderr(log):
            try:
                bench.main()
            except RuntimeError as caught:
                error = caught
        (args.output_dir / f"{name}.log").write_text(log.getvalue(), encoding="utf-8")
        rows = json.loads((output / "rows.json").read_text())
        measured = [r for r in rows if not r["warmup"]]
        assert len({r["sha256"] for r in rows}) == 1, "Real preview outputs differ"
        assert [r["accepted"] for r in measured[:4]] == [False] * 4
        assert all(r["accepted"] for r in measured[4:])
        assert [r["system_pct"] for r in measured[:4]] == [0, 50, 0, 0]
        assert json.loads((output / "run.json").read_text())["cpu_policy"]["max_blocks"] == max_blocks
        if succeeds:
            assert error is None, error
            result = json.loads((output / "results.json").read_text())
            for arm in ["baseline", "candidate"]:
                assert result["summary"][arm]["n"] == 4
                assert result["all_samples_summary"][arm]["n"] == 6
            # Exercise the real diagnostic JSON through the same busy-block
            # retry path. Stage tails and the outside-native remainder must
            # use the same population as wall time, without changing old fields.
            for field, accepted_only in [("summary", True), ("all_samples_summary", False)]:
                for arm in ["baseline", "candidate"]:
                    selected = [r for r in measured if r["arm"] == arm and (not accepted_only or r["accepted"])]
                    actual = result[field][arm]
                    native = [r["timing"]["total_ms"] for r in selected]
                    outside = [r["elapsed_ms"] - r["timing"]["total_ms"] for r in selected]
                    assert actual["native_total_ms"]["median"] == statistics.median(native)
                    assert actual["native_total_ms"]["p95"] == max(native)  # 4/6 samples: nearest-rank P95.
                    assert actual["outside_native_ms"]["median"] == statistics.median(outside)
                    assert actual["outside_native_ms"]["minimum"] == min(outside)
                    assert min(outside) >= 0
                    decode = [sum(v for n, v in r["timing"]["stages_ms"] if n == "read_decode") for r in selected]
                    assert min(decode) > 0
                    assert actual["stage_distributions_ms"]["read_decode"]["p95"] == max(decode)
                    assert actual["stage_distributions_ms"]["read_decode"]["median"] == actual["stages_ms"]["read_decode"]
        else:
            assert error and "Not enough quiet blocks" in str(error)
            assert not (output / "results.json").exists(), "Incomplete run must not publish a success summary"

    clock = [0.0]
    cpu = [0]

    def busy_cpu():
        cpu[0] += 100
        return cpu[0], cpu[0]

    def advance(seconds):
        clock[0] += seconds

    with patch.object(bench, "system_cpu", side_effect=busy_cpu), \
            patch.object(bench.time, "monotonic", side_effect=lambda: clock[0]), \
            patch.object(bench.time, "sleep", side_effect=advance):
        try:
            bench.wait_for_idle(8, 1)
        except TimeoutError:
            pass
        else:
            raise AssertionError("Idle wait must be bounded under sustained CPU load")
    print("Whole-block retries, phase distributions, retained samples, retry limit and idle timeout passed")


if __name__ == "__main__":
    main()

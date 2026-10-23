"""Validate static previews and record differences from gridthumb's FFmpeg command.

Example: python scripts/test-static-preview.py --vimg target/release/vimg.exe \
    --output-dir .scratch/static-check sample/input.mkv
Requires the native build's libav libraries on PATH. Keeps images and JSON for review.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location("probe_check", Path(__file__).with_name("test-preview-probe.py"))
probe_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe_check)


def ffmpeg_args(video, output, metadata, skip, width, height, quality):
    cover = any(s.get("disposition", {}).get("attached_pic") == 1 for s in metadata["streams"])
    percent = (0 if cover else 5) + skip
    args = ["ffmpeg", "-v", "error", "-threads", "1", "-filter_threads", "1",
            "-skip_frame", "nokey", "-an", "-sn", "-dn"]
    if percent:
        args += ["-ss", str(int(float(metadata["format"]["duration"]) * percent / 100))]
    args += ["-i", str(video)]
    if percent == 0:
        args += ["-map", "disp:attached_pic"]
    return args + ["-vframes", "1", "-threads:v", "1", "-q:v", str(31 - int(quality * .3)),
                   "-vf", f"scale='min({width},iw)':'min({height},ih)':force_original_aspect_ratio=decrease:flags=fast_bilinear",
                   "-f", "image2", "-y", str(output)]


def image_hashes(path):
    data = path.read_bytes()
    assert data[:2] == b"\xff\xd8", path
    rgb = subprocess.check_output(["ffmpeg", "-v", "error", "-xerror", "-err_detect", "explode", "-i", str(path), "-frames:v", "1",
                                   "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    info = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                              "-show_entries", "stream=width,height", "-of", "json", str(path)]))
    stream = info["streams"][0]
    assert len(rgb) == stream["width"] * stream["height"] * 3, path
    return {"jpeg": hashlib.sha256(data).hexdigest(), "rgb": hashlib.sha256(rgb).hexdigest(),
            "bytes": len(data), "width": stream["width"], "height": stream["height"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vimg", default="vimg")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--max-width", default=600, type=int)
    parser.add_argument("--max-height", default=900, type=int)
    parser.add_argument("--quality", default=75, type=int)
    parser.add_argument("--timings", action="store_true", help="Also check opt-in timing diagnostics on stderr")
    parser.add_argument("--exact", action="store_true", help="Additionally require the historical FFmpeg image (diagnostic only)")
    parser.add_argument("--dynamic-resolution", action="store_true", help="Allow size changes for fixtures whose coded resolution changes (same display aspect ratio)")
    parser.add_argument("--skip", action="append", type=int, help="Preview offset to check; repeat for multiple offsets (default: 0 and 45)")
    parser.add_argument("videos", nargs="+", type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    rows = []
    for index, video in enumerate(args.videos):
        video = video.resolve()
        expected = json.loads(subprocess.check_output(["ffprobe", "-v", "quiet", "-show_entries",
                              probe_check.ENTRIES, "-of", "json=c=1", str(video)]))
        for skip in args.skip if args.skip is not None else (0, 45):
            baseline = args.output_dir / f"{index}-{skip}-baseline.jpg"
            candidate = args.output_dir / f"{index}-{skip}-candidate.jpg"
            original_run = subprocess.run(ffmpeg_args(video, baseline, expected, skip, args.max_width, args.max_height, args.quality), capture_output=True)
            command = [args.vimg, "preview", "--output", str(candidate), "--skip", str(skip),
                       "--max-width", str(args.max_width), "--max-height", str(args.max_height),
                       "--quality", str(args.quality), "--", str(video)]
            if args.timings:
                command.insert(2, "--timings")
            completed = subprocess.run(command, capture_output=True, check=True)
            actual = json.loads(completed.stdout)
            assert actual.get("native_preview") is True, "This check requires an in-process-decode build"
            timing = None
            timing_lines = [line.removeprefix("vimg-preview-timing ")
                            for line in completed.stderr.decode(errors="replace").splitlines()
                            if line.startswith("vimg-preview-timing ")]
            if args.timings:
                assert len(timing_lines) == 1, completed.stderr
                timing = json.loads(timing_lines[0])
                assert timing["total_ms"] >= sum(value for _, value in timing["stages_ms"])
                if actual["preview_written"]:
                    phases = dict(timing["stages_ms"])
                    assert all(name in phases for name in ["open_header", "stream_info", "seek",
                               "read_decode", "filter_setup", "scale", "jpeg_encode", "publish", "input_release"])
                    assert timing["packets"] > 0
            else:
                assert not timing_lines, "Default preview must not emit timing diagnostics"
            assert probe_check.preview_fields(actual) == probe_check.preview_fields(expected), (video, actual)
            if not actual["preview_written"]:
                assert not candidate.exists(), "Fallback must not publish a partial image"
                fallback_run = subprocess.run(ffmpeg_args(video, candidate, actual, skip, args.max_width, args.max_height, args.quality), capture_output=True)
                assert fallback_run.returncode == original_run.returncode
            if not candidate.exists():
                assert not baseline.exists(), (video, "preview lost a usable fallback image")
                rows.append(dict(file=str(video), skip=skip, metadata=actual, timing=timing, no_image=True,
                                 baseline_exit=original_run.returncode, baseline_stderr=original_run.stderr.decode(errors="replace")))
                (args.output_dir / "results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
                print(f"{video.name} skip={skip}: matching no-image fallback", flush=True)
                continue
            if baseline.exists():
                assert original_run.returncode == 0
            original = image_hashes(baseline) if baseline.exists() else None
            new = image_hashes(candidate)
            assert 0 < new["width"] <= args.max_width and 0 < new["height"] <= args.max_height, (video, new)
            # For constant-resolution fixtures this also verifies autorotation,
            # aspect-ratio handling and the unchanged output-size policy.
            if original:
                if args.dynamic_resolution:
                    ratio = new["width"] / new["height"]
                    reference_ratio = original["width"] / original["height"]
                    assert abs(ratio - reference_ratio) <= .02, (video, original, new)
                else:
                    assert (new["width"], new["height"]) == (original["width"], original["height"]), (video, original, new)
            equal = original == new
            row = dict(file=str(video), skip=skip, metadata=actual, timing=timing, baseline=original,
                       candidate=new, image_identical=equal)
            rows.append(row)
            (args.output_dir / "results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
            if args.exact:
                assert equal, row
            print(f"{video.name} skip={skip}: valid JPEG; identical={equal}; native={actual['preview_written']}", flush=True)
    print(f"{len(rows)} comparisons passed; {sum(r['metadata']['preview_written'] for r in rows)} native")


if __name__ == "__main__":
    main()

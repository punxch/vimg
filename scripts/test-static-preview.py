"""Compare native static previews with gridthumb's FFmpeg command.

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
    rgb = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(path), "-frames:v", "1",
                                   "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    return {"jpeg": hashlib.sha256(data).hexdigest(), "rgb": hashlib.sha256(rgb).hexdigest(), "bytes": len(data)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vimg", default="vimg")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--max-width", default=600, type=int)
    parser.add_argument("--max-height", default=900, type=int)
    parser.add_argument("--quality", default=75, type=int)
    parser.add_argument("videos", nargs="+", type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    rows = []
    for index, video in enumerate(args.videos):
        video = video.resolve()
        expected = json.loads(subprocess.check_output(["ffprobe", "-v", "quiet", "-show_entries",
                              probe_check.ENTRIES, "-of", "json=c=1", str(video)]))
        for skip in (0, 45):
            baseline = args.output_dir / f"{index}-{skip}-baseline.jpg"
            candidate = args.output_dir / f"{index}-{skip}-candidate.jpg"
            original_run = subprocess.run(ffmpeg_args(video, baseline, expected, skip, args.max_width, args.max_height, args.quality), capture_output=True)
            command = [args.vimg, "preview", "--output", str(candidate), "--skip", str(skip),
                       "--max-width", str(args.max_width), "--max-height", str(args.max_height),
                       "--quality", str(args.quality), "--", str(video)]
            actual = json.loads(subprocess.check_output(command))
            assert actual.get("native_preview") is True, "This check requires an in-process-decode build"
            assert probe_check.preview_fields(actual) == probe_check.preview_fields(expected), (video, actual)
            if not actual["preview_written"]:
                assert not candidate.exists(), "Fallback must not publish a partial image"
                fallback_run = subprocess.run(ffmpeg_args(video, candidate, actual, skip, args.max_width, args.max_height, args.quality), capture_output=True)
                assert fallback_run.returncode == original_run.returncode
            if not baseline.exists():
                assert not candidate.exists(), (video, "native path produced a frame when baseline has none")
                rows.append(dict(file=str(video), skip=skip, metadata=actual, no_image=True,
                                 baseline_exit=original_run.returncode, baseline_stderr=original_run.stderr.decode(errors="replace")))
                (args.output_dir / "results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
                print(f"{video.name} skip={skip}: matching no-image fallback", flush=True)
                continue
            assert original_run.returncode == 0
            original, new = image_hashes(baseline), image_hashes(candidate)
            row = dict(file=str(video), skip=skip, metadata=actual, baseline=original, candidate=new)
            rows.append(row)
            (args.output_dir / "results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
            assert original == new, row
            print(f"{video.name} skip={skip}: identical JPEG/RGB; native={actual['preview_written']}", flush=True)
    print(f"{len(rows)} comparisons passed; {sum(r['metadata']['preview_written'] for r in rows)} native")


if __name__ == "__main__":
    main()

"""Compare native still decoders at the same selected frame; record pixel changes.

Requires ffmpeg/ffprobe on PATH. Both executables must support --timings. Validates
metadata, selected PTS, JPEG decoding and dimensions; pixel hashes/PSNR are evidence
for visual review rather than an exact-image requirement. Output directory is new.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess


def fixtures(root):
    cases = [("wpp-1080", "1920x1080", 1, 1, 4), ("wpp-4k", "3840x2160", 1, 1, 4),
             ("no-wpp", "1920x1080", 0, 1, 1), ("multi-slice", "1920x1080", 1, 4, 4),
             ("wpp-small", "320x180", 1, 1, 1), ("wpp-below", "1920x1078", 1, 1, 1)]
    expected = {f"decode-{name}.mkv": threads for name, _, _, _, threads in cases}
    manifest = root / "manifest.json"
    if manifest.exists():
        saved = json.loads(manifest.read_text())
        assert saved["version"] == 1 and set(saved["sha256"]) == set(expected)
        assert all(hashlib.sha256((root / name).read_bytes()).hexdigest() == value
                   for name, value in saved["sha256"].items())
    else:
        root.mkdir(parents=True, exist_ok=False)
        commands = []
        for name, dimensions, wpp, slices, _ in cases:
            command = ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", f"testsrc2=size={dimensions}:rate=24",
                       "-t", "3", "-pix_fmt", "yuv420p", "-c:v", "libx265", "-preset", "fast",
                       "-x265-params", f"pools=4:frame-threads=1:log-level=error:keyint=24:min-keyint=24:"
                       f"scenecut=0:open-gop=1:wpp={wpp}:slices={slices}", str(root / f"decode-{name}.mkv")]
            subprocess.run(command, check=True)
            commands.append(command)
        manifest.write_text(json.dumps(dict(version=1, commands=commands,
                            sha256={name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                                    for name in expected}), indent=2))
    return [root / name for name in expected], expected


def run(exe, video, output, skip):
    p = subprocess.run([str(exe), "preview", "--timings", "--output", str(output),
                        "--skip", str(skip), "--max-width", "600", "--max-height", "900",
                        "--quality", "75", "--", str(video)], capture_output=True, check=True, timeout=30)
    meta = json.loads(p.stdout)
    assert meta["native_preview"] and meta["preview_written"], (video, meta)
    timings = [json.loads(line.split(" ", 1)[1]) for line in p.stderr.decode(errors="replace").splitlines()
               if line.startswith("vimg-preview-timing ")]
    assert len(timings) == 1, p.stderr
    return meta, timings[0]


def image(path):
    jpeg = path.read_bytes()
    assert jpeg.startswith(b"\xff\xd8") and jpeg.endswith(b"\xff\xd9"), path
    data = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                     "-show_entries", "stream=width,height", "-of", "json", str(path)]))
    width, height = (data["streams"][0][key] for key in ["width", "height"])
    rgb = subprocess.check_output(["ffmpeg", "-v", "error", "-xerror", "-err_detect", "explode",
                                  "-i", str(path), "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    assert 0 < width <= 600 and 0 < height <= 900
    assert len(rgb) == width * height * 3
    return dict(jpeg=hashlib.sha256(jpeg).hexdigest(), rgb=hashlib.sha256(rgb).hexdigest(),
                width=width, height=height, bytes=len(jpeg)), rgb


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--fixtures", type=Path, help="Generate/reuse WPP, no-WPP, multi-slice and size-boundary fixtures (requires libx265)")
    parser.add_argument("--skip", action="append", type=int)
    parser.add_argument("--expect-threads", action="append", default=[], metavar="BASENAME=COUNT",
                        help="Assert the actual candidate decoder thread count for this input")
    parser.add_argument("videos", nargs="*", type=Path)
    args = parser.parse_args()
    expected_threads = {}
    if args.fixtures:
        generated, expected_threads = fixtures(args.fixtures)
        args.videos.extend(generated)
    if not args.videos:
        parser.error("Provide videos or --fixtures")
    for item in args.expect_threads:
        name, count = item.rsplit("=", 1)
        expected_threads[name] = int(count)
    assert set(expected_threads) <= {video.name for video in args.videos}, "Unknown --expect-threads input"
    args.output_dir.mkdir(parents=True, exist_ok=False)
    rows = []
    for index, video in enumerate(args.videos):
        video = video.resolve()
        for skip in args.skip if args.skip is not None else (0, 45, 90):
            outputs = {arm: args.output_dir / f"{index}-{skip}-{arm}.jpg" for arm in ["baseline", "candidate"]}
            baseline, before = run(args.baseline.resolve(), video, outputs["baseline"], skip)
            candidate, after = run(args.candidate.resolve(), video, outputs["candidate"], skip)
            assert baseline == candidate, (video, skip, baseline, candidate)
            for key in ["target_pts", "selected_pts", "seek_mode", "attempts"]:
                assert before[key] == after[key], (video, skip, key, before, after)
            if video.name in expected_threads:
                assert after["decoder_threads"] == expected_threads[video.name], (video, after)
            a, rgb_a = image(outputs["baseline"])
            b, rgb_b = image(outputs["candidate"])
            assert (a["width"], a["height"]) == (b["width"], b["height"]), (video, skip, a, b)
            if args.fixtures and video.name in {"decode-wpp-small.mkv", "decode-wpp-below.mkv", "decode-no-wpp.mkv"}:
                assert after["skip_loop_filter"] is False and rgb_a == rgb_b, (video, skip, after)
            if candidate["streams"][0]["codec_name"] == "h264":
                assert after["skip_loop_filter"] is False and after["decoder_threads"] == 1
                assert a == b, (video, skip, "H.264 policy must remain unchanged")
            absolute = [abs(x-y) for x,y in zip(rgb_a, rgb_b)]
            mse = sum(d*d for d in absolute) / len(absolute)
            row = dict(file=str(video), skip=skip, metadata=candidate, baseline=a, candidate=b,
                       before=before, after=after, mean_absolute_error=sum(absolute)/len(absolute),
                       max_channel_error=max(absolute), psnr_db=10*math.log10(255*255/mse) if mse else None,
                       pixel_identical=rgb_a==rgb_b, outputs={k:str(v.resolve()) for k,v in outputs.items()})
            rows.append(row)
            (args.output_dir / "results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
            print(f"{video.name} skip={skip}: PTS={after['selected_pts']} threads={after.get('decoder_threads')} "
                  f"MAE={row['mean_absolute_error']:.3f} PSNR={row['psnr_db']}", flush=True)
    print(f"{len(rows)} same-frame comparisons passed; pixel differences recorded for visual review")


if __name__ == "__main__":
    main()

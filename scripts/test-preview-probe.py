"""Compare vimg probe's preview metadata against the installed ffprobe.

Example: python scripts/test-preview-probe.py --vimg target/release/vimg.exe sample/input.mkv
The native build needs its libav shared libraries on the loader search path.
"""
import argparse
import json
from pathlib import Path
import subprocess

ENTRIES = (
    "format=duration:stream=codec_name,codec_type,width,height,time_base:"
    "stream_disposition=attached_pic"
)


def preview_fields(metadata):
    """Only fields consumed by the plugin, including every video stream."""
    return {
        "duration": metadata.get("format", {}).get("duration"),
        "streams": [
            {key: stream.get(key) for key in (
                "codec_type", "codec_name", "width", "height", "time_base", "disposition"
            )}
            for stream in metadata.get("streams", [])
            if stream.get("codec_type") == "video"
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vimg", default="vimg")
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--output", type=Path)
    parser.add_argument("videos", nargs="+", type=Path)
    args = parser.parse_args()
    results = []
    for video in args.videos:
        baseline = json.loads(subprocess.check_output([
            args.ffprobe, "-v", "quiet", "-show_entries", ENTRIES,
            "-of", "json=c=1", str(video.resolve()),
        ]))
        candidate = json.loads(subprocess.check_output([
            args.vimg, "probe", "--", str(video.resolve()),
        ]))
        expected, actual = preview_fields(baseline), preview_fields(candidate)
        if actual != expected:
            raise AssertionError(f"{video}: metadata mismatch\nexpected={expected}\nactual={actual}")
        results.append({"file": str(video.resolve()), "metadata": actual})
        print(f"{video.name}: duration, all video streams and cover flags match", flush=True)
    if args.output:
        args.output.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(f"{len(results)} metadata comparisons passed")


if __name__ == "__main__":
    main()

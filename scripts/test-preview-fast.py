"""Exercise fast preview seek/drain policies with reproducible local video fixtures.

Requires ffmpeg/libx264/libx265 and ffprobe on PATH. Reuses a fixture directory
only when its manifest hashes still match. Output directories must be new.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zlib

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def vint(data, pos, ident=False):
    size = 1
    while size <= 8 and not data[pos] & (1 << (8 - size)):
        size += 1
    assert size <= 8
    value = int.from_bytes(data[pos:pos + size], "big")
    return (value if ident else value & ((1 << (7 * size)) - 1)), size


def elements(data, start, end):
    pos = start
    while pos < end:
        ident, n = vint(data, pos, True)
        size, m = vint(data, pos + n)
        payload, finish = pos + n + m, pos + n + m + size
        assert finish <= end, (pos, size, end)
        yield ident, pos, payload, finish
        pos = finish


def children(data, parent):
    return list(elements(data, parent[2], parent[3]))


def crc(data, parent):
    fields = children(data, parent)
    field = next((f for f in fields if f[0] == 0xbf), None)
    if field:
        assert field[1] == parent[2] and field[3] - field[2] == 4
        data[field[2]:field[3]] = zlib.crc32(data[field[3]:parent[3]]).to_bytes(4, "little")


def mkv_variant(source, output, mode):
    data = bytearray(source.read_bytes())
    segment = next(f for f in elements(data, 0, len(data)) if f[0] == 0x18538067)
    fields = children(data, segment)
    changed = 0
    if mode == "sparse":
        cues = next(f for f in fields if f[0] == 0x1c53bb6b)
        points = [f for f in children(data, cues) if f[0] == 0xbb]
        assert len(points) == 3
        data[points[1][1]] = 0xec  # equal-size Void: video and all offsets stay unchanged
        crc(data, cues)
        changed = 1
    else:
        for cluster in [f for f in fields if f[0] == 0x1f43b675]:
            for block in [f for f in children(data, cluster) if f[0] == 0xa3]:
                _, n = vint(data, block[2])
                flags = data[block[2] + n + 2]
                assert flags & 6 == 0, "fixture must not use lacing"
                pos = block[2] + n + 3
                while pos < block[3]:
                    size = int.from_bytes(data[pos:pos + 4], "big")
                    pos += 4
                    assert size > 0 and pos + size <= block[3]
                    if mode == "bla" and (data[pos] >> 1) & 0x3f == 21:
                        # CRA and BLA both carry the non-IDR slice-header layout.
                        data[pos] = (16 << 1) | (data[pos] & 1)
                        changed += 1
                    elif mode == "corrupt" and data[pos] & 31 == 5:
                        data[pos + 1:pos + size] = b"\xff" * (size - 1)
                        changed += 1
                    pos += size
            crc(data, cluster)
    assert changed > 0, mode
    output.write_bytes(data)


def fixtures(root):
    manifest = root / "manifest.json"
    if manifest.exists():
        hashes = json.loads(manifest.read_text())
        assert all(digest(root / name) == value for name, value in hashes.items())
        return
    root.mkdir(parents=True, exist_ok=False)

    def generate(name, codec, dimensions, seconds, params):
        args = ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", f"testsrc2=size={dimensions}:rate=24",
                "-t", str(seconds), "-c:v", codec, "-threads", "4", "-pix_fmt", "yuv420p"]
        if codec == "libx265":
            args += ["-preset", "ultrafast", "-x265-params", "pools=4:frame-threads=1:log-level=error:" + params]
        else:
            args += ["-x264-params", params]
        subprocess.run([*args, str(root / name)], check=True)

    generate("closed.mkv", "libx264", "320x180", 24, "keyint=240:min-keyint=240:scenecut=0:bframes=8")
    mkv_variant(root / "closed.mkv", root / "sparse.mkv", "sparse")
    mkv_variant(root / "closed.mkv", root / "corrupt.mkv", "corrupt")
    for name, gop in [("hevc-idr.mkv", 0), ("hevc-cra.mkv", 1)]:
        generate(name, "libx265", "320x180", 12, f"keyint=96:min-keyint=96:scenecut=0:bframes=4:open-gop={gop}")
    mkv_variant(root / "hevc-cra.mkv", root / "hevc-bla.mkv", "bla")
    generate("hevc-1080.mkv", "libx265", "1920x1080", 12, "keyint=96:min-keyint=96:scenecut=0:open-gop=1")
    generate("hevc-4k.mkv", "libx265", "3840x2160", 4, "keyint=48:min-keyint=48:scenecut=0:open-gop=1")
    for name, dimensions in [("part-a.mkv", "320x180"), ("part-b.mkv", "640x360")]:
        generate(name, "libx264", dimensions, 6, "keyint=48:min-keyint=48:scenecut=0:repeat-headers=1")
    (root / "concat.txt").write_text("file 'part-a.mkv'\nfile 'part-b.mkv'\n")
    subprocess.run(["ffmpeg", "-v", "error", "-f", "concat", "-safe", "0", "-i", str(root / "concat.txt"),
                    "-c", "copy", str(root / "changing.mkv")], check=True)
    manifest.write_text(json.dumps({p.name: digest(p) for p in root.iterdir() if p.is_file()}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vimg", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    fixtures(args.fixtures)
    args.output_dir.mkdir(parents=True, exist_ok=False)
    videos = [args.fixtures / name for name in ["closed.mkv", "sparse.mkv", "hevc-idr.mkv", "hevc-cra.mkv",
                                               "hevc-bla.mkv", "hevc-1080.mkv", "hevc-4k.mkv"]]
    subprocess.run([sys.executable, "-B", "-X", "utf8", str(Path(__file__).with_name("test-static-preview.py")),
                    "--vimg", str(args.vimg), "--timings", "--output-dir", str(args.output_dir / "images"),
                    "--skip", "5", "--skip", "45", "--skip", "90", *map(str, videos)], check=True)
    rows = json.loads((args.output_dir / "images/results.json").read_text())
    subprocess.run([sys.executable, "-B", "-X", "utf8", str(Path(__file__).with_name("test-static-preview.py")),
                    "--vimg", str(args.vimg), "--timings", "--dynamic-resolution", "--output-dir", str(args.output_dir / "changing"),
                    "--skip", "5", "--skip", "45", "--skip", "90", str(args.fixtures / "changing.mkv")], check=True)
    rows += json.loads((args.output_dir / "changing/results.json").read_text())
    by_key = {(Path(r["file"]).name, r["skip"]): r for r in rows}
    for kind in ["idr", "cra", "bla"]:
        row = by_key[(f"hevc-{kind}.mkv", 5)]
        assert row["metadata"]["preview_written"] and row["timing"]["drain_kind"] == f"hevc_{kind}", row
        assert row["timing"]["packets"] == 1, row
    sparse = by_key[("sparse.mkv", 5)]
    assert sparse["timing"]["selected_pts"] == 20000 and not sparse["image_identical"], sparse
    tail = by_key[("closed.mkv", 90)]
    assert tail["metadata"]["preview_written"] and tail["timing"]["seek_mode"] == "backward", tail
    assert tail["timing"]["attempts"] == 2 and tail["timing"]["selected_pts"] < tail["timing"]["target_pts"], tail
    # An invalid bitstream must not replace an already published cache.
    cache = args.output_dir / "preserved.jpg"
    cache.write_bytes(b"existing cache")
    p = subprocess.run([str(args.vimg), "preview", "--output", str(cache), str(args.fixtures / "corrupt.mkv")], capture_output=True)
    assert p.returncode != 0 or not json.loads(p.stdout)["preview_written"], p.stdout
    assert cache.read_bytes() == b"existing cache"
    assert not list(args.output_dir.glob(".vimg-preview-*.tmp"))
    print("24 image cases and fast-seek/HEVC/corruption contracts passed", flush=True)


if __name__ == "__main__":
    main()

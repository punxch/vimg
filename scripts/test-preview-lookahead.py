"""Exercise bounded H.264 keyframe lookahead through real native previews.

Requires ffmpeg/libx264 and ffprobe on PATH. Fixtures are hash-checked on reuse.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fixtures(root):
    manifest = root / "manifest.json"
    if manifest.exists():
        saved = json.loads(manifest.read_text())
        expected = {"smaller.mkv", "smaller.mp4", "similar.mkv", "distant.mkv", "inband.mkv"}
        assert set(saved) == expected, "Use a new fixture directory for this fixture version"
        assert all(digest(root / n) == h for n, h in saved.items())
        return
    root.mkdir(parents=True, exist_ok=False)
    for name, noise, gop, duration in [
        ("smaller.mkv", "noise=alls=80:allf=t:all_seed=27:enable='lt(t,2)'", 8, 6),
        ("inband.mkv", "noise=alls=80:allf=t:all_seed=27:enable='lt(t,2)'", 8, 6),
        ("similar.mkv", "noise=alls=80:allf=t:all_seed=27", 8, 6),
        ("distant.mkv", "noise=alls=80:allf=t:all_seed=27:enable='lt(t,2)'", 24, 8),
    ]:
        params = (f"cabac=1:keyint={gop}:min-keyint={gop}:scenecut=0:bframes=2:slices=1:"
                  f"repeat-headers={int(name == 'inband.mkv')}")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                        f"testsrc2=size=1280x720:rate=4:duration={duration}", "-vf", noise,
                        "-c:v", "libx264", "-preset", "ultrafast", "-qp", "18", "-threads", "1",
                        "-x264-params", params,
                        str(root / name)], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-i", str(root / "smaller.mkv"), "-c", "copy",
                    str(root / "smaller.mp4")], check=True)
    manifest.write_text(json.dumps({p.name: digest(p) for p in root.iterdir() if p.is_file()}, indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--vimg", required=True, type=Path)
    p.add_argument("--fixtures", required=True, type=Path)
    p.add_argument("--output-dir", required=True, type=Path)
    a = p.parse_args()
    fixtures(a.fixtures)
    a.output_dir.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("fast_preview", Path(__file__).with_name("test-preview-fast.py"))
    fast = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fast)
    # Damage only the next IDR, preserving the original frame and all Cues.
    # One case fails the NAL check; the other reaches the decoder's error path.
    for mode in ["truncated", "corrupt"]:
        data = bytearray((a.fixtures / "smaller.mkv").read_bytes())
        segment = next(f for f in fast.elements(data, 0, len(data)) if f[0] == 0x18538067)
        count = 0
        for cluster in [f for f in fast.children(data, segment) if f[0] == 0x1f43b675]:
            for block in [f for f in fast.children(data, cluster) if f[0] == 0xa3]:
                _, n = fast.vint(data, block[2])
                assert data[block[2] + n + 2] & 6 == 0
                pos = block[2] + n + 3
                while pos < block[3]:
                    size = int.from_bytes(data[pos:pos + 4], "big")
                    assert size > 0 and pos + 4 + size <= block[3]
                    if data[pos + 4] & 31 == 5:
                        count += 1
                        if count == 2:
                            if mode == "truncated":
                                data[pos:pos + 4] = (size + 1).to_bytes(4, "big")
                            else:
                                assert size > 32
                                data[pos + 20:pos + 4 + size] = b"\xff" * (size - 16)
                    pos += 4 + size
            fast.crc(data, cluster)
        assert count == 3
        (a.output_dir / f"{mode}.mkv").write_bytes(data)
    rows = []
    for name, skip, expected_seconds, replaced in [
        ("smaller.mkv", 0, 2, True), ("smaller.mp4", 0, 2, True),
        ("similar.mkv", 0, 0, False), ("distant.mkv", 0, 0, False),
        ("smaller.mkv", 90, 4, False),
        ("truncated.mkv", 0, 0, False), ("corrupt.mkv", 0, 0, False),
        ("inband.mkv", 0, 0, False),
    ]:
        video = (a.output_dir if name in ["truncated.mkv", "corrupt.mkv"] else a.fixtures) / name
        output = a.output_dir / f"{name}-{skip}.jpg"
        proc = subprocess.run([str(a.vimg), "preview", "--timings", "--skip", str(skip),
                               "--output", str(output), str(video)], capture_output=True, check=True)
        metadata = json.loads(proc.stdout)
        timing = [json.loads(line.split(" ", 1)[1]) for line in proc.stderr.decode().splitlines()
                  if line.startswith("vimg-preview-timing ")]
        assert metadata["preview_written"] and len(timing) == 1, proc.stderr
        timing = timing[0]
        probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                           "-show_entries", "stream=time_base", "-of", "json", str(video)]))
        num, den = map(int, probe["streams"][0]["time_base"].split("/"))
        seconds = timing["selected_pts"] * num / den
        subprocess.run(["ffmpeg", "-v", "error", "-err_detect", "explode", "-xerror", "-i", str(output),
                        "-f", "null", "-"], check=True, capture_output=True)
        image = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries",
                           "stream=width,height", "-of", "json", str(output)]))["streams"][0]
        assert (image["width"], image["height"]) == (600, 338), image
        row = dict(file=name, skip=skip, metadata=metadata, timing=timing, selected_seconds=seconds,
                   sha256=digest(output))
        rows.append(row)
        (a.output_dir / "results.json").write_text(json.dumps(rows, indent=2))
        assert seconds == expected_seconds, row
        assert timing.get("lookahead_selected", False) == replaced, row
        if replaced:
            assert timing["lookahead_packets"] == 1 and timing["packets"] == 2, row
            assert timing["selected_packet_bytes"] <= timing["first_key_bytes"] // 2, row
        if name in ["distant.mkv", "inband.mkv"] or skip == 90:
            assert timing["lookahead_packets"] == 0, row
        if name in ["truncated.mkv", "corrupt.mkv"]:
            assert timing["lookahead_packets"] == 1, row
        if name == "corrupt.mkv":
            assert timing["attempts"] == 2 and timing["seek_mode"] == "backward", row
    assert not list(a.output_dir.glob(".vimg-preview-*.tmp"))
    print("Bounded lookahead: eight selection, configuration and damaged-candidate cases passed")


if __name__ == "__main__":
    main()

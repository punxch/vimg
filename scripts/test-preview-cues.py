"""Exercise the large Matroska video-index fast path through real previews."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command):
    p = subprocess.run([str(x) for x in command], capture_output=True, check=True)
    return p.stdout, p.stderr


def variants(directory, source):
    spec = importlib.util.spec_from_file_location('preview_fast', Path(__file__).with_name('test-preview-fast.py'))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    original = source.read_bytes()
    segment = next(f for f in helper.elements(original, 0, len(original)) if f[0] == 0x18538067)
    fields = helper.children(original, segment)
    cues = next(f for f in fields if f[0] == 0x1c53bb6b)
    points = [f for f in helper.children(original, cues) if f[0] == 0xbb]
    video = []
    for point in points:
        children = helper.children(original, point)
        timestamp = next(f for f in children if f[0] == 0xb3)
        for pos in [f for f in children if f[0] == 0xb7]:
            values = helper.children(original, pos)
            track = next(f for f in values if f[0] == 0xf7)
            if int.from_bytes(original[track[2]:track[3]], 'big') == 1:
                position = next(f for f in values if f[0] == 0xf1)
                video.append((timestamp, position, pos, point))
    assert len(points) >= 2048 and len(video) >= 5
    for name in ('sparse', 'mismatched-first', 'duplicate-time', 'no-cue-seek', 'unknown-segment', 'few-points'):
        data = bytearray(original)
        if name == 'sparse':
            data[video[3][2][1]] = 0xec
        elif name == 'mismatched-first':
            field = video[0][1]
            value = int.from_bytes(data[field[2]:field[3]], 'big') + 1
            data[field[2]:field[3]] = value.to_bytes(field[3] - field[2], 'big')
        elif name == 'duplicate-time':
            prior, current = video[2][0], video[3][0]
            value = int.from_bytes(data[prior[2]:prior[3]], 'big')
            data[current[2]:current[3]] = value.to_bytes(current[3] - current[2], 'big')
        elif name == 'no-cue-seek':
            seek = next(f for f in fields if f[0] == 0x114d9b74)
            for entry in helper.children(data, seek):
                if entry[0] != 0x4dbb:
                    continue
                field = next(f for f in helper.children(data, entry) if f[0] == 0x53ab)
                if int.from_bytes(data[field[2]:field[3]], 'big') == 0x1c53bb6b:
                    data[field[3] - 1] ^= 1
            helper.crc(data, seek)
        elif name == 'unknown-segment':
            _, width = helper.vint(data, segment[1] + 4)
            data[segment[1] + 4:segment[2]] = ((1 << (width * 7 + 1)) - 1).to_bytes(width, 'big')
        elif name == 'few-points':
            for point in points:
                if point not in (video[0][3], video[-1][3]):
                    data[point[1]] = 0xec
        helper.crc(data, cues)
        (directory / (name + '.mkv')).write_bytes(data)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--vimg', type=Path, required=True)
    p.add_argument('--baseline', type=Path)
    p.add_argument('--fixtures', type=Path, required=True)
    p.add_argument('--output-dir', type=Path, required=True)
    a = p.parse_args()
    a.output_dir.mkdir(exist_ok=False)
    a.fixtures.mkdir(exist_ok=True)
    video = a.fixtures / 'many-cues.mkv'
    manifest = a.fixtures / 'manifest.json'
    if manifest.exists():
        expected = json.loads(manifest.read_text())
        assert set(expected) == {'dense.srt', 'many-cues.mkv', 'sparse.mkv', 'mismatched-first.mkv',
                                'duplicate-time.mkv', 'no-cue-seek.mkv', 'unknown-segment.mkv', 'few-points.mkv'}
        assert all(digest(a.fixtures / name) == sha for name, sha in expected.items()), 'Fixture changed'
    else:
        assert not video.exists(), 'Use a new fixture directory or a verified manifest'
        subtitle = a.fixtures / 'dense.srt'
        def timestamp(ms):
            return f'00:00:{ms // 1000:02},{ms % 1000:03}'
        subtitle.write_text(''.join(f'{i+1}\n{timestamp(i*4)} --> {timestamp(i*4+3)}\nCue {i}\n\n'
                                    for i in range(3000)), encoding='utf-8')
        run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24',
             '-i', subtitle, '-map', '0:v', *['-map', '1:s'] * 8, '-c:v', 'libx264',
             '-preset', 'ultrafast', '-x264-params', 'keyint=48:min-keyint=48:scenecut=0',
             '-c:s', 'srt', '-t', '12', video])
        variants(a.fixtures, video)
        files = sorted(a.fixtures.glob('*.mkv')) + [subtitle]
        manifest.write_text(json.dumps({file.name: digest(file) for file in files}, indent=2))
    result = []
    cases = [('many-cues', skip, True) for skip in (0, 45, 90)]
    cases += [('sparse', 45, True), ('unknown-segment', 45, True)]
    cases += [(name, 45, False) for name in ('mismatched-first', 'duplicate-time', 'no-cue-seek', 'few-points')]
    for name, skip, fast in cases:
        source = (a.fixtures / (name + '.mkv')).resolve()
        output = a.output_dir / f'{name}-{skip}.jpg'
        out, err = run([a.vimg.resolve(), 'preview', '--timings', '--skip', skip, '--output', output, source])
        meta = json.loads(out)
        timing = [json.loads(s.split(' ', 1)[1]) for s in err.decode().splitlines()
                  if s.startswith('vimg-preview-timing ')][0]
        assert meta['preview_written'], (meta, err)
        assert (timing.get('cue_index_entries', 0) > 0) == fast, (name, timing)
        run(['ffmpeg', '-v', 'error', '-xerror', '-err_detect', 'explode', '-i', output, '-frames:v', '1', '-f', 'null', '-'])
        if a.baseline:
            before = a.output_dir / f'{name}-{skip}-baseline.jpg'
            old, _ = run([a.baseline.resolve(), 'preview', '--skip', skip, '--output', before, source])
            assert json.loads(old) == meta, (name, 'Metadata changed')
            assert digest(before) == digest(output), (name, 'Selected frame changed')
        result.append(dict(name=name, skip=skip, metadata=meta, timing=timing, sha256=digest(output)))
    (a.output_dir / 'results.json').write_text(json.dumps(result, indent=2))
    assert not list(a.output_dir.glob('.vimg-preview-*.tmp'))
    print('Large Matroska Cues: nine selection, layout and conservative fallback cases passed')


if __name__ == '__main__':
    main()

import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/avif_animation.dart';
import 'package:vimg_dart/src/capture.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _cfr = 'test/fixtures/timing-cfr.avi';
const _vfr = 'test/fixtures/timing-vfr.mov';
const _ntsc = 'test/fixtures/timing-ntsc.mkv';
const _h264 = 'test/fixtures/cabac-b-spatial.mkv';
const _trimAndRebase = 'trim=start=0.25:end=0.875,setpts=PTS-STARTPTS';
const _mixed =
    'settb=AVTB,trim=start_pts=125000,setpts=(PTS-STARTPTS)*0.75,fps=7';
const _mixedCfr = '6,8,9,11,12,12|17,19,20,22,23,23|25,27,28,30,31,31';

// Source IDs from FFmpeg 8.1.2 with input -ss and -t followed by -vf,
// -r and -fps_mode cfr. The frame-ID fixtures encode each ID in red.
// When FFmpeg reaches EOF early, vimg repeats its last emitted frame.
const _oracle = [
  (_cfr, _trimAndRebase, '7,8,9,10,11,11|18,19,20,21,22,22|26,27,28,29,30,30'),
  (
    _cfr,
    'trim=start_pts=3:start_frame=1:end_pts=3:end_frame=5',
    '6,6,7,8,9,9|17,17,18,19,20,20|25,25,26,27,28,28',
  ),
  (
    _cfr,
    r"trim=start='00\:00\:00.25':duration=250000us",
    '7,7,8,8,8,8|18,18,19,19,19,19|26,26,27,27,27,27',
  ),
  (
    _cfr,
    'fps=12/5:round=down:eof_action=pass',
    '8,8,11,11,11,12|19,19,22,22,22,23|27,27,30,30,30,31',
  ),
  (_cfr, _mixed, _mixedCfr),
  (
    _vfr,
    'fps=source_fps/2',
    '7,7,7,8,8,10|16,16,17,19,19,20|26,26,27,29,29,30',
  ),
  (
    _vfr,
    "setpts='if(isnan(PREV_OUTPTS),0,PREV_OUTPTS+2)'",
    '6,7,8,8,8,8|16,17,20,20,20,20|26,26,29,29,29,29',
  ),
  (
    _vfr,
    'setpts=2*PTS:strip_fps=1',
    '6,6,7,7,8,8|16,17,17,17,18,19|26,26,27,27,28,29',
  ),
  (_vfr, _mixed, '6,8,8,10,11,11|17,18,19,20,21,21|27,29,29,31,31,31'),
  (
    _ntsc,
    'fps=source_fps/2',
    '16,19,20,22,26,30|48,51,52,54,58,62|73,75,77,79,83,87',
  ),
  (
    _ntsc,
    'settb=tb=intb*2,setpts=N/(FR*TB)',
    '16,17,19,23,27,31|48,49,51,55,59,63|73,74,76,80,84,88',
  ),
  (
    _ntsc,
    'fps=8:start_time=0.1875:round=up,fps=5:round=inf:eof_action=pass',
    '23,23,23,23,26,32|55,55,55,55,58,64|79,79,79,79,82,88',
  ),
  (
    _h264,
    'trim=start_frame=1,setpts=(PTS-STARTPTS)*1.25,fps=7',
    '4,5,6,7,7,8,9,9,10,11,12,13|6,7,8,9,9,10,11,11,12,13,14,15|6,7,8,9,9,10,11,11,12,13,14,15',
  ),
];

Future<void> main(List<String> arguments) async {
  for (final (path, filters, expected) in _oracle) {
    _checkSelection(path, filters, expected);
  }
  for (final invalid in [
    'trim=duration=-0.25',
    'trim=start_frame=-2',
    'trim=start=1.2frames',
    'fps=6:round=nearest',
    'fps=6:eof_action=unknown',
    'setpts=unknown',
    'setpts=PTS:strip_fps=never',
  ]) {
    try {
      VideoFilterChain.parse(invalid);
    } on FormatException {
      continue;
    }
    throw StateError('Accepted invalid filter $invalid');
  }
  await _checkCli(arguments.firstOrNull);
}

void _checkSelection(String path, String filters, String expected) {
  final video = Video(path);
  try {
    final plan = CapturePlan(
      video.metadata.duration,
      CaptureOptions(
        number: 3,
        frames: path == _h264 ? 12 : 6,
        window: path == _h264 ? 1.5 : 1,
      ),
    );
    final stream = video.metadata.streams.firstWhere(
      (stream) => !stream.attached,
    );
    final [numerator, denominator] = stream.timeBase
        .split('/')
        .map(int.parse)
        .toList();
    final packets = video.packets().toList();
    final source = List.generate(3, (_) => <int>[]);
    final selected = plan.selectFiltered(
      packets,
      VideoFilterChain.parse(filters).filterTiming,
      timeBase: (numerator: numerator, denominator: denominator),
      frameRate: stream.nominalFrameRate,
      onSelect: (frame, capture, packet, index) {
        check(
          frame == source[capture].length,
          'Chronological output per capture',
        );
        check(
          packet == packets[index],
          'Original packet and timestamp retained',
        );
        source[capture].add(index);
      },
    );
    final actual = source.map((window) => window.join(',')).join('|');
    check(actual == expected, '$path $filters selected $actual');
    for (final (index, frames) in selected.indexed) {
      check(
        frames.length == plan.frames,
        'Each window has the requested length',
      );
      for (final (frame, packet) in frames.indexed) {
        check(
          packet == packets[source[index][frame]],
          'Reported source identity',
        );
      }
    }
  } finally {
    video.close();
  }
}

Future<void> _checkCli(String? executable) async {
  final temp = Directory.systemTemp.createTempSync('vimg-timing-filters-');
  Future<ProcessResult> run(List<String> args, {bool ok = true}) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...args],
    );
    check((result.exitCode == 0) == ok, '$args: ${result.stderr}');
    return result;
  }

  try {
    const capture = ['-n3', '-f6', '-t1s'];
    const chain = '$_mixed,crop=6:4:1:1,hflip';
    final captures = '${temp.path}/captures';
    final kept = '${temp.path}/kept';
    final sheet = '${temp.path}/sheet.avif';
    await run([
      'extract',
      ...capture,
      '-T4',
      '--output-dir',
      captures,
      '--vfilter',
      chain,
      _cfr,
    ]);
    await run([
      'vcs',
      '-c2',
      '-H8',
      ...capture,
      '-T1',
      '--keep',
      '--output-dir',
      kept,
      '--vfilter',
      chain,
      '-o',
      sheet,
      _cfr,
    ]);
    final expected = _mixedCfr.split('|');
    for (final (window, second) in [0, 2, 3].indexed) {
      for (final (frame, id) in expected[window].split(',').indexed) {
        final name = 'timing-cfr-${second}s-${frame + 1}.bmp';
        final file = File('$captures/$name').readAsBytesSync();
        final bmp = image.decodeBmp(file)!;
        final pixel = bmp.getPixel(0, 0);
        check(bmp.width == 6 && bmp.height == 4, 'Filtered BMP dimensions');
        check(
          pixel.r == int.parse(id) * 7 && pixel.g == 138 && pixel.b == 31,
          'Temporal source and crop/flip pixels in $name',
        );
        final saved = File('$kept/$name').readAsBytesSync();
        check(
          file.length == saved.length &&
              file.indexed.every((entry) => saved[entry.$1] == entry.$2),
          'Contact sheet and extract use the same filtered frame',
        );
      }
    }
    final animation = AvifAnimation.open(sheet);
    try {
      check(
        animation.width == 24 && animation.height == 16,
        'Filtered grid geometry',
      );
      check(
        animation.frameCount == 6 && animation.decodeFrames().length == 6,
        'Filtered AVIF',
      );
    } finally {
      animation.close();
    }

    final empty = '${temp.path}/empty';
    final error = await run([
      'extract',
      ...capture,
      '--output-dir',
      empty,
      '--vfilter',
      'trim=end_frame=0',
      _cfr,
    ], ok: false);
    check(
      (error.stderr as String).contains(
            'Video filters produced no frames for capture 1',
          ) &&
          !Directory(empty).existsSync(),
      'Empty timeline fails before writing captures',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

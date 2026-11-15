import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _avc = 'test/fixtures/cabac-b-spatial.mkv';
const _hevc = 'test/fixtures/hevc-main10.mp4';
const _anamorphic = 'test/fixtures/cabac-anamorphic.mp4';
const _chain =
    "crop=120:80:8:4,transpose=clock,pad='max(iw,ih)+8':ow:-1:-1:aliceblue,"
    'drawbox=3:7:24:35:yellow@0x80:fill,negate';

Future<void> main(List<String> arguments) async {
  _checkColorAndAlpha();
  _checkOracle();
  _checkErrors();
  if (arguments.isNotEmpty) await _checkCommands(arguments.single);
}

void _checkColorAndAlpha() {
  final source = image.Image(width: 8, height: 6, numChannels: 4)
    ..clear(image.ColorRgba8(25, 70, 160, 92));

  image.Image filter(String chain) =>
      YuvImageScaler(filters: VideoFilterChain.parse(chain)).filterRgb(source);

  final padded = filter('pad=12:10:-1:-1:0x11223344');
  check(padded.width == 12 && padded.height == 10, 'Centered RGB padding');
  _pixel(padded, 0, 0, 17, 34, 51, 68);
  _pixel(padded, 2, 2, 25, 70, 160, 92);
  _pixel(padded, 9, 7, 25, 70, 160, 92);
  _pixel(padded, 10, 8, 17, 34, 51, 68);

  final replaced = filter('drawbox=2:1:4:3:0x10203040:fill:1');
  _pixel(replaced, 2, 1, 16, 32, 48, 64);
  _pixel(replaced, 0, 0, 25, 70, 160, 92);
  final blended = filter('drawbox=2:1:4:3:red@0.5:fill');
  _pixel(blended, 2, 1, 139, 35, 80, 92);
  final inverted = filter('drawbox=2:1:4:3:invert:1');
  _pixel(inverted, 2, 1, 230, 185, 95, 92);
  _pixel(inverted, 3, 2, 25, 70, 160, 92);

  final negated = filter('negate=components=b+a');
  _pixel(negated, 4, 4, 25, 70, 95, 163);
  final gray = filter(
    'setdar=16/9,crop=4:6:2:0:keep_aspect=1,pad=aspect=2:x=-1',
  );
  check(
    gray.width == 5 && gray.height == 6,
    'Preserve display aspect through crop',
  );
  _pixel(source, 2, 1, 25, 70, 160, 92);
}

void _pixel(image.Image frame, int x, int y, int r, int g, int b, int a) {
  final pixel = frame.getPixel(x, y);
  check((pixel.r, pixel.g, pixel.b, pixel.a) == (r, g, b, a), 'RGBA at $x,$y');
}

void _checkOracle() {
  // FFmpeg 8.1 filtered planar frames. The 8-bit cases use the unscaled
  // Dart renderer's RGB matrix and nearest chroma placement. The 10-bit
  // cases use FFmpeg's RGB24 output after filtering.
  for (final (file, filters, index, width, height, expected) in [
    (_avc, 'pad=iw+16:ih+12:-1:-1:navy', 8, 182, 122, 0xb79aded9),
    (_avc, 'drawbox=-3:5:37:29:red@0.5:3', 8, 166, 110, 0x9bb72417),
    (
      _avc,
      'drawbox=3:5:37:29:invert:fill,negate=components=u+v',
      8,
      166,
      110,
      0xbbfc49b9,
    ),
    (_avc, _chain, 8, 128, 128, 0xa414a54d),
    (_anamorphic, 'pad=aspect=2:x=-1:y=-1:color=red', 5, 96, 64, 0x3207fe3d),
    (_hevc, 'negate=components=y+u', 6, 166, 110, 0xefc4cafc),
    (_hevc, 'pad=iw+16:ih+12:-1:-1:#1af085', 6, 182, 122, 0x006d3acd),
  ]) {
    final video = Video(file);
    try {
      final selected = video.packets().elementAt(index);
      final scaler = YuvImageScaler(filters: VideoFilterChain.parse(filters));
      final frame = video
          .decodeSelected([selected], scaler: scaler)
          .single
          .frame;
      check(
        frame.width == width && frame.height == height,
        '$filters geometry',
      );
      check(_hash(frame.getBytes()) == expected, '$filters filtered frame');
    } finally {
      video.close();
    }
  }
}

void _checkErrors() {
  for (final chain in [
    'pad=5:4',
    'pad=32768:32768',
    'pad=12:10:0:0:no-such-color',
    'drawbox=color=red@2',
    'drawbox=w=x:x=w',
    'negate=components=y',
    'setsar=1/0',
  ]) {
    try {
      final scaler = YuvImageScaler(filters: VideoFilterChain.parse(chain));
      scaler.filterRgb(image.Image(width: 8, height: 6));
      throw StateError('Accepted invalid filter $chain');
    } on FormatException {
      // The parse or the frame geometry rejects the filter.
    }
  }
}

Future<void> _checkCommands(String executable) async {
  final temp = Directory.systemTemp.createTempSync('vimg-paint-filters-');
  Future<void> run(List<String> arguments) async {
    final result = await Process.run(executable, arguments);
    check(result.exitCode == 0, '${arguments.first}: ${result.stderr}');
  }

  Map<String, File> captures(String directory) => {
    for (final file in Directory(directory).listSync().cast<File>())
      file.uri.pathSegments.last: file,
  };

  try {
    const chain = '$_chain,fps=6';
    final serial = '${temp.path}/serial';
    final parallel = '${temp.path}/parallel';
    for (final (threads, output) in [(1, serial), (4, parallel)]) {
      await run([
        'extract',
        '-n3',
        '-f3',
        '-T$threads',
        '--output-dir',
        output,
        '--vfilter',
        chain,
        _avc,
      ]);
    }
    final expected = captures(serial), actual = captures(parallel);
    check(expected.length == 9 && actual.length == 9, 'Nine captures per run');
    for (final entry in expected.entries) {
      final bytes = entry.value.readAsBytesSync();
      final other = actual[entry.key]!.readAsBytesSync();
      check(_hash(other) == _hash(bytes), 'Serial and parallel BMPs');
      final frame = image.decodeBmp(bytes)!;
      check(frame.width == 128 && frame.height == 128, 'Filtered BMP size');
    }
    final keep = '${temp.path}/keep';
    final grid = '${temp.path}/grid.avif';
    await run([
      'vcs',
      '-c2',
      '-H32',
      '-n3',
      '-f3',
      '-T4',
      '--keep',
      '--output-dir',
      keep,
      '--vfilter',
      chain,
      '-o',
      grid,
      _avc,
    ]);
    check(File(grid).lengthSync() > 0, 'Animated filtered sheet');
    final kept = captures(keep);
    check(kept.length == expected.length, 'All filtered originals were kept');
    for (final entry in kept.entries) {
      check(
        _hash(entry.value.readAsBytesSync()) ==
            _hash(expected[entry.key]!.readAsBytesSync()),
        'Kept BMPs match extract',
      );
    }
  } finally {
    temp.deleteSync(recursive: true);
  }
}

int _hash(List<int> samples) {
  var hash = 2166136261;
  for (final sample in samples) {
    hash = ((hash ^ sample) * 16777619) & 0xffffffff;
  }
  return hash;
}

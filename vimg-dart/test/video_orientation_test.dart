import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/avif_image.dart';
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _source = 'test/fixtures/cabac-idr.mp4';
const _unit = 1 << 16;
const _identity = [_unit, 0, 0, _unit];
const _clockwise = [0, _unit, -_unit, 0];
const _counterclockwise = [0, -_unit, _unit, 0];
const _mirror = [-_unit, 0, 0, _unit];

Future<void> main(List<String> arguments) async {
  final directory = Directory.systemTemp.createTempSync('vimg-orientation-');
  try {
    final clip = '${directory.path}/clip.mp4';
    _withMatrices(clip, _clockwise);
    _checkMatrices(clip);
    _checkWideHeaders(directory);
    await _checkCommands(directory, clip, arguments.firstOrNull);
  } finally {
    directory.deleteSync(recursive: true);
  }
}

void _checkWideHeaders(Directory directory) {
  final matrix = [
    for (final value in [0, _unit, 0, -_unit, 0, 0, 0, 0, 1 << 30])
      ...uint(value, 4),
  ];
  final file = File('${directory.path}/wide-headers.mov')
    ..writeAsBytesSync(
      box('moov', [
        ...box('mvhd', [1, ...List.filled(47, 0), ...matrix]),
        ...box('trak', [
          ...box('tkhd', [1, ...List.filled(51, 0), ...matrix]),
          ...box(
            'mdia',
            box('hdlr', [...List.filled(8, 0), ...ascii.encode('vide')]),
          ),
        ]),
      ]),
    );
  final handle = file.openSync();
  try {
    check(
      IsoMedia(BinaryFile(handle)).videoOrientation() ==
          (degrees: 0, horizontal: true, vertical: true),
      'Version 1 track and movie headers compose two quarter turns',
    );
  } finally {
    handle.closeSync();
  }
}

void _withMatrices(String path, List<int> track, {List<int>? movie}) {
  final file = File(_source).copySync(path).openSync(mode: FileMode.append);
  try {
    final iso = IsoMedia(BinaryFile(file));
    void write(MediaBox box, List<int> values, int narrow, int wide) {
      final version = iso.file.unsigned(box.data, 1);
      final offset = box.data + (version == 0 ? narrow : wide);
      final [a, b, c, d] = values;
      final data = ByteData(36);
      for (final (i, value) in [
        a,
        b,
        0,
        c,
        d,
        0,
        120 * _unit,
        -10 * _unit,
        1 << 30,
      ].indexed) {
        data.setInt32(i * 4, value);
      }
      file.setPositionSync(offset);
      file.writeFromSync(data.buffer.asUint8List());
    }

    write(iso.child(iso.firstVideoTrack(), 'tkhd')!, track, 40, 52);
    if (movie != null) write(iso.child(iso.movie(), 'mvhd')!, movie, 36, 48);
  } finally {
    file.closeSync();
  }
}

image.Image _firstPicture(String path) {
  final video = Video(path);
  try {
    return video.decode(video.packets(preview: true).first, preview: true);
  } finally {
    video.close();
  }
}

void _samePixels(image.Image actual, image.Image expected, String message) {
  check(
    actual.width == expected.width && actual.height == expected.height,
    '$message dimensions',
  );
  final bytes = expected.getBytes();
  check(
    actual.getBytes().indexed.every((item) => bytes[item.$1] == item.$2),
    message,
  );
}

void _checkMatrices(String clip) {
  final original = _firstPicture(_source);
  _samePixels(
    _firstPicture(clip),
    image.copyRotate(original, angle: 90),
    'Track matrix rotates the independently decoded H.264 keyframe',
  );
  final counter = '${File(clip).parent.path}/counter.mp4';
  _withMatrices(counter, _counterclockwise);
  _samePixels(
    _firstPicture(counter),
    image.copyRotate(original, angle: 270),
    'Counterclockwise track matrix',
  );
  final mirrored = '${File(clip).parent.path}/mirrored.mp4';
  _withMatrices(mirrored, _mirror);
  _samePixels(
    _firstPicture(mirrored),
    image.flipHorizontal(image.Image.from(original)),
    'Horizontal reflection at 180-degree matrix angle',
  );
  final composed = '${File(clip).parent.path}/composed.mp4';
  _withMatrices(composed, _mirror, movie: _clockwise);
  _samePixels(
    _firstPicture(composed),
    image.flipHorizontal(image.copyRotate(original, angle: 270)),
    'Compose track and movie matrices in display order',
  );
  final neutral = '${File(clip).parent.path}/neutral.mp4';
  _withMatrices(neutral, _identity);
  _samePixels(_firstPicture(neutral), original, 'Display ignores translation');
  final angle = '${File(clip).parent.path}/angle.mp4';
  _withMatrices(angle, const [46341, 46341, -46341, 46341]);
  final angled = _firstPicture(angle);
  check(
    angled.width == original.width &&
        angled.height == original.height &&
        angled.getPixel(0, 0).r == 0 &&
        angled.getPixel(0, 0).g == 0 &&
        angled.getPixel(0, 0).b == 0 &&
        angled.getPixel(angled.width ~/ 2, angled.height ~/ 2).luminance > 0,
    'Other angles rotate into a fixed canvas with black fill',
  );
}

Future<void> _checkCommands(
  Directory directory,
  String clip,
  String? executable,
) async {
  Future<ProcessResult> run(List<String> args) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...args],
    );
    check(result.exitCode == 0, '$args failed: ${result.stderr}');
    return result;
  }

  final preview = '${directory.path}/preview.jpg';
  final response = await run([
    'preview',
    '--output',
    preview,
    '--max-width',
    '30',
    '--max-height',
    '60',
    clip,
  ]);
  final metadata = jsonDecode(response.stdout as String) as Map;
  final stream = (metadata['streams'] as List).first as Map;
  final jpeg = image.decodeJpg(File(preview).readAsBytesSync())!;
  check(
    metadata['preview_written'] == true &&
        stream['width'] == 78 &&
        stream['height'] == 50 &&
        jpeg.width == 30 &&
        jpeg.height == 47,
    'Preview bounds use display orientation and metadata keeps coded dimensions',
  );

  List<File> captures(String path) =>
      Directory(path).listSync().cast<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final raw = '${directory.path}/raw';
  final upright = '${directory.path}/upright';
  await run(['extract', '-n2', '-T1', '--output-dir', raw, _source]);
  await run([
    'extract',
    '-n2',
    '-T2',
    '--output-dir',
    upright,
    '--vfilter',
    'crop=24:38:0:0',
    clip,
  ]);
  final baseFrames = captures(raw);
  final outputFrames = captures(upright);
  check(baseFrames.length == 2 && outputFrames.length == 2, 'Capture counts');
  for (var i = 0; i < baseFrames.length; i++) {
    final base = image.decodeBmp(baseFrames[i].readAsBytesSync())!;
    final expected = image.copyCrop(
      image.copyRotate(base, angle: 90),
      x: 0,
      y: 0,
      width: 24,
      height: 38,
    );
    _samePixels(
      image.decodeBmp(outputFrames[i].readAsBytesSync())!,
      expected,
      'Orientation precedes user crop in parallel capture',
    );
  }

  final grid = '${directory.path}/grid.avif';
  final kept = '${directory.path}/kept';
  await run([
    'vcs',
    '-c2',
    '-H39',
    '-n2',
    '-f1',
    '-T2',
    '--keep',
    '--output-dir',
    kept,
    '--output',
    grid,
    clip,
  ]);
  final sheet = readAvifImage(grid)!;
  check(
    sheet.width == 50 && sheet.height == 39,
    'Contact sheet tile orientation',
  );
  final retained = captures(kept);
  check(retained.length == baseFrames.length, 'Retained capture count');
  for (final (i, file) in retained.indexed) {
    final base = image.decodeBmp(baseFrames[i].readAsBytesSync())!;
    _samePixels(
      image.decodeBmp(file.readAsBytesSync())!,
      image.copyRotate(base, angle: 90),
      'Retained BMP keeps display orientation and full dimensions',
    );
  }
}

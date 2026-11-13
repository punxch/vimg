import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/capture.dart';
import 'package:vimg_dart/src/grid.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/video_commands.dart';

import 'fixtures.dart';

Future<void> main() async {
  await _checkDescriptions(
    'avc-sample-descriptions.mov',
    'cavlc-baseline.mp4',
    'cabac-idr.mp4',
    [0, 1, 2],
    [0, 1],
    [0, 3, 4, 5],
  );
  await _checkDescriptions(
    'hevc-sample-descriptions.mp4',
    'hevc-main10.mp4',
    'hevc-fields-tff-b.mp4',
    [0, 1, 2],
    [0],
    [0, 3, 4],
  );
  await _checkDescriptions(
    'av1-sample-descriptions.mp4',
    'av1-stsd-source.mp4',
    'av1-intra.mp4',
    [0, 1, 2],
    [0, 1],
    [0, 3, 4, 5],
  );
  await _checkDescriptions(
    'mpeg2-sample-descriptions.mov',
    'mpeg2-stsd-source.mp4',
    'mpeg2-fields.mov',
    [0, 1, 2],
    [0],
    [0, 3, 4],
  );
  _checkInvalidDescription();
  final expected = <image.Image>[
    _color(14, 62, 190),
    _color(53, 180, 74),
    ..._sourcePictures('cabac-p.mp4', 3),
    ..._sourcePictures('hevc-main10.mp4', 3),
    ..._sourcePictures('av1-intra.mp4', 2),
    ..._sourcePictures('mpeg2-fields.mov', 1),
    _color(53, 180, 74),
    ..._sourcePictures('cabac-p.mp4', 2),
  ];
  for (final name in ['mixed-codecs.mov', 'mixed-codecs-fragmented.mp4']) {
    await _checkMixedCodecs('test/fixtures/$name', expected);
  }
  final portrait = image.Image(width: 10, height: 20)
    ..clear(image.ColorRgb8(128, 64, 32));
  final grid = GridComposer(
    20,
    20,
    1,
    1,
    const [],
  ).compose([portrait], fitTiles: true);
  check(
    grid.getPixel(4, 10).r == 0 &&
        grid.getPixel(5, 10).r == 128 &&
        grid.getPixel(14, 10).r == 128 &&
        grid.getPixel(15, 10).r == 0,
    'Fit portrait tiles without stretching and center them in the grid',
  );
}

image.Image _color(int r, int g, int b) =>
    image.Image(width: 78, height: 50)..clear(image.ColorRgb8(r, g, b));

List<image.Image> _sourcePictures(String name, int count) {
  final video = Video('test/fixtures/$name');
  try {
    return video.packets().take(count).map(video.decode).toList();
  } finally {
    video.close();
  }
}

Future<void> _checkMixedCodecs(String input, List<image.Image> expected) async {
  final video = Video(input);
  final workers = VideoCaptureDecoder(video, threads: 4);
  final temp = Directory.systemTemp.createTempSync('vimg-mixed-codecs-');
  try {
    check(
      video.codec == 'png' && video.usesReferencePictures,
      'Mixed track starting in PNG',
    );
    final packets = video.packets().toList();
    check(packets.length == expected.length, 'Mixed track frame count');
    final positions = {
      for (final (index, packet) in packets.indexed) packet: index,
    };
    for (final (index, packet) in packets.indexed) {
      check(packet.seconds == index / 4, 'Mixed track PTS');
    }
    final keys = video.packets(preview: true).toList();
    const previewIndexes = [0, 1, 2, 5, 8, 9, 10, 11, 12];
    check(keys.length == previewIndexes.length, 'Mixed track keyframes');
    for (final (index, key) in keys.indexed.toList().reversed) {
      final source = previewIndexes[index];
      check(key == packets[source], 'Mixed track preview PTS');
      _same(
        video.decode(key, preview: true).getBytes(),
        expected[source].getBytes(),
        '$input preview $source',
      );
    }
    final pending = packets.toSet();
    await for (final result in workers.decode(packets.reversed)) {
      final index = positions[result.packet]!;
      final frame = result.frame;
      final reference = expected[index];
      check(pending.remove(result.packet), 'Mixed track parallel packet');
      check(
        (frame.width, frame.height) == (reference.width, reference.height),
        'Mixed track frame dimensions',
      );
      _same(
        frame.getBytes(),
        reference.getBytes(),
        '$input parallel frame $index',
      );
    }
    check(pending.isEmpty, 'Mixed track parallel frame count');
    final output = '${temp.path}/sheet.avif';
    var grids = 0;
    await writeContactSheet(
      input,
      output,
      const CaptureOptions(number: 7, frames: 2, window: 0.2),
      columns: 7,
      height: 24,
      onGrid: (_, frame, tileWidth, tileHeight) {
        check(
          frame.width == tileWidth * 7 && frame.height == tileHeight,
          'Mixed contact sheet dimensions',
        );
        grids++;
      },
    );
    check(
      grids == 2 && File(output).lengthSync() > 0,
      'Mixed AVIF contact sheet',
    );
  } finally {
    await workers.close();
    video.close();
    temp.deleteSync(recursive: true);
  }
}

Future<void> _checkDescriptions(
  String input,
  String outer,
  String middle,
  List<int> outerFrames,
  List<int> middleFrames,
  List<int> keys,
) async {
  const root = 'test/fixtures';
  final video = Video('$root/$input');
  final first = Video('$root/$outer');
  final second = Video('$root/$middle');
  final workers = VideoCaptureDecoder(video, threads: 3);
  try {
    // Samples start with entry 2, switch to entry 1 and return to entry 2.
    // AVC and HEVC switch between four- and two-byte NAL lengths. The MPEG-2
    // sequence headers live in glbl and do not appear in the samples.
    final firstPackets = first.packets().toList();
    final secondPackets = second.packets().toList();
    final before = [for (final i in outerFrames) first.decode(firstPackets[i])];
    final stream = video.metadata.streams.single;
    check(
      (stream.width, stream.height) ==
          (before.first.width, before.first.height),
      '$input probe uses the first active description',
    );
    final expected = [
      ...before,
      for (final i in middleFrames) second.decode(secondPackets[i]),
      ...before,
    ];
    final packets = video.packets().toList();
    check(packets.length == expected.length, '$input frame count');
    final positions = {
      for (final (index, packet) in packets.indexed) packet: index,
    };
    for (final (index, packet) in packets.indexed) {
      check(packet.seconds == index / 4, '$input PTS after description change');
    }
    final preview = video.packets(preview: true).toList().reversed.toList();
    check(preview.length == keys.length, '$input preview count');
    for (final (i, index) in keys.reversed.indexed) {
      check(preview[i] == packets[index], '$input preview packet');
      final picture = video.decode(preview[i], preview: true);
      final reference = expected[index];
      check(
        (picture.width, picture.height) == (reference.width, reference.height),
        '$input preview dimensions',
      );
      _same(picture.getBytes(), reference.getBytes(), '$input preview');
    }
    final serial = video.decodeSelected(packets).toList();
    check(serial.length == packets.length, '$input serial frame count');
    for (final frame in serial) {
      final index = positions[frame.packet]!;
      _same(
        frame.frame.getBytes(),
        expected[index].getBytes(),
        '$input serial frame $index',
      );
    }
    final selected = [packets.last, packets[3], packets[1]];
    final decoded = await workers.decode(selected).toList();
    check(decoded.length == selected.length, '$input parallel frame count');
    for (final frame in decoded) {
      final index = positions[frame.packet]!;
      check(selected.remove(frame.packet), '$input parallel packet');
      _same(
        frame.frame.getBytes(),
        expected[index].getBytes(),
        '$input parallel frame $index',
      );
    }
  } finally {
    await workers.close();
    second.close();
    first.close();
    video.close();
  }
}

void _checkInvalidDescription() {
  const path = 'test/fixtures/avc-sample-descriptions.mov';
  final directory = Directory.systemTemp.createTempSync('vimg-stsd-');
  final source = File(path).openSync();
  try {
    final media = IsoMedia(BinaryFile(source));
    final table = media.sampleTable(
      media.child(media.firstVideoTrack(), 'mdia'),
    );
    final mapping = media.child(table, 'stsc')!;
    final path = '${directory.path}/invalid.mov';
    final output = File(path).openSync(mode: FileMode.write);
    try {
      output.writeFromSync(media.file.read(0, media.file.length));
      output.setPositionSync(mapping.data + 16);
      output.writeFromSync(uint(3, 4));
    } finally {
      output.closeSync();
    }
    final video = Video(path);
    try {
      video.packets().toList();
    } on FormatException catch (error) {
      check(
        error.message == 'Invalid ISO media sample description index',
        'Invalid stsd index',
      );
      return;
    } finally {
      video.close();
    }
    throw StateError('Accepted a sample that refers to an absent description');
  } finally {
    source.closeSync();
    directory.deleteSync(recursive: true);
  }
}

void _same(List<int> actual, List<int> expected, String label) {
  check(
    actual.length == expected.length &&
        actual.indexed.every((sample) => expected[sample.$1] == sample.$2),
    '$label differs from its source',
  );
}

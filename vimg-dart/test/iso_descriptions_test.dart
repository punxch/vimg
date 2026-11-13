import 'dart:io';

import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/video.dart';

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

import 'dart:io';
import 'dart:typed_data';

import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/matroska_frames.dart';
import 'package:vimg_dart/src/mpeg12/decode.dart';
import 'package:vimg_dart/src/mpeg12/syntax.dart';
import 'package:vimg_dart/src/mpeg_systems.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';
import 'mpeg_checks.dart';

const _source = 'test/fixtures/mpeg2-fields';

// Authored MPEG-2 pictures with alternating field orders, I/I and I/P
// anchors, P/P and B/B pairs, and leading B-fields in the second GOP.
// Predictions exercise field, 16×8 and dual-prime modes, skipped and
// zero-motion macroblocks, and half-pel luma prediction. The I-field also
// has concealment vectors. The reference samples use FFmpeg -idct simple.
// dart format off
const _yuv420 = [
  0xfa3f236d, 0x134ba8ed, 0xb9d82156, 0xf04a208c, 0x371d321b,
  0xa1168396, 0xb78df363, 0xb78df363, 0x8685b22d,
];
const _yuv422 = [
  0xbe9fbe35, 0x6ad483bd, 0x31dd756e, 0x2e688ac4, 0xf637d11f,
  0x526c315e, 0x8342d91f, 0x8342d91f, 0xc9a77cc9,
];
const _yuv444 = [
  0x47328c95, 0xc301afc1, 0x5daf87fa, 0x16000e60, 0xfd4d83f5,
  0x1c519481, 0xb190eaad, 0xb190eaad, 0x830232d3,
];
// dart format on

Future<void> main(List<String> arguments) async {
  await _check('$_source.m2v', _yuv420);
  await _check('$_source-422.m2v', _yuv422);
  await _check('$_source-444.m2v', _yuv444);
  await _check('$_source.mkv', _yuv420, durationTicks: 40);
  await _check('$_source.vob', _yuv420, firstPts: 90000, duration: 0.38);
  // The TS stores fields in individual PES packets, omits the timestamp
  // from the first field of one B-frame and both fields of an I/P frame,
  // and ends during a separate PES with a known declared length.
  await _check('$_source.ts', _yuv420, firstPts: 90000, duration: 0.38);
  final temp = Directory.systemTemp.createTempSync('vimg-mpeg-fields-');
  try {
    _checkOrphanField(temp);
    if (arguments.isNotEmpty) await _checkCommands(arguments.single, temp);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

Future<void> _check(
  String path,
  List<int> hashes, {
  int firstPts = 0,
  int durationTicks = 3600,
  double duration = 0.36,
}) async {
  final video = Video(path);
  final workers = VideoCaptureDecoder(video, threads: 2);
  try {
    final stream = video.metadata.streams.single;
    check(stream.codec == 'mpeg2video', '$path MPEG-2 codec');
    check(stream.width == 48 && stream.height == 64, '$path dimensions');
    check(video.metadata.duration == duration, '$path duration');
    final packets = video.packets().toList();
    check(packets.length == 9, '$path one packet per field pair');
    final positions = {for (final (i, packet) in packets.indexed) packet: i};
    final systems = MpegSystemsVideo.detect(video.file);
    final coded =
        systems?.packets(false) ?? matroskaFrames(Matroska(video.file));
    final decoder = MpegStreamDecoder();
    final rgb = <int, Uint8List>{};
    const fieldsFirst = [1, 1, 2, 1, 2, 1, 2, 1, 2];
    for (final packet in coded) {
      final i = positions[packet]!;
      check(
        packet.timestamp!.pts == firstPts + durationTicks * i,
        '$path PTS of frame $i',
      );
      check(
        packet.timestamp!.duration == durationTicks,
        '$path frame duration',
      );
      check((packet.seconds - i / 25).abs() < 1e-9, '$path presentation time');
      final sample =
          systems?.read(packet) ?? video.file.read(packet.offset, packet.size);
      final structures = [
        for (final unit in mpegStartCodes(sample))
          if (unit.code == 0xb5 && sample[unit.data] >> 4 == 8)
            sample[unit.data + 2] & 3,
      ];
      final first = fieldsFirst[i];
      check(
        structures.length == 2 &&
            structures[0] == first &&
            structures[1] == 3 - first,
        '$path field order of frame $i',
      );
      final picture = decoder.decode(sample);
      check(mpegYuvHash(picture) == hashes[i], '$path YUV of frame $i');
      rgb[i] = picture.rgb().getBytes();
    }

    final keys = video.packets(preview: true).toList();
    check(
      keys.map((packet) => positions[packet]).join(',') == '0,6',
      'I/I and I/P are random-access frames',
    );
    _same(video.decode(keys.last, preview: true).getBytes(), rgb[6]!);
    var returned = 0;
    // The leading B-fields need both GOPs. The I/P anchor is also decoded
    // from scratch in its own run, then used as a reference for the last P.
    final requested = [packets.first, packets[5], packets[6], packets.last];
    await for (final result in workers.decode(requested)) {
      _same(result.frame.getBytes(), rgb[positions[result.packet]]!);
      returned++;
    }
    check(returned == requested.length, '$path worker results');
  } finally {
    await workers.close();
    video.close();
  }
}

void _checkOrphanField(Directory temp) {
  final bytes = File('$_source.m2v').readAsBytesSync();
  final lastField = mpegStartCodes(bytes).where((unit) => unit.code == 0).last;
  final file = File('${temp.path}/orphan.m2v')
    ..writeAsBytesSync(Uint8List.sublistView(bytes, 0, lastField.start));
  final video = Video(file.path);
  try {
    check(video.packets().length == 8, 'Do not output an orphan field');
    check(
      video.decode(video.packets().last).height == 64,
      'Decode the last complete pair',
    );
  } finally {
    video.close();
  }
}

Future<void> _checkCommands(String executable, Directory temp) async {
  final preview = '${temp.path}/preview.jpg';
  final captures = '${temp.path}/captures';
  final sheet = '${temp.path}/sheet.avif';
  for (final arguments in [
    ['preview', '--output', preview, '$_source.vob'],
    ['extract', '-n3', '-T2', '--output-dir', captures, '$_source.mkv'],
    ['vcs', '-c2', '-H32', '-n3', '-f3', '-T2', '-o', sheet, '$_source.ts'],
  ]) {
    final result = await Process.run(executable, arguments);
    check(result.exitCode == 0, '${arguments.first}: ${result.stderr}');
  }
  check(File(preview).lengthSync() > 0, 'JPEG preview');
  check(Directory(captures).listSync().length == 3, 'BMP frames');
  check(File(sheet).lengthSync() > 0, 'Animated AVIF');
}

void _same(Uint8List actual, Uint8List expected) {
  check(actual.length == expected.length, 'RGB byte length');
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) throw StateError('RGB differs at byte $i');
  }
}

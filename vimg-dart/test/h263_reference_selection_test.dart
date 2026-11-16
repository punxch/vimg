import 'dart:io';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _input = 'test/fixtures/h263-reference-selection.h263';

Future<void> main(List<String> arguments) async {
  // Three rows of DC-coded samples distinguish the immediately preceding
  // picture from two older anchors. The first GOB is implicit, and later
  // headers are unaligned. An Improved PB pair also exercises selected
  // anchor timing with nonzero motion on both sides of the paired picture.
  await _verify(_input, 1001 / 30000, [
    (48, 48, 0, 1032195271),
    (48, 48, 4, 550352297),
    (48, 48, 8, 120857840),
    (48, 48, 10, 2135521929),
    (48, 48, 12, 493535929),
    (48, 48, 16, 493535929),
    (48, 48, 18, 1861611258),
    (48, 48, 20, 2074649704),
    (96, 96, 24, 4012391355),
  ]);
  // The last EP selects an older enhancement reference before a slice uses
  // the immediate predecessor. The clock wraps from 1022 to 2.
  await _verify('test/fixtures/h263-reference-selection-layer.h263', 1 / 20, [
    (32, 32, 0, 824715724),
    (32, 32, 4, 3814851877),
    (32, 32, 8, 1689759055),
  ]);
  if (arguments.firstOrNull case final cli?) {
    final directory = Directory.systemTemp.createTempSync('vimg-h263-rps-');
    try {
      final output = File('${directory.path}/references.avif');
      final result = await Process.run(cli, [
        'vcs',
        '-c2',
        '-n2',
        '-H24',
        '-f3',
        '-t200ms',
        '-o',
        output.path,
        _input,
      ]);
      check(result.exitCode == 0, 'H.263 reference capture ${result.stderr}');
      check(
        String.fromCharCodes(output.readAsBytesSync().sublist(4, 12)) ==
            'ftypavis',
        'H.263 reference animation',
      );
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
}

Future<void> _verify(
  String path,
  double clock,
  List<(int, int, int, int)> expected,
) async {
  final video = Video(path);
  final worker = VideoCaptureDecoder(video, threads: 2);
  try {
    final packets = video.packets().toList();
    check(packets.length == expected.length, '$path frame count');
    final frames = {
      for (final capture in video.decodeSelected(packets))
        capture.packet: capture.frame,
    };
    for (final (i, (width, height, tick, crc)) in expected.indexed) {
      final packet = packets[i];
      final frame = frames[packet]!;
      check((frame.width, frame.height) == (width, height), '$path size $i');
      check(getCrc32(frame.getBytes()) == crc, '$path pixels $i');
      check((packet.seconds - tick * clock).abs() < 1e-8, '$path time $i');
    }
    for (var i = packets.length - 1; i >= 0; i--) {
      final capture = await worker.decode([packets[i]]).single;
      check(
        getCrc32(capture.frame.getBytes()) == expected[i].$4,
        '$path seek $i',
      );
    }
  } finally {
    await worker.close();
    video.close();
  }
}

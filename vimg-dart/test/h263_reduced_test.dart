import 'dart:io';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _input = 'test/fixtures/h263-reduced.h263';

Future<void> main(List<String> arguments) async {
  // A 44×44 display uses 48×48 stored references and a 64×64 update grid.
  // Independent reconstruction covers signed residuals, enlarged OBMC,
  // slice edges, both boundary filters, mixed-resolution B prediction and
  // both PB parts.
  await _verify(_input, [
    (44, 44, 0, 2858953621),
    (44, 44, 1, 2349012838),
    (44, 44, 2, 460469589),
    (44, 44, 4, 2789308496),
    (44, 44, 6, 864536857),
    (44, 44, 8, 3483612272),
    (44, 44, 12, 3483612272),
    (44, 44, 14, 3298231340),
    (44, 44, 16, 1628637966),
  ]);
  // The spatial enhancement update predicts from its two reference pictures
  // across a base-layer intra boundary.
  await _verify('test/fixtures/h263-reduced-layer.h263', [
    (40, 40, 0, 843096119),
    (40, 40, 4, 3715522644),
  ]);
  // Implicit Annex P enlargement precedes the update. The slice addresses
  // use the 15-macroblock update grid instead of the 54-macroblock full grid.
  await _verify('test/fixtures/h263-reduced-resize.h263', [
    (68, 44, 0, 3199268594),
    (136, 88, 4, 2439426070),
  ]);
  if (arguments.firstOrNull case final cli?) {
    final directory = Directory.systemTemp.createTempSync('vimg-h263-rru-');
    try {
      final sheet = File('${directory.path}/update.avif');
      final result = await Process.run(cli, [
        'vcs',
        '-c2',
        '-n2',
        '-H24',
        '-f3',
        '-t160ms',
        '-o',
        sheet.path,
        _input,
      ]);
      check(
        result.exitCode == 0,
        'H.263 update contact sheet ${result.stderr}',
      );
      check(
        String.fromCharCodes(sheet.readAsBytesSync().sublist(4, 12)) ==
            'ftypavis',
        'H.263 update animation',
      );
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
}

Future<void> _verify(String path, List<(int, int, int, int)> expected) async {
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
      check(
        (packet.seconds - tick * 1001 / 30000).abs() < 1e-8,
        '$path time $i',
      );
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

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _input = 'test/fixtures/h263-resample.h263';

Future<void> main(List<String> arguments) async {
  // The expected pixels come from an independent rational implementation of
  // Annex P. The clip includes implicit changes in size, both warping
  // precisions, all fill modes, and distinct B and P parts of an Improved PB.
  await _verify(_input, [
    (20, 20, 0, 1416394133),
    (40, 40, 2, 3975168862),
    (40, 40, 4, 2366028604),
    (28, 24, 6, 266886312),
    (28, 24, 8, 399696296),
    (28, 24, 10, 1202498528),
    (28, 24, 12, 3632147948),
    (28, 24, 16, 641330298),
    (56, 48, 20, 2768229321),
    (28, 24, 24, 2224773712),
  ]);
  // The EP chain inherits the color and warping parameters through an SNR
  // layer, a layer that doubles the width, and one that doubles the height.
  await _verify('test/fixtures/h263-resample-layers.h263', [
    (40, 40, 0, 2722702842),
    (40, 40, 4, 150324878),
  ]);
  if (arguments.firstOrNull case final cli?) {
    final directory = Directory.systemTemp.createTempSync('vimg-h263-rpr-');
    try {
      final sheet = File('${directory.path}/resampled.avif');
      final result = await Process.run(cli, [
        'vcs',
        '-c2',
        '-n2',
        '-H24',
        '-f3',
        '-t200ms',
        '-o',
        sheet.path,
        _input,
      ]);
      check(result.exitCode == 0, 'H.263 resampling capture ${result.stderr}');
      check(
        String.fromCharCodes(sheet.readAsBytesSync().sublist(4, 12)) ==
            'ftypavis',
        'H.263 mixed-resolution animation',
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
      final frame = frames[packets[i]]!;
      check((frame.width, frame.height) == (width, height), '$path size $i');
      check(getCrc32(frame.getBytes()) == crc, '$path pixels $i');
      check(
        (packets[i].seconds - tick * 1001 / 30000).abs() < 1e-8,
        '$path timestamp $i',
      );
    }
    for (var i = packets.length - 1; i >= 0; i--) {
      final frame = (await worker.decode([packets[i]]).single).frame;
      check(getCrc32(frame.getBytes()) == expected[i].$4, '$path seek $i');
    }
  } finally {
    await worker.close();
    video.close();
  }
}

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/mpeg4/short_header.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _input = 'test/fixtures/h263-slices.h263';

Future<void> main(List<String> arguments) async {
  // Five unequal rectangles tile a 5×4 macroblock grid. The reordered
  // pictures start at macroblock 7. P uses OBMC and historical references,
  // B uses reordered free-running slices, and the pair uses MVDB predictors.
  await _verify(
    _input,
    (80, 64),
    [
      (0, 1960588523),
      (4, 624745365),
      (6, 2892181271),
      (8, 2827636327),
      (12, 3443470270),
      (14, 326817720),
      (16, 4255208188),
    ],
  );
  await _verify(
    'test/fixtures/h263-slices-sac.h263',
    (48, 48),
    [(0, 2776158028), (4, 2776158028)],
  );
  await _verify(
    'test/fixtures/h263-slices-reduced-layer.h263',
    (96, 64),
    [(0, 4190680347), (4, 1544908782)],
  );
  _invalidLayouts();
  if (arguments.firstOrNull case final cli?) {
    final directory = Directory.systemTemp.createTempSync('vimg-h263-slices-');
    try {
      final output = File('${directory.path}/slices.avif');
      final result = await Process.run(cli, [
        'vcs',
        '-c2',
        '-n2',
        '-H32',
        '-f3',
        '-t200ms',
        '-o',
        output.path,
        _input,
      ]);
      check(result.exitCode == 0, 'H.263 slice capture ${result.stderr}');
      check(
        String.fromCharCodes(output.readAsBytesSync().sublist(4, 12)) ==
            'ftypavis',
        'H.263 slice animation',
      );
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
}

Future<void> _verify(
  String path,
  (int, int) dimensions,
  List<(int, int)> expected,
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
    for (final (i, (tick, crc)) in expected.indexed) {
      final packet = packets[i];
      final frame = frames[packet]!;
      check((frame.width, frame.height) == dimensions, '$path size $i');
      check(getCrc32(frame.getBytes()) == crc, '$path pixels $i');
      check(
        (packet.seconds - tick * 1001 / 30000).abs() < 1e-8,
        '$path time $i',
      );
    }
    for (var i = packets.length - 1; i >= 0; i--) {
      final capture = await worker.decode([packets[i]]).single;
      check(
        getCrc32(capture.frame.getBytes()) == expected[i].$2,
        '$path seek $i',
      );
    }
  } finally {
    await worker.close();
    video.close();
  }
}

void _invalidLayouts() {
  final bytes = File(_input).readAsBytesSync();
  final offsets = [
    for (var i = 0; i + 2 < bytes.length; i++)
      if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] & 0xfc == 0x80) i,
  ];
  final sample = bytes.sublist(offsets[1], offsets[2]);
  final header = H263Headers().read(sample);
  final start = h263GroupUnits(header, sample).first.start;
  for (final (offset, width, value, error) in [
    (start + 18, 6, 7, 'Duplicate H.263+ slice address'),
    (start + 29, 4, 0, 'H.263+ slices do not cover the picture'),
  ]) {
    final damaged = Uint8List.fromList(sample);
    for (var bit = 0; bit < width; bit++) {
      final position = offset + bit;
      final mask = 1 << (7 - (position & 7));
      final octet = damaged[position >> 3] & ~mask;
      damaged[position >> 3] = value & (1 << (width - 1 - bit)) == 0
          ? octet
          : octet | mask;
    }
    try {
      H263Decoder().decode(damaged);
      throw StateError('Accepted invalid slice layout');
    } on FormatException catch (failure) {
      check(
        failure.message == error,
        'slice layout validation ${failure.message}',
      );
    }
  }
}

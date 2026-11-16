import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _input = 'test/fixtures/h263-erps-whole.h263';
const _multiple = 'test/fixtures/h263-erps-multiple.h263';

Future<void> main(List<String> arguments) async {
  // Inter- and B-pictures choose older anchors across intra pictures,
  // with per-GOB overrides, PN inheritance and redundant transmissions.
  await _verify(
    _input,
    (32, 48),
    [
      (0, 3784710467),
      (4, 1518288916),
      (6, 445849988),
      (8, 1592532209),
      (12, 1518288916),
      (16, 1628300464),
      (20, 3784710467),
      (24, 1592532209),
      (28, 1592532209),
      (32, 1592532209),
    ],
  );
  // An enhancement layer has its own picture numbers and buffer. Its
  // first slice overrides the picture remapping while the second inherits it.
  await _verify(
    'test/fixtures/h263-erps-layer.h263',
    (32, 32),
    [(0, 3297136590), (4, 2188566787), (8, 1429583243)],
  );
  // Four luma references in an overlapped P prediction, two backward
  // anchors for B, and macroblock emulation prevention bits.
  await _verify(
    _multiple,
    (48, 48),
    [
      (0, 3051300694),
      (4, 2423074036),
      (6, 2164495757),
      (7, 2976680510),
      (8, 1996439153),
      (12, 191463258),
    ],
  );
  // Improved PB uses separate PR and PRB fields and the latest anchor's
  // temporal interval for direct predictions from an older reference.
  await _verify(
    'test/fixtures/h263-erps-paired.h263',
    (48, 32),
    [(0, 147444639), (4, 1083431100), (6, 2458478402), (8, 3028833305)],
  );
  await _verify(
    'test/fixtures/h263-erps-ep.h263',
    (32, 32),
    [(0, 4130403365), (4, 174037254), (8, 3688018285)],
  );
  // Annex J permits four different luma references without overlap.
  // Both chroma planes use the primary luma reference.
  await _verify(
    'test/fixtures/h263-erps-four-luma.h263',
    (32, 32),
    [
      (0, 3553379717),
      (4, 2439526410),
      (8, 3164132516),
      (12, 1427980596),
      (16, 2535081388),
    ],
  );
  _checkEviction();
  if (arguments.firstOrNull case final cli?) {
    final directory = Directory.systemTemp.createTempSync('vimg-h263-erps-');
    try {
      final output = File('${directory.path}/references.avif');
      final result = await Process.run(cli, [
        'vcs',
        '-c2',
        '-n2',
        '-H24',
        '-f3',
        '-t160ms',
        '-o',
        output.path,
        _multiple,
      ]);
      check(result.exitCode == 0, 'H.263 ERPS capture ${result.stderr}');
      check(
        String.fromCharCodes(output.readAsBytesSync().sublist(4, 12)) ==
            'ftypavis',
        'H.263 ERPS animation',
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

void _checkEviction() {
  final bytes = File(_input).readAsBytesSync();
  final offsets = [
    for (var i = 0; i + 2 < bytes.length; i++)
      if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] & 0xfc == 0x80) i,
  ];
  for (final (stop, packet) in [(7, 'slid'), (9, 'removed')]) {
    final decoder = H263Decoder();
    for (var i = 0; i < stop; i++) {
      decoder.decodePair(
        Uint8List.sublistView(bytes, offsets[i], offsets[i + 1]),
        includeBidirectional: true,
      );
    }
    _expectMissing(decoder, packet, 1);
  }
}

void _expectMissing(H263Decoder decoder, String packet, int index) {
  final data = File('test/fixtures/h263-erps-$packet.packet').readAsBytesSync();
  try {
    decoder.decode(data);
    throw StateError('Accepted an evicted ERPS reference');
  } on FormatException catch (failure) {
    check(
      failure.message == 'Missing H.263+ ERPS reference index $index',
      'ERPS eviction ${failure.message}',
    );
  }
}

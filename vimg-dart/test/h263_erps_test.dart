import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _input = 'test/fixtures/h263-erps-whole.h263';

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
        _input,
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

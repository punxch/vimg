import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/mpeg4/short_header.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _input = 'test/fixtures/h263-dps-b.h263';
const _inter = 'test/fixtures/h263-dps-p.h263';

Future<void> main(List<String> arguments) async {
  // An arbitrary-order rectangle can contain no MVs, one MV, or a
  // continuous chain spanning skipped, intra and four-vector macroblocks.
  await _verify(_inter, (64, 48), [(0, 748039020), (4, 874143617)]);
  await _verify(
    _input,
    (48, 32),
    [(0, 4215270467), (2, 633038121), (4, 1419865999)],
  );
  await _verify(
    'test/fixtures/h263-dps-pb.h263',
    (48, 32),
    [(0, 4215270467), (2, 3114600301), (4, 198180590)],
  );
  await _verify(
    'test/fixtures/h263-dps-layer.h263',
    (32, 32),
    [(0, 386366067), (4, 1938702315)],
  );
  await _verify(
    'test/fixtures/h263-dps-reduced.h263',
    (40, 52),
    [(0, 217700441), (4, 4138163183)],
  );
  _verifyInvalidPartitions();
  if (arguments.firstOrNull case final cli?) {
    final directory = Directory.systemTemp.createTempSync('vimg-h263-dps-');
    try {
      final output = File('${directory.path}/partitions.avif');
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
      check(
        result.exitCode == 0,
        'H.263 data partition capture ${result.stderr}',
      );
      check(
        String.fromCharCodes(output.readAsBytesSync().sublist(4, 12)) ==
            'ftypavis',
        'H.263 data partition animation',
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

void _verifyInvalidPartitions() {
  final bytes = File(_inter).readAsBytesSync();
  final offsets = [
    for (var i = 0; i + 2 < bytes.length; i++)
      if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] & 0xfc == 0x80) i,
  ];
  final intra = Uint8List.sublistView(bytes, offsets[0], offsets[1]);
  final predicted = Uint8List.sublistView(bytes, offsets[1]);
  final reader = H263Headers()..read(intra);
  // The first slice has one INTER macroblock, one skipped macroblock,
  // and the only vector encodes (0, 1) in four bits.
  final headerMarker = reader.read(predicted).bits.position + 4;
  final motionMarker = headerMarker + 9 + 4;
  for (final (offset, expected) in [
    (headerMarker + 8, 'Too many macroblocks in H.263+ header partition'),
    (motionMarker + 9, 'Invalid H.263+ motion partition marker'),
  ]) {
    final damaged = Uint8List.fromList(predicted);
    damaged[offset >> 3] ^= 1 << (7 - (offset & 7));
    _expectError(intra, damaged, expected);
  }
  final damaged = File(
    'test/fixtures/h263-dps-bad-last-vector.packet',
  ).readAsBytesSync();
  _expectError(
    intra,
    damaged,
    'H.263+ motion partition has an inconsistent last vector',
  );
}

void _expectError(Uint8List intra, Uint8List damaged, String message) {
  final decoder = H263Decoder()..decode(intra);
  try {
    decoder.decode(damaged);
    throw StateError('Accepted an invalid H.263+ partition');
  } on FormatException catch (failure) {
    check(
      failure.message == message,
      'partition validation ${failure.message}',
    );
  }
}

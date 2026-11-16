import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/mpeg4/short_header.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _input = 'test/fixtures/h263-independent-gob.h263';

Future<void> main(List<String> arguments) async {
  // Independent GOB bands with OBMC, deblocking, standalone B and Improved PB.
  await _verify(
    _input,
    (48, 64),
    [
      (0, 2830028416),
      (2, 1213060820),
      (4, 3676783993),
      (6, 1113556429),
      (8, 3352856691),
    ],
  );
  // EI splits the lower-layer bands into quadrants; EP uses the RRU grid.
  await _verify(
    'test/fixtures/h263-independent-spatial.h263',
    (64, 64),
    [(0, 94526111), (4, 4027098254)],
  );
  // RRU and normal pictures have different padded extents.
  await _verify(
    'test/fixtures/h263-independent-padded.h263',
    (40, 52),
    [(0, 4074627860), (4, 1190712839), (8, 1190712839)],
  );
  _verifyInvalidSegments();
  if (arguments.firstOrNull case final cli?) {
    final directory = Directory.systemTemp.createTempSync(
      'vimg-h263-independent-',
    );
    try {
      final output = File('${directory.path}/independent.avif');
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
        'H.263 independent segment capture ${result.stderr}',
      );
      check(
        String.fromCharCodes(output.readAsBytesSync().sublist(4, 12)) ==
            'ftypavis',
        'H.263 independent segment animation',
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

void _verifyInvalidSegments() {
  final bytes = File(_input).readAsBytesSync();
  final offsets = [
    for (var i = 0; i + 2 < bytes.length; i++)
      if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] & 0xfc == 0x80) i,
  ];
  final intra = Uint8List.sublistView(bytes, offsets[0], offsets[1]);
  final predicted = Uint8List.sublistView(bytes, offsets[1], offsets[2]);
  final firstGroup = h263GroupUnits(
    H263Headers().read(predicted),
    predicted,
  ).first.start;
  final changedGroup = Uint8List.fromList(predicted);
  _writeBits(changedGroup, firstGroup + 17, 5, 1);
  _expectInvalid(
    intra,
    changedGroup,
    'H.263+ temporal reference changed independent segment boundaries',
  );

  final restrictedMotion = Uint8List.fromList(predicted);
  // Disable Advanced Prediction and Deblocking Filter in OPPTYPE.
  _writeBits(restrictedMotion, 47, 1, 0);
  _writeBits(restrictedMotion, 49, 1, 0);
  _expectInvalid(
    intra,
    restrictedMotion,
    'H.263+ motion vector crosses an independent segment',
  );
}

void _writeBits(Uint8List bytes, int offset, int width, int value) {
  for (var bit = 0; bit < width; bit++) {
    final position = offset + bit;
    final mask = 1 << (7 - (position & 7));
    final octet = bytes[position >> 3] & ~mask;
    bytes[position >> 3] = value & (1 << (width - 1 - bit)) == 0
        ? octet
        : octet | mask;
  }
}

void _expectInvalid(Uint8List intra, Uint8List predicted, String message) {
  final decoder = H263Decoder()..decode(intra);
  try {
    decoder.decode(predicted);
    throw StateError('Accepted invalid independent segments');
  } on FormatException catch (failure) {
    check(failure.message == message, 'segment validation ${failure.message}');
  }
}

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/mpeg4/short_header.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _input = 'test/fixtures/h263-dps-b.h263';
const _inter = 'test/fixtures/h263-dps-p.h263';
const _recoveredB = 'test/fixtures/h263-dps-recover-b.h263';
const _recoveredSlices = 'test/fixtures/h263-dps-recover-slices.h263';

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
  // Oversized and shortened MVD words break the forward parse. The
  // intact LMVV permits recovery of the suffix and of an isolated lost
  // delta. Multiple faults leave a gap, and a lone vector has no LMVV.
  await _verify(
    'test/fixtures/h263-dps-recover-p.h263',
    (96, 80),
    [(0, 1996152582), (4, 2140024951)],
  );
  // Skip secondary deltas encountered in the reverse pass, for standalone
  // B prediction and for the B part of an Improved PB frame.
  await _verify(
    _recoveredB,
    (64, 32),
    [(0, 2479670088), (2, 3243469502), (4, 15202281)],
  );
  await _verify(
    'test/fixtures/h263-dps-recover-pb.h263',
    (48, 32),
    [(0, 2068204920), (2, 1175256506), (4, 2620488000)],
  );
  await _verify(
    _recoveredSlices,
    (64, 48),
    [(0, 2149761827), (2, 967149101), (4, 840275573)],
  );
  _verifyRecoveredPlanes();
  _verifyConcealedPartitions();
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
        _recoveredSlices,
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

void _verifyRecoveredPlanes() {
  final bytes = File(_recoveredSlices).readAsBytesSync();
  final [intra, predicted] = _pictureUnits(bytes);
  final decoder = H263Decoder();
  final anchor = decoder.decode(intra);
  final (:picture, :bidirectional) = decoder.decodePair(
    predicted,
    includeBidirectional: true,
  );
  // The I frame retains its first macroblock and last slice. The PB frame
  // also retains the valid prefix and final slice when a paired block fails.
  const expected = [
    [2578231546, 1810497639, 4233545759],
    [4171025462, 3936048452, 917335351],
    [1010188664, 438121571, 2475324487],
  ];
  for (final (frame, decoded) in [anchor, bidirectional!, picture!].indexed) {
    for (final (plane, samples) in decoded.planes.indexed) {
      check(
        getCrc32(samples) == expected[frame][plane],
        'H.263+ recovered frame $frame, plane $plane',
      );
    }
  }

  final header = H263Headers().read(intra);
  final groups = h263GroupUnits(header, intra).toList();
  final damaged = Uint8List.fromList(intra);
  _flipBit(damaged, header.bits.position + 4 + 8);
  _flipBit(damaged, groups.last.data + 8 + 8);
  var rejected = false;
  try {
    H263Decoder().decode(damaged);
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'H.263+ picture without any readable macroblocks');
}

void _verifyConcealedPartitions() {
  final bytes = File(_inter).readAsBytesSync();
  final [intra, predicted] = _pictureUnits(bytes);
  final decoder = H263Decoder();
  final anchor = decoder.decode(intra);
  final intact = decoder.decode(predicted);
  final reader = H263Headers()..read(intra);
  // The first slice has one INTER macroblock, one skipped macroblock,
  // and the only vector encodes (0, 1) in four bits.
  final headerMarker = reader.read(predicted).bits.position + 4;
  final motionMarker = headerMarker + 9 + 4;
  for (final offset in [headerMarker + 8, motionMarker + 9]) {
    final damaged = Uint8List.fromList(predicted);
    _flipBit(damaged, offset);
    _verifyConcealedRectangle(intra, damaged, anchor, intact, (
      left: 32,
      top: 0,
      right: 64,
      bottom: 16,
    ));
  }
  final damaged = File(
    'test/fixtures/h263-dps-bad-last-vector.packet',
  ).readAsBytesSync();
  _verifyConcealedRectangle(intra, damaged, anchor, intact, (
    left: 0,
    top: 0,
    right: 32,
    bottom: 48,
  ));
}

void _verifyConcealedRectangle(
  Uint8List intra,
  Uint8List damaged,
  H263Picture anchor,
  H263Picture intact,
  ({int left, int top, int right, int bottom}) rectangle,
) {
  final decoder = H263Decoder()..decode(intra);
  final recovered = decoder.decode(damaged);
  final (:left, :top, :right, :bottom) = rectangle;
  for (final (plane, samples) in recovered.planes.indexed) {
    final sub = plane == 0 ? 0 : 1;
    final stride = recovered.stride >> sub;
    for (var y = 0; y < recovered.height >> sub; y++) {
      for (var x = 0; x < recovered.width >> sub; x++) {
        final concealed =
            x >= left >> sub &&
            x < right >> sub &&
            y >= top >> sub &&
            y < bottom >> sub;
        final expected = (concealed ? anchor : intact).planes[plane];
        final index = y * stride + x;
        check(samples[index] == expected[index], 'plane $plane at $x,$y');
      }
    }
  }
}

List<Uint8List> _pictureUnits(Uint8List bytes) {
  final offsets = [
    for (var i = 0; i + 2 < bytes.length; i++)
      if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] & 0xfc == 0x80) i,
    bytes.length,
  ];
  return [
    for (var i = 0; i + 1 < offsets.length; i++)
      Uint8List.sublistView(bytes, offsets[i], offsets[i + 1]),
  ];
}

void _flipBit(Uint8List bytes, int bit) {
  bytes[bit >> 3] ^= 1 << (7 - (bit & 7));
}

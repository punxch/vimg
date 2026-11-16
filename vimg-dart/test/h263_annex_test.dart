import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _fixture = 'test/fixtures/h263-annex.avi';

Future<void> main(List<String> arguments) async {
  _checkDirectionalPrediction();
  await _checkVideo();
  if (arguments.firstOrNull case final cli?) await _checkContactSheet(cli);
}

void _checkDirectionalPrediction() {
  // One 32x32 H.263+ I-picture, starting at QUANT 6. The first
  // macroblock establishes an AC coefficient of 36 on each prediction axis.
  const prefix = [
    0x00,
    0x00,
    0x80,
    0x02,
    0x1c,
    0xe8,
    0xa3,
    0x00,
    0x10,
    0x81,
    0xe0,
    0x8f,
    0xf0,
    0x32,
  ];
  const bits =
      '000001' // Remaining picture header (six bits).
      '1'
      '0'
      '000010' // DC prediction, two coded luma blocks.
      '0000011'
      '1'
      '000010'
      '00000011' // Zigzag index 2, level 3.
      '0000011'
      '1'
      '000001'
      '00000011' // Zigzag index 1, level 3.
      '0001'
      '11'
      '00010'
      '001001' // Left prediction, absolute QUANT 9.
      '0000011'
      '1'
      '000001'
      '00000001' // Vertical scan index 1, level 1.
      '1'
      '10'
      '00010' // Top prediction, inherited QUANT 9.
      '0000011'
      '1'
      '000001'
      '11111111' // Horizontal scan index 1, level -1.
      '0001'
      '0'
      '00010'
      '11' // DC prediction, relative QUANT 9 -> 10.
      '0000011'
      '1'
      '000001'
      '00000111'; // Zigzag index 1, level 7.
  final padded = bits.padRight((bits.length + 7) ~/ 8 * 8, '0');
  final bytes = Uint8List.fromList([
    ...prefix,
    for (var i = 0; i < padded.length; i += 8)
      int.parse(padded.substring(i, i + 8), radix: 2),
  ]);
  final picture = H263Decoder().decode(bytes);
  final luma = picture.planes.first;
  void block(int bx, int by, int coefficient, {required bool vertical}) {
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        final k = vertical ? y : x;
        final expected =
            (1025 / 8 +
                    coefficient *
                        math.sqrt2 *
                        math.cos((2 * k + 1) * math.pi / 16) /
                        8)
                .round();
        final index = (by + y) * picture.stride + bx + x;
        // Allow the integer IDCT to round a pixel differently.
        check(
          (luma[index] - expected).abs() <= 1,
          'H.263+ AC prediction at ${bx + x},${by + y}',
        );
      }
    }
  }

  block(16, 0, 54, vertical: true);
  block(0, 16, 18, vertical: false);
  block(16, 16, 140, vertical: false);
}

Future<void> _checkVideo() async {
  // FFmpeg testsrc2 132x92 at 11 fps, encoded with h263p, -aiv 1,
  // -flags +aic+loop, -q:v 8, -g 7, and -ps 180. Expected RGB hashes
  // use the reference simple-IDCT YUV output and vimg's color conversion.
  const hashes = [
    3814393274,
    39576951,
    4009892263,
    1547521000,
    950269946,
    479079674,
    3745577521,
    1180240303,
    3232620558,
    604056353,
    2588971034,
    2469729205,
    475497612,
    103388916,
    1340704817,
    4262006099,
    2462628718,
  ];
  final video = Video(_fixture);
  final worker = VideoCaptureDecoder(video, threads: 2);
  try {
    final packets = video.packets().toList();
    check(packets.length == hashes.length, 'H.263+ display frame count');
    check(video.packets(preview: true).length == 3, 'H.263+ keyframe count');
    final captures = {
      for (final capture in video.decodeSelected(packets))
        capture.packet: getCrc32(capture.frame.getBytes()),
    };
    for (final (i, packet) in packets.indexed) {
      check((packet.seconds - i / 11).abs() < 0.000001, 'H.263+ timestamp $i');
      check(captures[packet] == hashes[i], 'H.263+ RGB frame $i');
    }
    for (final i in [16, 6, 14, 0, 9]) {
      final capture = await worker.decode([packets[i]]).single;
      check(getCrc32(capture.frame.getBytes()) == hashes[i], 'H.263+ seek $i');
    }
  } finally {
    await worker.close();
    video.close();
  }
}

Future<void> _checkContactSheet(String cli) async {
  final directory = Directory.systemTemp.createTempSync('vimg-h263-annex-');
  try {
    final sheet = File('${directory.path}/h263.avif');
    final result = await Process.run(cli, [
      'vcs',
      '-c2',
      '-H24',
      '-n2',
      '-f3',
      '-t200ms',
      '-o',
      sheet.path,
      _fixture,
    ]);
    check(result.exitCode == 0, 'H.263+ contact sheet: ${result.stderr}');
    final bytes = sheet.readAsBytesSync();
    check(
      ascii.decode(bytes.sublist(4, 12)) == 'ftypavis',
      'H.263+ AVIF sequence',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

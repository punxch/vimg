import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _mp4 = 'test/fixtures/mpeg4-partitioned.mp4';
const _rvlc = 'test/fixtures/mpeg4-partitioned-rvlc.mkv';
const _gop = 'test/fixtures/mpeg4-partitioned-gov.avi';

Future<void> main(List<String> arguments) async {
  // testsrc2 encoded by FFmpeg. The MP4 has partitioned I/P-VOPs,
  // ordinary B-VOPs, multiple video packets, AC prediction, MPEG
  // quantization and quarter-sample motion. The Matroska stream also
  // exercises reversible run/level codes and both signs of VLC escapes.
  // RGB hashes come from FFmpeg's simple IDCT and vimg's YUV420 conversion.
  await _verifyContainer(_mp4, 10, [
    2652781831,
    130521569,
    4153582595,
    2353604921,
    2330829774,
    202041260,
    10244447,
    3101282629,
    3417367688,
    647094263,
    447945373,
    1178601396,
    2908587953,
    3591795003,
    796312472,
    649246078,
    2701742281,
  ]);
  await _verifyContainer(_rvlc, 10, [
    2662693441,
    4027579070,
    3499400274,
    1353499842,
    885349725,
    3348089815,
    758733040,
    3191038000,
    3860405349,
    1452259627,
    1830417010,
    981824289,
    15217901,
  ]);
  // Each I-VOP follows a GOV header. The ninth capture occurs after
  // the seconds field advances and vop_time_increment wraps to zero.
  await _verifyContainer(_gop, 6, [
    634577146,
    3898121435,
    2609966425,
    72280965,
    791476990,
    2028014624,
    1824943408,
    1413711118,
    1127191846,
  ]);
  _verifyDcInTexturePartition();
  await _verifyDamagedReversibleTexture(arguments.firstOrNull);
  if (arguments.firstOrNull case final cli?) await _verifyContactSheet(cli);
}

Future<void> _verifyContainer(String path, int rate, List<int> hashes) async {
  final video = Video(path);
  final decoder = VideoCaptureDecoder(
    video,
    threads: 2,
    scaler: YuvImageScaler(height: 24),
    includeOriginal: true,
  );
  try {
    final packets = video.packets().toList();
    check(packets.length == hashes.length, '$path display count');
    final serial = {
      for (final capture in video.decodeSelected(packets))
        capture.packet: getCrc32(capture.frame.getBytes()),
    };
    for (final (index, packet) in packets.indexed) {
      check((packet.seconds - index / rate).abs() < 1e-12, '$path time $index');
      check(serial[packet] == hashes[index], '$path frame $index');
    }
    for (final index in [packets.length - 2, 0, 7, 2]) {
      final capture = await decoder.decode([packets[index]]).single;
      check(
        getCrc32(capture.original!.getBytes()) == hashes[index],
        '$path seek $index',
      );
      check(capture.frame.height == 24, '$path scaled capture $index');
    }
  } finally {
    await decoder.close();
    video.close();
  }
}

void _verifyDcInTexturePartition() {
  // One 16x16 I-VOP, with intra_dc_vlc_thr=7 so DC is the first texture
  // coefficient. Each block contains one coefficient with magnitude 1.
  const contents =
      '0000012000c48d88002d0084021471000001b3001007'
      '000001b611f2bd6002dcf73dcf7f';
  final bytes = Uint8List.fromList([
    for (var offset = 0; offset < contents.length; offset += 2)
      int.parse(contents.substring(offset, offset + 2), radix: 16),
  ]);
  final frame = Mpeg4Decoder().decode(bytes).single;
  check(
    getCrc32(frame.planes.expand((plane) => plane).toList()) == 2655799332,
    'Partitioned DC in texture matches separately coded DC from FFmpeg',
  );
}

Future<void> _verifyDamagedReversibleTexture(String? cli) async {
  final damaged = _reversibleStream(damaged: true);
  final concealed = _reversibleStream();
  final healthy = _reversibleStream(healthy: true);
  final actual = Mpeg4Decoder().decode(damaged).toList();
  final original = Mpeg4Decoder().decode(healthy).toList();
  // FFmpeg's simple IDCT, decoding the intact concealment reference.
  const expected = [3829798683, 2738999772, 3371650375];
  check(actual.length == expected.length, 'RVLC recovery preserves all VOPs');
  for (final (index, frame) in actual.indexed) {
    check(frame.pts == index, 'Recovered VOP $index preserves its timestamp');
    check(
      getCrc32(frame.planes.expand((plane) => plane).toList()) ==
          expected[index],
      'Recovered VOP $index equals its concealment reference',
    );
  }
  for (final index in [0, 2]) {
    check(
      getCrc32(actual[index].planes[0]) != getCrc32(original[index].planes[0]),
      'Damaged block in VOP $index originally had texture',
    );
  }
  if (cli == null) return;
  final directory = Directory.systemTemp.createTempSync('vimg-rvlc-recovery-');
  try {
    final input = File('${directory.path}/damaged.m4v')
      ..writeAsBytesSync(damaged);
    final reference = File('${directory.path}/concealed.m4v')
      ..writeAsBytesSync(concealed);
    for (final (name, file) in [('actual', input), ('expected', reference)]) {
      final result = await Process.run(cli, [
        'extract',
        '-n1',
        '-f3',
        '-t300ms',
        '-T2',
        '--output-dir',
        '${directory.path}/$name',
        file.path,
      ]);
      check(result.exitCode == 0, '${result.stderr}');
    }
    List<int> hashes(String name) {
      final frames =
          Directory(
              '${directory.path}/$name',
            ).listSync().whereType<File>().toList()
            ..sort((left, right) => left.path.compareTo(right.path));
      return [for (final file in frames) getCrc32(file.readAsBytesSync())];
    }

    final captures = hashes('actual'), references = hashes('expected');
    check(
      captures.length == 3 &&
          references.length == 3 &&
          captures.toSet().length == 3 &&
          captures.indexed.every((entry) => entry.$2 == references[entry.$1]),
      'CLI extract preserves the three recovered frames in presentation order',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

Uint8List _reversibleStream({bool damaged = false, bool healthy = false}) {
  String word(int value, int length) =>
      value.toRadixString(2).padLeft(length, '0');
  String padded(String bits) =>
      '$bits${'0'.padRight(8 - (bits.length & 7), '1')}';
  List<int> unit(int startCode, String bits) {
    final data = padded(bits);
    return [
      0,
      0,
      1,
      startCode,
      for (var i = 0; i < data.length; i += 8)
        int.parse(data.substring(i, i + 8), radix: 2),
    ];
  }

  const intraMarker = '1101011000000000001';
  const motionMarker = '11111000000000001';
  const dc = '1110110110111111';
  const last = '10110'; // LAST=1, RUN=0, LEVEL=+1 in both tables.
  const positiveEscape = '000011000001100000010100100000';
  const negativeEscape = '000011000001100000010100100001';
  // A missing escape marker before an intact LAST event leaves a block
  // boundary the backward decoder can use to delimit the following block.
  final brokenBlock = damaged ? '00000$last' : (healthy ? '10111' : '');
  final codeAll = damaged || healthy;
  final vol =
      '0${word(1, 8)}0'
      '0001'
      '000'
      '1${word(10, 16)}10'
      '1${word(32, 13)}1${word(16, 13)}1'
      '0100010110';
  String header(int time, {bool intra = true}) =>
      '${intra ? '00' : '01'}01${word(time, 4)}11${intra ? '' : '0'}00000110'
      '${intra ? '' : '001'}';

  // First I-VOP has two packets. Preserve DC in the damaged block and
  // recover the signed escapes and ordinary VLCs on its far side.
  final packet =
      '011$dc$intraMarker'
      '0${codeAll ? '11' : '1010'}'
      '$last$brokenBlock'
      '1100$positiveEscape$negativeEscape$last'
      '100101';
  final nextHeader = '${word(1, 17)}1${word(6, 5)}0';
  final nextPacket =
      '${padded('${header(0)}$packet')}$nextHeader'
      '1$dc$intraMarker'
      '01001$positiveEscape$last';
  final cleanIntra =
      '${header(1)}'
      '1$dc'
      '1$dc$intraMarker'
      '01001'
      '000100'
      '$last$positiveEscape$negativeEscape';

  // Final packet of a P-VOP. The reverse pass crosses from intra to inter
  // VLCs and the lost inter block retains its motion-compensated pixels.
  final predictive =
      '${header(2, intra: false)}'
      '000010111'
      '00000011'
      '$motionMarker${codeAll ? '0011' : '00011'}'
      '011$dc'
      '$last$brokenBlock$positiveEscape$last$negativeEscape$last'
      '1100$positiveEscape$negativeEscape$last$last$last$last';
  return Uint8List.fromList([
    ...unit(0x20, vol),
    ...unit(0xb6, nextPacket),
    ...unit(0xb6, cleanIntra),
    ...unit(0xb6, predictive),
  ]);
}

Future<void> _verifyContactSheet(String cli) async {
  final directory = Directory.systemTemp.createTempSync(
    'vimg-mpeg4-partitions-',
  );
  try {
    final sheet = File('${directory.path}/sheet.avif');
    final result = await Process.run(cli, [
      'vcs',
      '-c2',
      '-n2',
      '-H24',
      '-f3',
      '-t200ms',
      '-o',
      sheet.path,
      _rvlc,
    ]);
    check(result.exitCode == 0, '${result.stderr}');
    check(
      ascii.decode(sheet.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'RVLC input produces an animated contact sheet',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

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

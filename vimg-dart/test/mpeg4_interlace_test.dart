import 'dart:io';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _tff = 'test/fixtures/mpeg4-interlaced-tff.mp4';
const _bff = 'test/fixtures/mpeg4-interlaced-bff.avi';
const _qpel = 'test/fixtures/mpeg4-interlaced-qpel.mkv';
const _tffHashes = [
  2757071915,
  2691171837,
  237276453,
  3013462892,
  390983210,
  752148589,
  2100543999,
  2274198505,
  3607111656,
  1638545651,
  3214189740,
  3589997650,
  2458848958,
  3060994842,
  1441083205,
  2223999804,
  3262955210,
];

Future<void> main(List<String> arguments) async {
  // FFmpeg mpeg4 at 176x112 or 160x98, testsrc2 woven by tinterlace, two
  // B-VOPs, -flags +ildct+ilme and -mbd rd. The Matroska clip also uses
  // quarter-sample motion, MPEG quantization and alternate vertical scan.
  // The hashes come from FFmpeg's single-threaded simple IDCT decoding,
  // converted from the resulting YUV420 into vimg's RGB output.
  await _verifyContainer(_tff, _tffHashes, 1001 / 12000, keys: 3);
  await _verifyContainer(
    _bff,
    [
      3356346241,
      852338962,
      1804196749,
      2639695229,
      3671444078,
      2858734697,
      3385277960,
      2165729929,
      18906025,
      968791200,
      1850035542,
      2454688926,
      3359932389,
      2563360714,
      2462839436,
      2229916755,
      555714349,
    ],
    1 / 12,
    keys: 3,
  );
  await _verifyContainer(
    _qpel,
    [
      1148462745,
      2566013907,
      2462325531,
      1747467959,
      3082590845,
      1686241181,
      735863893,
      2538583257,
      2927621939,
      4270170555,
      3933528663,
      3935924892,
      1204781435,
    ],
    1 / 9,
    keys: 2,
    tolerance: 0.0005,
  );
  if (arguments.firstOrNull case final cli?) await _verifyExtraction(cli);
}

Future<void> _verifyContainer(
  String path,
  List<int> hashes,
  double period, {
  required int keys,
  double tolerance = 1e-12,
}) async {
  final video = Video(path);
  final worker = VideoCaptureDecoder(
    video,
    threads: 2,
    scaler: YuvImageScaler(height: 28),
    includeOriginal: true,
  );
  try {
    final packets = video.packets().toList();
    check(packets.length == hashes.length, '$path display frames');
    check(video.packets(preview: true).length == keys, '$path I-VOPs');
    final decoded = {
      for (final result in video.decodeSelected(packets))
        result.packet: getCrc32(result.frame.getBytes()),
    };
    for (final (i, packet) in packets.indexed) {
      check((packet.seconds - i * period).abs() < tolerance, '$path time $i');
      check(decoded[packet] == hashes[i], '$path frame $i');
    }
    // Every capture starts a separate run, including leading B-VOPs and VOPs
    // after the bitstream clock has crossed a one-second boundary.
    for (final (i, packet) in packets.indexed.toList().reversed) {
      final frame = await worker.decode([packet]).single;
      check(frame.frame.height == 28, '$path scaled frame $i');
      check(getCrc32(frame.original!.getBytes()) == hashes[i], '$path seek $i');
    }
  } finally {
    await worker.close();
    video.close();
  }
}

Future<void> _verifyExtraction(String cli) async {
  final directory = Directory.systemTemp.createTempSync('vimg-mpeg4-fields-');
  try {
    final result = await Process.run(cli, [
      'extract',
      '-T2',
      '-n2',
      '-f3',
      '-t180ms',
      '--ignore-start',
      '750ms',
      '--output-dir',
      directory.path,
      _tff,
    ]);
    check(result.exitCode == 0, '${result.stderr}');
    final hashes = {
      for (final file in directory.listSync().whereType<File>())
        getCrc32(image.decodeBmp(file.readAsBytesSync())!.getBytes()),
    };
    check(hashes.length >= 2, 'Interlaced extraction emits distinct captures');
    check(
      _tffHashes.skip(8).toSet().containsAll(hashes),
      'Interlaced extraction retains source pixels with both fields',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

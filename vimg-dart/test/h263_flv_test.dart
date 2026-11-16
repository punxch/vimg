import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _fixtures = 'test/fixtures';
const _raw = '$_fixtures/h263-gob.h263';
const _mobile = '$_fixtures/h263-3gp.3gp';
const _plus = '$_fixtures/h263-plus.avi';
const _spark = '$_fixtures/spark.flv';
const _avc = '$_fixtures/flv-avc.flv';
const _rawTicks = [0, 2, 4, 7, 9, 12, 14, 17, 19, 22, 24, 27, 29];
const _plusHashes = [
  2809631082,
  2884018495,
  641873397,
  1332745952,
  1730168362,
  366144416,
  3701596103,
  942390446,
  1528612013,
  2929549195,
  2238385970,
  3426019603,
  230965628,
];
const _avcHashes = [
  1037749429,
  2758696241,
  1133170589,
  2165255631,
  947245503,
  237173443,
  281631518,
  445495729,
  531912167,
  2972984666,
  2238339506,
  4018398305,
  2995574683,
  4060294323,
  2675238604,
  1358993411,
  2470294537,
];

Future<void> main(List<String> arguments) async {
  // FFmpeg generated testsrc2 pictures. Hashes use its simple IDCT
  // followed by vimg's YUV-to-RGB conversion.
  await _verify(
    _raw,
    'h263',
    176,
    144,
    [
      1398795107,
      796479211,
      1870466382,
      2797443159,
      2119515211,
      2487875350,
      2981539404,
      3077497732,
      1192728475,
      1863088532,
      1892658506,
      139995623,
      288168976,
    ],
    rate: 12,
    keys: 2,
    timeBase: '1/1200000',
    duration: 31 * 40040 / 1200000,
  );
  await _verify(
    _mobile,
    'h263',
    176,
    144,
    [
      1777311077,
      78074951,
      3916504220,
      870615441,
      2929515233,
      3735499159,
      3886734325,
      807277047,
      3798574385,
      2259988580,
      2156473713,
      124958847,
      4011579892,
      2420432101,
      3347008742,
      3836186692,
      3136229875,
    ],
    rate: 10,
    keys: 3,
    timeBase: '1/10240',
    duration: 1.7,
  );

  // The H.263+ stream uses a custom picture size and clock, structured
  // slices, unrestricted motion vectors, and P-picture rounding changes.
  await _verify(
    _plus,
    'h263',
    104,
    76,
    _plusHashes,
    rate: 12,
    keys: 2,
    timeBase: '1/12',
  );
  await _verify(
    '$_fixtures/h263-plus.mkv',
    'h263',
    104,
    76,
    _plusHashes,
    rate: 12,
    keys: 2,
    timeBase: '1/1000',
  );
  await _verify(
    _spark,
    'flv1',
    104,
    74,
    [
      1260986256,
      111710257,
      2333763956,
      1789515506,
      3128377347,
      1577572524,
      724262631,
      2903171582,
      2106679723,
      266681578,
      902932738,
      3635321448,
      1162161444,
      2154838717,
      597206840,
      289080965,
      3848765792,
    ],
    rate: 10,
    keys: 3,
    timeBase: '1/1000',
    duration: 1.7,
  );
  // Spark version 0 headers around H.263 macroblocks. The third picture
  // is disposable, so the fourth still references the second.
  await _verify(
    '$_fixtures/spark-disposable.flv',
    'flv1',
    176,
    144,
    [1777311077, 78074951, 3916504220, 1641043162],
    rate: 10,
    keys: 1,
    timeBase: '1/1000',
  );
  await _verify(
    _avc,
    'h264',
    126,
    82,
    _avcHashes,
    rate: 10,
    keys: 3,
    timeBase: '1/1000',
    duration: 1.9,
    firstPts: 200,
  );

  final directory = Directory.systemTemp.createTempSync('vimg-flv-');
  try {
    await _checkSignedOffsets(directory);
    if (arguments.firstOrNull case final cli?) await _checkCli(cli, directory);
  } finally {
    directory.deleteSync(recursive: true);
  }
}

Future<void> _verify(
  String path,
  String codec,
  int width,
  int height,
  List<int> hashes, {
  required int rate,
  required int keys,
  required String timeBase,
  double? duration,
  int? firstPts,
}) async {
  final video = Video(path);
  final worker = VideoCaptureDecoder(video, threads: 2);
  try {
    final stream = video.metadata.streams.single;
    check(stream.codec == codec && stream.timeBase == timeBase, '$path probe');
    check((stream.width, stream.height) == (width, height), '$path dimensions');
    if (duration != null)
      check(video.metadata.duration == duration, '$path duration');
    final packets = video.packets().toList();
    check(packets.length == hashes.length, '$path count');
    check(video.packets(preview: true).length == keys, '$path random access');
    final captures = {
      for (final capture in video.decodeSelected(packets))
        capture.packet: getCrc32(capture.frame.getBytes()),
    };
    for (final (i, packet) in packets.indexed) {
      final double expected;
      if (path == _raw) {
        final tick = _rawTicks[i] * 40040;
        expected = tick / 1200000;
        check(packet.timestamp?.pts == tick, 'H.263 temporal reference $i');
      } else {
        expected = i / rate;
      }
      check(
        (packet.seconds - expected).abs() < 0.0005,
        '$path display time $i',
      );
      if (firstPts != null) {
        check(packet.timestamp?.pts == firstPts + i * 100, '$path CTS $i');
      }
      check(captures[packet] == hashes[i], '$path RGB frame $i');
    }
    for (final i in {packets.length - 2, 1, packets.length ~/ 2, 0}) {
      final captured = await worker.decode([packets[i]]).single;
      check(getCrc32(captured.frame.getBytes()) == hashes[i], '$path seek $i');
    }
  } finally {
    await worker.close();
    video.close();
  }
}

Future<void> _checkSignedOffsets(Directory directory) async {
  final bytes = File(_avc).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  var negative = false;
  for (var offset = data.getUint32(5) + 4; offset + 15 <= bytes.length;) {
    final size = data.getUint32(offset) & 0xffffff;
    final start = offset + 11;
    if (bytes[offset] == 9 && size >= 5 && bytes[start + 1] == 1) {
      final value = (data.getUint32(start + 1) & 0xffffff) - 101;
      negative |= value < 0;
      bytes[start + 2] = (value >> 16) & 0xff;
      data.setUint16(start + 3, value & 0xffff);
    }
    offset += size + 15;
  }
  check(negative, 'Authored FLV has signed composition offsets');
  final path = File('${directory.path}/signed.flv')..writeAsBytesSync(bytes);
  await _verify(
    path.path,
    'h264',
    126,
    82,
    _avcHashes,
    rate: 10,
    keys: 3,
    timeBase: '1/1000',
    duration: 1.799,
    firstPts: 99,
  );
}

Future<void> _checkCli(String cli, Directory directory) async {
  Future<String> run(List<String> args) async {
    final result = await Process.run(cli, args);
    check(result.exitCode == 0, '$args failed: ${result.stderr}');
    return result.stdout as String;
  }

  final probe =
      jsonDecode(await run(['probe', _mobile])) as Map<String, dynamic>;
  final stream = (probe['streams'] as List).single as Map<String, dynamic>;
  check(stream['codec_name'] == 'h263', '3GP H.263 native probe');
  final preview = File('${directory.path}/spark.jpg');
  await run(['preview', '--output', preview.path, _spark]);
  final jpeg = image.decodeJpg(preview.readAsBytesSync());
  check(jpeg?.width == 104 && jpeg?.height == 74, 'Spark preview');
  final sheet = File('${directory.path}/h263.avif');
  await run([
    'vcs',
    '-c2',
    '-H24',
    '-n2',
    '-f3',
    '-t200ms',
    '-o',
    sheet.path,
    _plus,
  ]);
  check(
    ascii.decode(sheet.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
    'H.263+ animated contact sheet',
  );
}

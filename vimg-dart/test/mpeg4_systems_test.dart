import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _fixture = 'test/fixtures/mpeg4-systems';
const _raw = '$_fixture.m4v';
const _ts = '$_fixture.ts';
const _ps = '$_fixture.mpg';
const _rawClock = 1200000, _pesClock = 90000;
// These three files remux the MPEG-4 Visual track of mpeg4-partitioned.mp4
// with the VOL in band. The RGB hashes are from FFmpeg's simple IDCT.
const _hashes = [
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
];

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-mpeg4-systems-');
  try {
    // A payload-formatted user-data block places a start code across the
    // elementary reader's chunk boundary. The extension is immaterial.
    final padding = Uint8List((256 << 10) - 2)
      ..fillRange(4, (256 << 10) - 2, 65);
    padding.setRange(0, 4, const [0, 0, 1, 0xb2]);
    final chunked = File('${temp.path}/chunked.bin')
      ..writeAsBytesSync(padding)
      ..writeAsBytesSync(File(_raw).readAsBytesSync(), mode: FileMode.append);
    await _checkConstantRate(_raw, _rawClock, 0, 1.7);
    await _checkConstantRate(chunked.path, _rawClock, 0, 1.7);
    await _checkConstantRate(_ts, _pesClock, 9000, 1.7);
    await _checkConstantRate(_ps, _pesClock, 54000, 1.5);
    await _checkTransportEdits(temp);
    await _checkProgramMap(temp);
    await _checkVariableRate();
    if (arguments.firstOrNull case final cli?) await _checkCli(cli, temp);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

Future<void> _checkConstantRate(
  String path,
  int clock,
  int first,
  double duration, {
  int count = 17,
}) => _checkVideo(
  path,
  _hashes.sublist(0, count),
  [for (var i = 0; i <= count; i++) first + i * (clock ~/ 10)],
  clock: clock,
  duration: duration,
  frameRate: 10,
  width: 144,
  height: 82,
);

Future<void> _checkTransportEdits(Directory temp) async {
  final bytes = File(_ts).readAsBytesSync();
  final sparse = Uint8List.fromList(bytes);
  var frame = 0, last = 0;
  for (var packet = 0; packet < bytes.length; packet += 188) {
    if (bytes[packet + 1] & 0x40 == 0) continue;
    var start = packet + 4;
    if (bytes[packet + 3] & 0x20 != 0) start += 1 + bytes[start];
    if (start + 9 >= packet + 188 ||
        ByteData.sublistView(bytes, start, start + 4).getUint32(0) !=
            0x000001e0)
      continue;
    last = packet;
    if (!const {0, 8, 14}.contains(frame++)) {
      sparse[start + 7] &= 0x3f;
      sparse.fillRange(start + 9, start + 9 + bytes[start + 8], 0xff);
    }
  }
  check(frame == 17, 'MPEG-4 transport fixture has 17 PES starts');
  final sparsePath = File('${temp.path}/sparse.ts')..writeAsBytesSync(sparse);
  await _checkConstantRate(sparsePath.path, _pesClock, 9000, 1.7);
  final truncated = File('${temp.path}/truncated.ts')
    ..writeAsBytesSync(Uint8List.sublistView(bytes, 0, last + 188));
  await _checkConstantRate(truncated.path, _pesClock, 9000, 1.6, count: 16);
}

Future<void> _checkProgramMap(Directory temp) async {
  final bytes = File(_ps).readAsBytesSync();
  // A program stream map with stream_type 0x10 and video stream ID 0xe0.
  const map = [
    0,
    0,
    1,
    0xbc,
    0,
    14,
    0xe0,
    0xff,
    0,
    0,
    0,
    4,
    0x10,
    0xe0,
    0,
    0,
    0x6d,
    0x41,
    0x97,
    0x21,
  ];
  final path = File('${temp.path}/mapped.mpg')
    ..writeAsBytesSync(Uint8List.sublistView(bytes, 0, 12))
    ..writeAsBytesSync(map, mode: FileMode.append)
    ..writeAsBytesSync(Uint8List.sublistView(bytes, 12), mode: FileMode.append);
  await _checkConstantRate(path.path, _pesClock, 54000, 1.5);
}

Future<void> _checkVariableRate() => _checkVideo(
  'test/fixtures/mpeg4-vfr.m4v',
  [
    3352778951,
    3525014432,
    1533982399,
    351641298,
    2328586422,
    3172824285,
    2964933482,
    1284574937,
    2118029234,
    2563564272,
    4172645836,
  ],
  // The encoder uses a 7 Hz VOP clock. Two input pictures were omitted.
  [
    for (final i in [0, 1, 2, 4, 5, 6, 7, 9, 10, 11, 12, 13])
      (i * _rawClock + 3) ~/ 7,
  ],
  clock: _rawClock,
  duration: 2228571 / _rawClock,
  frameRate: null,
  width: 96,
  height: 64,
);

Future<void> _checkVideo(
  String path,
  List<int> hashes,
  List<int> pts, {
  required int clock,
  required double duration,
  required double? frameRate,
  required int width,
  required int height,
}) async {
  final video = Video(path);
  final worker = VideoCaptureDecoder(video, threads: 2);
  try {
    final stream = video.metadata.streams.single;
    check(
      stream.codec == 'mpeg4' && stream.timeBase == '1/$clock',
      '$path probe',
    );
    check((stream.width, stream.height) == (width, height), '$path dimensions');
    check(video.metadata.duration == duration, '$path duration');
    check(video.filterTiming.frameRate == frameRate, '$path nominal rate');
    final packets = video.packets().toList();
    check(packets.length == hashes.length, '$path display count');
    check(video.packets(preview: true).length == 3, '$path random access');
    final captures = {
      for (final frame in video.decodeSelected(packets))
        frame.packet: getCrc32(frame.frame.getBytes()),
    };
    for (final (i, packet) in packets.indexed) {
      check(packet.seconds == (pts[i] - pts.first) / clock, '$path time $i');
      check(packet.timestamp?.pts == pts[i], '$path PTS $i');
      check(
        packet.timestamp?.duration == pts[i + 1] - pts[i],
        '$path frame duration $i',
      );
      check(captures[packet] == hashes[i], '$path pixels $i');
    }
    for (final index in [packets.length - 2, 1, 9, 0]) {
      final captured = await worker.decode([packets[index]]).single;
      check(
        getCrc32(captured.frame.getBytes()) == hashes[index],
        '$path seek $index',
      );
    }
  } finally {
    await worker.close();
    video.close();
  }
}

Future<void> _checkCli(String cli, Directory temp) async {
  Future<String> run(List<String> arguments) async {
    final result = await Process.run(cli, arguments);
    check(result.exitCode == 0, '$arguments failed: ${result.stderr}');
    return result.stdout as String;
  }

  final probe = jsonDecode(await run(['probe', _raw])) as Map<String, dynamic>;
  check(probe['native_probe'] == true, 'Raw MPEG-4 CLI probe');
  final preview = File('${temp.path}/preview.jpg');
  await run(['preview', '--output', preview.path, _raw]);
  final jpeg = image.decodeJpg(preview.readAsBytesSync());
  check(jpeg?.width == 144 && jpeg?.height == 82, 'Raw MPEG-4 CLI preview');

  final frames = Directory('${temp.path}/frames');
  await run(['extract', '-n3', '-t200ms', '--output-dir', frames.path, _raw]);
  final checksums = {
    for (final file in frames.listSync().whereType<File>())
      getCrc32(image.decodeBmp(file.readAsBytesSync())!.getBytes()),
  };
  check(
    checksums.length == 3 && _hashes.toSet().containsAll(checksums),
    'Raw MPEG-4 CLI extracts three distinct source frames',
  );

  final output = File('${temp.path}/tiles.avif');
  await run([
    'vcs',
    '-c2',
    '-H24',
    '-n2',
    '-f3',
    '-t250ms',
    '-o',
    output.path,
    _ts,
  ]);
  check(
    ascii.decode(output.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
    'MPEG-4 transport CLI creates an animated contact sheet',
  );
}

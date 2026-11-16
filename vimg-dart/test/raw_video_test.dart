import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/avif_image.dart';
import 'package:vimg_dart/src/raw_video.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  _checkLayouts();
  final directory = Directory.systemTemp.createTempSync('vimg-raw-video-');
  try {
    final mkv = _matroska(
      directory,
      'I420',
      (n) => [
        ...List.filled(8, [65, 125, 220][n % 3]),
        ...List.filled(4, 128),
      ],
    );
    final avi = _avi(directory);
    final vfw = _matroska(
      directory,
      'UYVY',
      (n) => [
        for (var i = 0; i < 4; i++) ...[128, 65 + n, 128, 210 - n],
      ],
      vfw: true,
    );
    final alpha = _matroska(
      directory,
      'BGRA',
      (n) => [
        for (var i = 0; i < 8; i++) ...[16, 38, 180, 50 + n * 10],
      ],
    );
    for (final (path, value) in [
      (mkv.path, 65),
      (avi.path, ((50 - 16) * 255 / 219).round()),
      (vfw.path, 65),
    ]) {
      final video = Video(path);
      final workers = VideoCaptureDecoder(video, threads: 2);
      try {
        check(video.codec == 'rawvideo', 'Probe codec for $path');
        final packets = video.packets().toList();
        check(packets.length == 8, 'Raw frames are independently decodable');
        final first = video.decode(packets.first, preview: true);
        check((first.width, first.height) == (4, 2), 'Raw preview dimensions');
        check(
          first.getPixel(0, 0).r == value,
          'Frame zero honors container layout and color range',
        );
        final expected = {
          for (final result in video.decodeSelected(packets))
            result.packet: result.frame.getBytes().toList(),
        };
        await for (final result in workers.decode(packets.reversed)) {
          final bytes = expected.remove(result.packet)!;
          check(
            result.frame.getBytes().indexed.every((p) => bytes[p.$1] == p.$2),
            'Parallel raw capture matches serial pixels',
          );
        }
        check(expected.isEmpty, 'Parallel raw capture count');
      } finally {
        await workers.close();
        video.close();
      }
    }
    await _checkCli(directory, mkv, alpha, arguments.firstOrNull);
  } finally {
    directory.deleteSync(recursive: true);
  }
}

void _checkLayouts() {
  final y = List<int>.generate(15, (i) => 35 + 9 * i);
  final u = [30, 60, 90, 120, 150, 180];
  final v = [210, 180, 150, 120, 90, 60];
  image.Image render(String tag, List<int> bytes) => RawVideoFormat(
    tag,
    5,
    3,
    matrix: 1,
    fullRange: true,
  ).decode(Uint8List.fromList(bytes)).rgb();
  final a = render('I420', [...y, ...u, ...v]);
  for (final (tag, bytes) in [
    ('YV12', [...y, ...v, ...u]),
    (
      'NV12',
      [
        ...y,
        for (var i = 0; i < u.length; i++) ...[u[i], v[i]],
      ],
    ),
    (
      'NV21',
      [
        ...y,
        for (var i = 0; i < u.length; i++) ...[v[i], u[i]],
      ],
    ),
  ]) {
    check(
      a.getBytes().toString() == render(tag, bytes).getBytes().toString(),
      '$tag matches I420 with odd dimensions',
    );
  }
  final rgba = RawVideoFormat(
    'BGRA',
    2,
    1,
  ).decode(Uint8List.fromList([16, 38, 180, 50, 61, 82, 140, 200]));
  final scaler = YuvImageScaler(filters: VideoFilterChain.parse('hflip'));
  final pixel = rgba.rgb(scaler: scaler).getPixel(0, 0);
  check(
    (pixel.r, pixel.g, pixel.b, pixel.a) == (140, 82, 61, 200),
    'Packed color and alpha survive planar filtering',
  );

  final tag = String.fromCharCodes([10, 10, 0x34, 0x59]); // YUVA422P10BE
  final input = Uint8List.fromList([
    for (final value in [64, 941, 512, 512, 0, 1023]) ...uint(value, 2),
  ]);
  final high = RawVideoFormat(tag, 2, 1).decode(input).rgb();
  check(
    high.getPixel(0, 0).r == 0 &&
        high.getPixel(0, 0).a == 0 &&
        high.getPixel(1, 0).r == 253 &&
        high.getPixel(1, 0).a == 255,
    'Big-endian 10-bit limited-range YUV and alpha',
  );

  final packed = RawVideoFormat('Y210', 2, 1)
      .decode(
        Uint8List.fromList([
          for (final value in [64, 512, 940, 512])
            ...uint(value << 6, 2).reversed,
        ]),
      )
      .rgb();
  check(
    packed.getPixel(0, 0).r == 0 && packed.getPixel(1, 0).r == 253,
    'Y210 stores ten significant bits at the top of each word',
  );
  try {
    render('I420', y);
    throw StateError('Accepted an incomplete planar frame');
  } on FormatException {
    // Missing chroma must not be interpreted as valid data.
  }
}

File _matroska(
  Directory directory,
  String tag,
  List<int> Function(int) frame, {
  bool vfw = false,
}) {
  List<int> item(int id, int size, List<int> bytes) =>
      ebml(uint(id, size), bytes);
  final duration = ByteData(8)..setFloat64(0, 8000);
  return File('${directory.path}/$tag.mkv')..writeAsBytesSync([
    ...item(0x1a45dfa3, 4, item(0x4282, 2, ascii.encode('matroska'))),
    ...item(0x18538067, 4, [
      ...item(0x1549a966, 4, item(0x4489, 2, duration.buffer.asUint8List())),
      ...item(
        0x1654ae6b,
        4,
        item(0xae, 1, [
          ...item(0xd7, 1, [1]),
          ...item(0x83, 1, [1]),
          ...item(
            0x86,
            1,
            ascii.encode(vfw ? 'V_MS/VFW/FOURCC' : 'V_UNCOMPRESSED'),
          ),
          if (vfw)
            ...item(0x63a2, 2, [
              ...uint(40, 4).reversed,
              ...uint(4, 4).reversed,
              ...uint(2, 4).reversed,
              1,
              0,
              16,
              0,
              ...tag.codeUnits,
              ...List.filled(20, 0),
            ]),
          ...item(0xe0, 1, [
            ...item(0xb0, 1, [4]),
            ...item(0xba, 1, [2]),
            if (!vfw) ...item(0x2eb524, 3, tag.codeUnits),
            ...item(0x55b0, 2, [
              ...item(0x55b1, 2, [1]),
              ...item(0x55b9, 2, [2]),
            ]),
          ]),
        ]),
      ),
      ...item(0x1f43b675, 4, [
        ...item(0xe7, 1, [0]),
        for (var i = 0; i < 8; i++)
          ...item(0xa3, 1, [0x81, ...uint(i * 1000, 2), 0x80, ...frame(i)]),
      ]),
    ]),
  ]);
}

File _avi(Directory directory) {
  List<int> little(int value, int size) => uint(value, size).reversed.toList();
  List<int> chunk(String type, List<int> payload) => [
    ...ascii.encode(type),
    ...little(payload.length, 4),
    ...payload,
    if (payload.length.isOdd) 0,
  ];
  List<int> list(String type, List<int> payload) =>
      chunk('LIST', [...ascii.encode(type), ...payload]);
  return File('${directory.path}/capture.avi')..writeAsBytesSync(
    chunk('RIFF', [
      ...ascii.encode('AVI '),
      ...list(
        'hdrl',
        list('strl', [
          ...chunk('strh', [
            ...ascii.encode('vidsUYVY'),
            ...List.filled(12, 0),
            ...little(1, 4),
            ...little(1, 4),
            ...little(0, 4),
            ...little(8, 4),
          ]),
          ...chunk('strf', [
            ...little(40, 4),
            ...little(4, 4),
            ...little(2, 4),
            ...little(1, 2),
            ...little(16, 2),
            ...ascii.encode('UYVY'),
            ...List.filled(20, 0),
          ]),
        ]),
      ),
      ...list('movi', [
        for (var i = 0; i < 8; i++)
          ...chunk('00db', [
            for (var pair = 0; pair < 4; pair++) ...[
              128,
              50 + i * 7,
              128,
              210 - i * 9,
            ],
          ]),
      ]),
    ]),
  );
}

Future<void> _checkCli(
  Directory directory,
  File mkv,
  File alpha,
  String? executable,
) async {
  Future<ProcessResult> run(List<String> arguments) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...arguments],
    );
    check(result.exitCode == 0, '$arguments: ${result.stderr}');
    return result;
  }

  final preview = '${directory.path}/preview.jpg';
  final response = await run(['preview', '--output', preview, mkv.path]);
  final metadata = jsonDecode(response.stdout as String) as Map;
  check(
    metadata['preview_written'] == true && File(preview).existsSync(),
    'Raw Matroska static preview',
  );
  final output = '${directory.path}/frames';
  final grid = '${directory.path}/grid.avif';
  await run([
    'vcs',
    '-c2',
    '-H16',
    '-n2',
    '-f1',
    '-T2',
    '--keep',
    '--output-dir',
    output,
    '--output',
    grid,
    alpha.path,
  ]);
  final sheet = readAvifImage(grid)!;
  check((sheet.width, sheet.height) == (64, 16), 'Raw Matroska grid geometry');
  final files = Directory(output).listSync().cast<File>().toList();
  check(files.length == 2, 'Raw Matroska retained capture count');
  for (final file in files) {
    final frame = image.decodeBmp(file.readAsBytesSync())!;
    final pixel = frame.getPixel(0, 0);
    check(
      (frame.width, frame.height) == (4, 2) &&
          pixel.r == 180 &&
          pixel.a >= 50 &&
          pixel.a <= 120,
      'Retained BGRA BMP preserves source geometry and alpha',
    );
  }
}

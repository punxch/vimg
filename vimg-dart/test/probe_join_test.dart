import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'package:vimg_dart/src/probe.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

List<int> uint(int value, int width) => [
  for (var shift = (width - 1) * 8; shift >= 0; shift -= 8)
    (value >> shift) & 255,
];

List<int> ebml(List<int> id, List<int> data) => [
  ...id,
  0x80 | data.length,
  ...data,
];
List<int> box(String tag, List<int> data) => [
  ...uint(data.length + 8, 4),
  ...latin1.encode(tag),
  ...data,
];

void testProbe(Directory temp) {
  final matroska = File('${temp.path}/test.mkv');
  final duration = ByteData(8)..setFloat64(0, 2250);
  matroska.writeAsBytesSync([
    ...ebml([
      0x1a,
      0x45,
      0xdf,
      0xa3,
    ], ebml([0x42, 0x82], ascii.encode('matroska'))),
    ...ebml(
      [0x18, 0x53, 0x80, 0x67],
      [
        ...ebml(
          [0x15, 0x49, 0xa9, 0x66],
          [
            ...ebml([0x2a, 0xd7, 0xb1], uint(1000000, 3)),
            ...ebml([0x44, 0x89], duration.buffer.asUint8List()),
          ],
        ),
        ...ebml(
          [0x16, 0x54, 0xae, 0x6b],
          ebml(
            [0xae],
            [
              ...ebml([0x83], [1]),
              ...ebml([0x86], ascii.encode('V_MPEG4/ISO/AVC')),
              ...ebml(
                [0xe0],
                [
                  ...ebml([0xb0], uint(1920, 2)),
                  ...ebml([0xba], uint(1080, 2)),
                ],
              ),
            ],
          ),
        ),
        0x1f, 0x43, 0xb6, 0x75, 0xff, // unknown-length Cluster
        ...ebml([0xe7], [0]),
        ...ebml([0x1c, 0x53, 0xbb, 0x6b], []), // following segment-level Cues
      ],
    ),
  ]);
  final mkv = probe(matroska.path);
  check(
    mkv.duration == 2.25 &&
        mkv.streams.single.codec == 'h264' &&
        mkv.streams.single.width == 1920 &&
        mkv.streams.single.height == 1080 &&
        mkv.streams.single.timeBase == '1/1000',
    'Matroska video metadata',
  );

  final mp4 = File('${temp.path}/test.mp4');
  mp4.writeAsBytesSync([
    ...box('ftyp', ascii.encode('isom')),
    ...box('mdat', [0, 0, 0, 0]),
    ...box('moov', [
      ...box('mvhd', [
        ...List.filled(12, 0),
        ...uint(1000, 4),
        ...uint(2250, 4),
      ]),
      ...box(
        'trak',
        box('mdia', [
          ...box('hdlr', [...List.filled(8, 0), ...ascii.encode('vide')]),
          ...box('mdhd', [
            ...List.filled(12, 0),
            ...uint(90000, 4),
            ...uint(202500, 4),
          ]),
          ...box(
            'minf',
            box(
              'stbl',
              box('stsd', [
                ...List.filled(7, 0),
                1,
                ...box('hvc1', [
                  ...List.filled(24, 0),
                  ...uint(320, 2),
                  ...uint(240, 2),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    ]),
  ]);
  final iso = probe(mp4.path);
  check(
    iso.duration == 2.25 &&
        iso.streams.single.codec == 'hevc' &&
        iso.streams.single.width == 320 &&
        iso.streams.single.height == 240 &&
        iso.streams.single.timeBase == '1/90000',
    'ISO media video metadata',
  );

  mp4.writeAsBytesSync([0, 0, 0, 100, ...ascii.encode('moov')]);
  try {
    probe(mp4.path);
    throw StateError('Accepted an out-of-bounds box');
  } on FormatException {
    // Expected.
  }
}

Future<void> testJoin(Directory temp) async {
  final paths = <String>[];
  for (final (index, color) in [
    (0, image.ColorRgb8(255, 0, 0)),
    (1, image.ColorRgb8(0, 255, 0)),
    (2, image.ColorRgb8(0, 0, 255)),
  ]) {
    final path = '${temp.path}/input $index.png';
    final frame = image.Image(width: 120, height: 80);
    image.fill(frame, color: color);
    File(path).writeAsBytesSync(image.encodePng(frame));
    paths.add(path);
  }
  final output = '${temp.path}/out.png';
  final args = [
    'bin/vimg.dart',
    'join',
    '-c2',
    '-H40',
    '--label',
    '01:23',
    ...paths,
    '-o',
    output,
  ];
  final result = await Process.run(Platform.resolvedExecutable, args);
  check(result.exitCode == 0, 'join failed: ${result.stderr}');
  final sheet = image.decodePng(File(output).readAsBytesSync())!;
  check(sheet.width == 120 && sheet.height == 80, 'Grid bounds');
  check(sheet.getPixel(0, 0).r == 255, 'First tile');
  check(sheet.getPixel(60, 0).g == 255, 'Second tile');
  check(sheet.getPixel(0, 40).b == 255, 'Third tile');
  check(sheet.getPixel(60, 40).r == 0, 'Empty tile');
  check(
    sheet.any((pixel) => pixel.x < 60 && pixel.y < 40 && pixel.r < 255),
    'Label overlay',
  );
}

Future<void> main() async {
  final temp = Directory.systemTemp.createTempSync('vimg-dart-test-');
  try {
    testProbe(temp);
    await testJoin(temp);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

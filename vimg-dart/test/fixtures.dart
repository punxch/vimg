import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

List<int> uint(int value, int width) => [
  for (var shift = (width - 1) * 8; shift >= 0; shift -= 8)
    (value >> shift) & 255,
];

List<int> ebml(List<int> id, List<int> data) {
  var width = 1;
  while (data.length >= (1 << (7 * width)) - 1) {
    width++;
  }
  return [...id, ...uint((1 << (7 * width)) | data.length, width), ...data];
}

List<int> box(String tag, List<int> data) => [
  ...uint(data.length + 8, 4),
  ...latin1.encode(tag),
  ...data,
];

image.Image solidFrame(int frame) {
  final pixels = image.Image(width: 32, height: 24);
  image.fill(
    pixels,
    color: switch (frame % 3) {
      0 => image.ColorRgb8(255, 0, 0),
      1 => image.ColorRgb8(0, 255, 0),
      _ => image.ColorRgb8(0, 0, 255),
    },
  );
  return pixels;
}

File matroskaFixture(Directory directory, {bool vp8 = false}) {
  final duration = ByteData(8)..setFloat64(0, 8000);
  final frames = [
    for (var frame = 0; frame < 8; frame++)
      if (vp8)
        _vp8Packet(solidFrame(frame))
      else
        image.encodeJpg(solidFrame(frame)),
  ];
  return File('${directory.path}/${vp8 ? 'video.webm' : 'video.mkv'}')
    ..writeAsBytesSync([
      ...ebml([
        0x1a,
        0x45,
        0xdf,
        0xa3,
      ], ebml([0x42, 0x82], ascii.encode(vp8 ? 'webm' : 'matroska'))),
      ...ebml(
        [0x18, 0x53, 0x80, 0x67],
        [
          ...ebml(
            [0x15, 0x49, 0xa9, 0x66],
            [
              ...ebml([0x44, 0x89], duration.buffer.asUint8List()),
            ],
          ),
          ...ebml(
            [0x16, 0x54, 0xae, 0x6b],
            ebml(
              [0xae],
              [
                ...ebml([0xd7], [1]),
                ...ebml([0x83], [1]),
                ...ebml([0x86], ascii.encode(vp8 ? 'V_VP8' : 'V_MJPEG')),
                ...ebml(
                  [0xe0],
                  [
                    ...ebml([0xb0], [32]),
                    ...ebml([0xba], [24]),
                  ],
                ),
              ],
            ),
          ),
          ...ebml(
            [0x1f, 0x43, 0xb6, 0x75],
            [
              ...ebml([0xe7], [0]),
              for (var index = 0; index < frames.length; index++)
                ...ebml(
                  [0xa3],
                  [0x81, ...uint(index * 1000, 2), 0x80, ...frames[index]],
                ),
            ],
          ),
        ],
      ),
    ]);
}

List<int> _vp8Packet(image.Image pixels) {
  final webp = image.WebPEncoder(lossless: false, method: 0).encode(pixels);
  check(ascii.decode(webp.sublist(12, 16)) == 'VP8 ', 'Fixture VP8 chunk');
  final size = ByteData.sublistView(webp).getUint32(16, Endian.little);
  return webp.sublist(20, 20 + size);
}

File isoFixture(Directory directory) {
  final frames = List.generate(
    8,
    (index) => image.encodeJpg(solidFrame(index)),
  );
  final ftyp = box('ftyp', ascii.encode('qt  '));
  List<int> table(String type, int count, List<int> entries) =>
      box(type, [...List.filled(4, 0), ...uint(count, 4), ...entries]);
  final timing = [...List.filled(12, 0), ...uint(1000, 4), ...uint(8000, 4)];
  return File('${directory.path}/video.mov')..writeAsBytesSync([
    ...ftyp,
    ...box('mdat', [for (final frame in frames) ...frame]),
    ...box('moov', [
      ...box('mvhd', timing),
      ...box(
        'trak',
        box('mdia', [
          ...box('hdlr', [...List.filled(8, 0), ...ascii.encode('vide')]),
          ...box('mdhd', timing),
          ...box(
            'minf',
            box('stbl', [
              ...table(
                'stsd',
                1,
                box('jpeg', [
                  ...List.filled(24, 0),
                  ...uint(32, 2),
                  ...uint(24, 2),
                ]),
              ),
              ...table('stts', 1, [...uint(8, 4), ...uint(1000, 4)]),
              ...table('stsc', 1, [
                ...uint(1, 4),
                ...uint(8, 4),
                ...uint(1, 4),
              ]),
              ...table('stco', 1, uint(ftyp.length + 8, 4)),
              ...box('stsz', [
                ...List.filled(8, 0),
                ...uint(8, 4),
                for (final frame in frames) ...uint(frame.length, 4),
              ]),
            ]),
          ),
        ]),
      ),
    ]),
  ]);
}

File aviFixture(Directory directory, {bool raw = false}) {
  List<int> little(int value, int width) =>
      uint(value, width).reversed.toList();
  List<int> chunk(String id, List<int> data) => [
    ...ascii.encode(id),
    ...little(data.length, 4),
    ...data,
    if (data.length.isOdd) 0,
  ];
  List<int> list(String id, List<int> data) =>
      chunk('LIST', [...ascii.encode(id), ...data]);
  List<int> stream(String type, String handler, int count) => chunk('strh', [
    ...ascii.encode(type),
    ...ascii.encode(handler),
    ...List.filled(12, 0),
    ...little(1, 4),
    ...little(1, 4),
    ...List.filled(4, 0),
    ...little(count, 4),
    ...List.filled(20, 0),
  ]);

  final header = list('hdrl', [
    ...list('strl', stream('auds', '    ', 8)),
    ...list('strl', [
      ...stream('vids', raw ? 'DIB ' : 'MJPG', 8),
      ...chunk('strf', [
        ...little(40, 4),
        ...little(raw ? 3 : 32, 4),
        ...little(raw ? 2 : 24, 4),
        ...little(1, 2),
        ...little(24, 2),
        if (raw) ...List.filled(4, 0) else ...ascii.encode('MJPG'),
        ...List.filled(20, 0),
      ]),
    ]),
  ]);
  // 3px rows with 3 bytes of padding. BMP's first stored row is the bottom.
  final bitmap = [
    255,
    0,
    0,
    255,
    0,
    0,
    255,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    255,
    0,
    0,
    255,
    0,
    0,
    255,
    0,
    0,
    0,
  ];
  final movie = list('movi', [
    ...chunk('JUNK', [1]),
    for (var frame = 0; frame < 8; frame++)
      ...list('rec ', [
        ...chunk('00wb', [1, 2]),
        ...chunk(
          raw ? '01db' : '01dc',
          raw ? bitmap : image.encodeJpg(solidFrame(frame)),
        ),
      ]),
  ]);
  return File('${directory.path}/${raw ? 'raw' : 'mjpeg'}.avi')
    ..writeAsBytesSync(
      chunk('RIFF', [...ascii.encode('AVI '), ...header, ...movie]),
    );
}

import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/av1/palette_encoder.dart';
import 'package:vimg_dart/src/avif_image.dart';

import 'fixtures.dart';

void main() {
  final directory = Directory.systemTemp.createTempSync('vimg-avif-items-');
  try {
    _checkGrid(directory);
    _checkAlpha();
  } finally {
    directory.deleteSync(recursive: true);
  }
}

void _checkAlpha() {
  // Pillow 11.3/libavif, quality 100 and 4:4:4, from a 64x48 RGBA image.
  // RGB is (200, 40, 90) throughout and alpha has four constant quadrants.
  final pixels = readAvifImage('test/fixtures/avif-alpha.avif')!;
  check(
    pixels.width == 64 && pixels.height == 48 && pixels.hasAlpha,
    'An externally encoded AVIF carries its auxiliary alpha',
  );
  for (final (x, y, expected) in [
    (5, 5, 48),
    (40, 5, 192),
    (5, 30, 96),
    (40, 30, 255),
  ]) {
    final pixel = pixels.getPixel(x, y);
    check(pixel.a == expected, 'AVIF alpha value at ($x, $y)');
    check(
      (pixel.r - 201).abs() <= 1 &&
          (pixel.g - 40).abs() <= 1 &&
          (pixel.b - 90).abs() <= 1,
      'AVIF alpha leaves unassociated color intact',
    );
  }
}

void _checkGrid(Directory directory) {
  const tileSize = 64;
  const primary = 0x10001, red = 0x10002, green = 0x10003;
  final encoder = Av1PaletteEncoder(tileSize, tileSize, still: true);
  List<int> tile(image.Color color) => [
    ...encoder.sequence,
    ...encoder.frame(
      image.Image(width: tileSize, height: tileSize)..clear(color),
    ),
  ];

  final tiles = {
    red: tile(image.ColorRgb8(255, 0, 0)),
    green: tile(image.ColorRgb8(0, 255, 0)),
  };
  final data = <int>[];
  final items = <int, List<(int, int)>>{};
  void store(int id, List<int> bytes, {bool split = false}) {
    final offset = data.length - 1;
    if (split) {
      final middle = bytes.length ~/ 2;
      items[id] = [
        (offset, middle),
        (offset + middle + 1, bytes.length - middle),
      ];
      data
        ..addAll(bytes.take(middle))
        ..add(0xff)
        ..addAll(bytes.skip(middle));
    } else {
      items[id] = [(offset, bytes.length)];
      data.addAll(bytes);
    }
  }

  // Nonzero base offset and an idat-backed grid with a partial edge tile.
  data.add(0xff);
  store(primary, [0, 0, 0, 1, ...uint(113, 2), ...uint(64, 2)]);
  for (final entry in tiles.entries) {
    store(entry.key, entry.value, split: true);
  }
  List<int> full(String type, int version, List<int> body, {int flags = 0}) =>
      box(type, [version, ...uint(flags, 3), ...body]);

  List<int> item(int id, String type) =>
      full('infe', 3, [...uint(id, 4), 0, 0, ...ascii.encode(type), 0]);
  List<int> properties(int id, List<int> indices) => [
    ...uint(id, 4),
    indices.length,
    for (final index in indices) ...uint(index, 2),
  ];
  final path = '${directory.path}/grid.avif';
  final file = File(path);
  void write(List<int> locationData) => file.writeAsBytesSync([
    ...box('ftyp', [
      ...ascii.encode('avif'),
      0,
      0,
      0,
      0,
      ...ascii.encode('avifmif1'),
    ]),
    ...full('meta', 0, [
      ...full('hdlr', 0, [
        ...uint(0, 4),
        ...ascii.encode('pict'),
        ...List.filled(13, 0),
      ]),
      ...full('pitm', 1, uint(primary, 4)),
      ...full('iinf', 1, [
        ...uint(3, 4),
        ...item(primary, 'grid'),
        ...item(red, 'av01'),
        ...item(green, 'av01'),
      ]),
      ...full('iloc', 2, [
        0x44,
        0x41,
        ...uint(items.length, 4),
        for (final entry in items.entries) ...[
          ...uint(entry.key, 4),
          0,
          1,
          0,
          0,
          ...uint(1, 4),
          ...uint(entry.value.length, 2),
          for (final (offset, length) in entry.value) ...[
            0,
            ...uint(offset, 4),
            ...uint(length, 4),
          ],
        ],
      ]),
      ...box('idat', locationData),
      ...full('iref', 1, [
        ...box('dimg', [
          ...uint(primary, 4),
          0,
          2,
          ...uint(red, 4),
          ...uint(green, 4),
        ]),
      ]),
      ...box('iprp', [
        ...box('ipco', [
          ...box('av1C', [0x81, 0x2d, 0, 0]),
          ...full('ispe', 0, [...uint(113, 4), ...uint(64, 4)]),
          ...box('clap', [
            for (final value in [109, 1, 64, 1, -2, 1, 0, 1]) ...uint(value, 4),
          ]),
          ...box('irot', [1]),
          ...box('imir', [0]),
          ...full('ispe', 0, [...uint(64, 4), ...uint(64, 4)]),
        ]),
        ...full('ipma', 1, [
          ...uint(3, 4),
          ...properties(primary, [2, 0x8003, 0x8004, 0x8005]),
          ...properties(red, [0x8001, 6]),
          ...properties(green, [0x8001, 6]),
        ], flags: 1),
      ]),
    ]),
  ]);

  write(data);
  final pixels = readAvifImage(path)!;
  check(
    pixels.width == 64 && pixels.height == 109,
    'Grid dimensions reflect the crop and rotation',
  );
  check(
    pixels.getPixel(0, 0).r == 255 &&
        pixels.getPixel(63, 63).r == 255 &&
        pixels.getPixel(0, 64).g == 255 &&
        pixels.getPixel(63, 108).g == 255,
    'Grid tiles follow reference order, with mirroring after rotation',
  );
  write(data.sublist(0, data.length - 1));
  try {
    readAvifImage(path);
    throw StateError('Read a truncated AVIF item from the next box');
  } on FormatException catch (error) {
    check(error.message.contains('extent'), 'Invalid idat extent is rejected');
  }
}

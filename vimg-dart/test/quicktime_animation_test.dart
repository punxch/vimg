import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/quicktime_animation.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  // FNV-1a hashes of FFmpeg-decoded RGB or RGBA frames in presentation order.
  await _checkClip('animation-argb.mov', true, 8, [
    0x6fd97dc5,
    0x26b47925,
    0x26b47925,
    0xbd0eb33d,
    0x26b47925,
    0x26b47925,
    0x6fd97dc5,
    0x6fd97dc5,
    0x6fd97dc5,
    0x26b47925,
    0x26b47925,
    0xbd0eb33d,
    0x26b47925,
    0x26b47925,
    0x6fd97dc5,
    0x6fd97dc5,
  ]);
  await _checkClip('animation-rgb.mov', false, 8, [
    0xe6e4ab58,
    0xe6e4ab58,
    0x7eb1d276,
    0x02005a8a,
    0xff0107de,
    0xeade666d,
    0xeade666d,
    0xca19c5a9,
    0xca19c5a9,
    0x626896e9,
    0xd8f6ab4b,
    0xa447d7ab,
    0x75f9b507,
    0x75f9b507,
    0x5a0d9a75,
    0xc04d48d5,
  ]);
  await _checkClip('animation-555.mov', false, 4, [
    0xdeeaa87c,
    0xdeeaa87c,
    0x56779846,
    0x5706b4ca,
    0x10f72d19,
    0x425a8720,
    0x425a8720,
    0xadb3b977,
  ]);
  _checkIndexed();
  await _checkDescriptionChanges();
  await _checkCli(arguments.firstOrNull);
}

Future<void> _checkDescriptionChanges() async {
  final png = <int>[
    _hash(
      image.Image(width: 78, height: 50)..clear(image.ColorRgb8(14, 62, 190)),
    ),
    _hash(
      image.Image(width: 78, height: 50)..clear(image.ColorRgb8(53, 180, 74)),
    ),
  ];
  const argb = [0x6fd97dc5, 0x26b47925, 0x26b47925];
  for (final (name, expected) in [
    (
      'animation-depth-switch.mov',
      [...argb, 0xdeeaa87c, 0xdeeaa87c, 0x56779846, ...argb],
    ),
    (
      'animation-mixed.mov',
      [...argb, ...png, 0xe6e4ab58, 0xe6e4ab58, 0x7eb1d276, ...argb],
    ),
  ]) {
    final video = Video('test/fixtures/$name');
    final worker = VideoCaptureDecoder(video, threads: 3);
    try {
      final packets = video.packets().toList();
      final positions = {
        for (final (index, packet) in packets.indexed) packet: index,
      };
      check(packets.length == expected.length, '$name frame count');
      final seen = <int>{};
      await for (final result in worker.decode(packets)) {
        final index = positions[result.packet]!;
        check(seen.add(index), '$name frame identity');
        check(
          _hash(result.frame) == expected[index],
          '$name frame $index after description change',
        );
      }
      check(seen.length == packets.length, '$name frames decoded');
    } finally {
      await worker.close();
      video.close();
    }
  }
}

int _hash(image.Image picture) {
  var hash = 0x811c9dc5;
  for (final byte in picture.getBytes()) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

Future<void> _checkClip(
  String name,
  bool alpha,
  int gop,
  List<int> hashes,
) async {
  final video = Video('test/fixtures/$name');
  final workers = VideoCaptureDecoder(video, threads: 2);
  try {
    check(video.codec == 'qtrle', 'QuickTime Animation codec');
    final packets = video.packets().toList();
    check(packets.length == hashes.length, '$name frame count');
    final indices = {for (final (i, packet) in packets.indexed) packet: i};
    for (final (i, packet) in packets.indexed) {
      check(packet.seconds == i / 8, '$name PTS');
    }
    final previews = video.packets(preview: true).toList();
    check(
      previews.length == 2 && previews.last == packets[gop],
      '$name keyframes',
    );
    check(
      !video.decode(previews.last, preview: true).hasAlpha,
      '$name opaque preview',
    );
    final frames = video.decodeSelected(packets).toList();
    check(frames.length == packets.length, '$name sequential frames');
    for (final result in frames) {
      final i = indices[result.packet]!;
      check(result.frame.hasAlpha == alpha, '$name frame alpha');
      check(
        _hash(result.frame) == hashes[i],
        '$name differs from FFmpeg at frame $i',
      );
    }
    final pending = {packets.last, packets[2], packets[gop - 1]};
    await for (final result in workers.decode(pending.toList())) {
      final i = indices[result.packet]!;
      check(pending.remove(result.packet), '$name sparse decode identity');
      check(
        _hash(result.frame) == hashes[i],
        '$name sparse decode differs at frame $i',
      );
    }
    check(pending.isEmpty, '$name sparse frame count');
    if (alpha) {
      final scaled = VideoCaptureDecoder(
        video,
        threads: 2,
        includeOriginal: true,
        scaler: YuvImageScaler(height: 16),
      );
      try {
        final selected = [packets[3], packets[gop + 3]];
        final results = await scaled.decode(selected).toList();
        check(results.length == 2, 'Scaled Animation tiles');
        for (final result in results) {
          check(
            result.frame.height == 16 && !result.frame.hasAlpha,
            'Scaled tile RGB',
          );
          check(
            _hash(result.original!) == hashes[indices[result.packet]!],
            'Original alpha',
          );
        }
      } finally {
        await scaled.close();
      }
    }
  } finally {
    await workers.close();
    video.close();
  }
}

void _checkIndexed() {
  QuickTimeAnimationDecoder decoder(
    int width,
    int depth, {
    List<int>? palette,
  }) {
    final entry = Uint8List(78 + (palette?.length ?? 0));
    final data = ByteData.sublistView(entry)
      ..setUint16(24, width)
      ..setUint16(26, 2)
      ..setUint16(74, depth)
      ..setUint16(76, palette == null ? 65535 : 0);
    if (palette != null) entry.setRange(78, data.lengthInBytes, palette);
    return QuickTimeAnimationDecoder(entry);
  }

  Uint8List chunk(List<int> payload, {int? row}) {
    final header = row == null ? [0, 0] : [0, 8, 0, row, 0, 0, 0, 1, 0, 0];
    return Uint8List.fromList([
      ...uint(4 + header.length + payload.length, 4),
      ...header,
      ...payload,
    ]);
  }

  final mono = decoder(16, 1);
  mono.advance(chunk([128, 1, 0x80, 0, 128, 1, 0x7f, 0xff, 0, 0]));
  check(
    mono.rgb().getPixel(0, 0).r == 0 && mono.rgb().getPixel(1, 0).r == 255,
    'One-bit pixels',
  );
  final indexed = decoder(
    4,
    8,
    palette: [
      0,
      0,
      0,
      0,
      0x80,
      0,
      0,
      1,
      0,
      0,
      180,
      0,
      44,
      0,
      12,
      0,
      0,
      0,
      9,
      0,
      84,
      0,
      201,
      0,
    ],
  );
  indexed.advance(chunk([1, 1, 0, 1, 1, 0, 255, 1, 1, 1, 0, 0, 1, 255]));
  final original = indexed.rgb();
  final color = original.getPixel(1, 0);
  check((color.r, color.g, color.b) == (9, 84, 201), 'Inline palette color');
  indexed.advance(chunk([1, 1, 1, 1, 0, 0, 255], row: 1));
  check(
    indexed.rgb().getPixel(0, 0).r == 180 &&
        indexed.rgb().getPixel(0, 1).r == 9,
    'Indexed delta row',
  );
  final gray = decoder(16, 34);
  gray.advance(
    chunk([
      for (var i = 0; i < 2; i++) ...[1, 1, 0x1b, 0x1b, 0x1b, 0x1b, 255],
    ]),
  );
  check(
    [for (var x = 0; x < 4; x++) gray.rgb().getPixel(x, 0).r].join(',') ==
        '255,170,85,0',
    'Two-bit grayscale ramp',
  );
  final color4 = decoder(8, 4);
  color4.advance(
    chunk([
      for (var i = 0; i < 2; i++) ...[1, 1, 0x12, 0x34, 0x56, 0x78, 255],
    ]),
  );
  check(color4.rgb().getPixel(0, 0).b == 5, 'Four-bit default palette');
  try {
    color4.advance(chunk([1, 2, 0, 0, 0, 0, 255], row: 0));
    throw StateError('Accepted an out-of-bounds Animation run');
  } on FormatException catch (error) {
    check(
      error.message == 'QuickTime Animation run exceeds its row',
      'Reject row overflow',
    );
  }
}

Future<void> _checkCli(String? executable) async {
  final temp = Directory.systemTemp.createTempSync('vimg-animation-');
  const input = 'test/fixtures/animation-argb.mov';
  Future<void> run(List<String> args) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...args],
    );
    check(result.exitCode == 0, '$args: ${result.stderr}');
  }

  try {
    final jpg = '${temp.path}/preview.jpg';
    await run(['preview', '--output', jpg, '--skip', '50', input]);
    check(
      image.decodeJpg(File(jpg).readAsBytesSync())?.width == 48,
      'Animation JPEG preview',
    );
    final avif = '${temp.path}/grid.avif';
    await run([
      'vcs',
      '-c2',
      '-H16',
      '-n2',
      '-f4',
      '-t500ms',
      '-T2',
      '-o',
      avif,
      input,
    ]);
    check(
      ascii.decode(File(avif).readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'Animation contact sheet',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

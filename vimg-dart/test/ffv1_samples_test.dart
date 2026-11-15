import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/ffv1.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/video_configuration.dart';

import 'fixtures.dart';

const _half = 'test/fixtures/ffv1-v4-gbrpf16.mkv';
const _float = 'test/fixtures/ffv1-v4-gbrpf32.mkv';
const _grayAlpha = 'test/fixtures/ffv1-v4-yaf16.mkv';
const _bayer = 'test/fixtures/ffv1-v4-rggb16.mkv';
const _width = 22;
const _height = 18;
const _colors = [
  [0.0, 1 / 1024, 0.1, 0.5, 1.0, 1.5, 2.0, -0.125, -0.5, -1.0],
  [0.0, 0.25, 1.0, 2.125, -0.25, 0.125, 0.8, 0.001, 0.000001],
  [1.0, 1.0001, 0.3333, 0.025, 0.02501, -0.01, 0.0, 15.0, -2.0],
];
const _halfCodes = [
  [
    0x0000,
    0x1400,
    0x2e66,
    0x3800,
    0x3c00,
    0x3e00,
    0x4000,
    0xb000,
    0xb800,
    0xbc00,
  ],
  [0x0000, 0x3400, 0x3c00, 0x4040, 0xb400, 0x3000, 0x3a66, 0x1419, 0x0011],
  [0x3c00, 0x3c00, 0x3555, 0x2666, 0x2667, 0xa11f, 0x0000, 0x4b80, 0xc000],
];

Future<void> main(List<String> arguments) async {
  for (final path in [_half, _float, _grayAlpha, _bayer]) {
    await _checkVideo(path);
  }
  if (arguments.firstOrNull case final cli?) await _checkCommands(cli);
}

Future<void> _checkVideo(String path) async {
  final video = Video(path);
  final capture = VideoCaptureDecoder(video, threads: 2);
  try {
    final stream = video.metadata.streams.single;
    check(stream.codec == 'ffv1', '$path codec');
    check(
      stream.width == _width && stream.height == _height,
      '$path dimensions',
    );
    final config = matroskaVideoConfiguration(Matroska(video.file), 'ffv1')!;
    final decoder = Ffv1Decoder(_width, _height, config);
    final packets = video.packets().toList();
    check(packets.length == 5, '$path frame count');
    var lastRgb = Uint8List(0);
    for (final (frame, packet) in packets.indexed) {
      final picture = decoder.decode(
        video.file.read(packet.offset, packet.size),
      );
      final rendered = picture.rgb();
      switch (path) {
        case _bayer:
          _checkBayer(frame, picture, rendered);
        case _grayAlpha:
          _checkGrayAlpha(frame, picture, rendered);
        default:
          _checkFloatingRgb(path, frame, picture, rendered);
      }
      lastRgb = rendered.getBytes();
    }
    final result = await capture.decode([packets.last]).single;
    check(
      _equal(result.frame.getBytes(), lastRgb),
      '$path seek into second GOP',
    );
  } finally {
    await capture.close();
    video.close();
  }
}

void _checkFloatingRgb(
  String path,
  int frame,
  Ffv1Picture picture,
  image.Image rendered,
) {
  final planes = [picture.y, picture.cb, picture.cr];
  final word = ByteData(4);
  for (final (plane, samples) in planes.indexed) {
    final values = _colors[plane];
    check(samples.length == _width * _height, '$path plane size');
    for (final (i, sample) in samples.indexed) {
      final slot = (i ~/ 3 + i ~/ _width + frame * (plane + 1)) % values.length;
      final value = values[slot];
      word.setFloat32(0, value, Endian.little);
      final expected = path == _half
          ? _halfCodes[plane][slot]
          : word.getUint32(0, Endian.little);
      check(sample == expected, '$path frame $frame plane $plane sample $i');
      final pixel = rendered.getPixel(i % _width, i ~/ _width);
      final component = switch (plane) {
        0 => pixel.g,
        1 => pixel.b,
        _ => pixel.r,
      };
      check((component - _display(value)).abs() <= 1, '$path RGB conversion');
    }
  }
}

void _checkGrayAlpha(int frame, Ffv1Picture picture, image.Image rendered) {
  const luminance = [-1.0, 0.25, 0.5, 1.0, 16.0];
  const lumaCodes = [0xbc00, 0x3400, 0x3800, 0x3c00, 0x4c00];
  const opacity = [0.0, 0.125, 0.5, 1.0, 2.0, -0.5];
  const alphaCodes = [0x0000, 0x3000, 0x3800, 0x3c00, 0x4000, 0xb800];
  check(picture.cb.isEmpty && rendered.hasAlpha, 'FFV1 grayscale with alpha');
  final alpha = picture.alpha!;
  for (final (i, sample) in picture.y.indexed) {
    final slot = (i ~/ 3 + frame) % opacity.length;
    check(
      sample == lumaCodes[frame] && alpha[i] == alphaCodes[slot],
      'FFV1 half-float gray/alpha bits',
    );
    final pixel = rendered.getPixel(i % _width, i ~/ _width);
    final y = _display(luminance[frame]);
    check(
      (pixel.r - y).abs() <= 1 && pixel.r == pixel.g && pixel.g == pixel.b,
      'FFV1 gray conversion',
    );
    check(
      (pixel.a - _display(opacity[slot])).abs() <= 1,
      'FFV1 alpha conversion',
    );
  }
}

void _checkBayer(int frame, Ffv1Picture picture, image.Image rendered) {
  check(picture.cb.isEmpty && picture.cr.isEmpty, 'FFV1 Bayer mosaic plane');
  const base = [8192, 32768, 32768, 49152];
  for (final (i, sample) in picture.y.indexed) {
    final x = i % _width, y = i ~/ _width;
    final channel = 2 * (y & 1) + (x & 1);
    final expected = frame == 0
        ? base[channel]
        : (x * 901 +
                  y * 1709 +
                  x * y * (12 + frame) +
                  frame * 11939 +
                  channel * 21167) &
              65535;
    check(sample == expected, 'FFV1 Bayer frame $frame sensor sample $i');
    final pixel = rendered.getPixel(x, y);
    if (frame == 0) {
      check(
        pixel.r == 32 && pixel.g == 128 && (pixel.b - 191).abs() <= 1,
        'FFV1 RGGB interpolation',
      );
    }
  }
}

int _display(double sample) => (sample.clamp(0, 1) * 255).round();

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> _checkCommands(String cli) async {
  final temp = Directory.systemTemp.createTempSync('vimg-ffv1-samples-');
  Future<void> run(List<String> arguments) async {
    final result = await Process.run(cli, arguments);
    check(result.exitCode == 0, '${result.stderr}');
  }

  try {
    final jpeg = '${temp.path}/bayer.jpg';
    final avif = '${temp.path}/float.avif';
    await run(['preview', '--output', jpeg, _bayer]);
    check(
      image.decodeJpg(File(jpeg).readAsBytesSync())?.width == _width,
      'Bayer preview',
    );
    await run([
      'extract',
      '-n3',
      '--output-dir',
      '${temp.path}/frames',
      _grayAlpha,
    ]);
    final frames = Directory(
      '${temp.path}/frames',
    ).listSync().whereType<File>();
    check(frames.length == 3, 'Half-float extraction');
    for (final frame in frames) {
      final bitmap = image.decodeBmp(frame.readAsBytesSync());
      check(
        bitmap != null && bitmap.width == _width && bitmap.hasAlpha,
        'Half-float BMP alpha',
      );
    }
    await run([
      'vcs',
      '-c2',
      '-H18',
      '-n3',
      '-f3',
      '-t500ms',
      '-o',
      avif,
      _float,
    ]);
    final bytes = File(avif).readAsBytesSync();
    check(
      ascii.decode(bytes.sublist(4, 12)) == 'ftypavis',
      'Float32 contact sheet',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

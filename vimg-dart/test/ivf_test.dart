import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/av1/bitstream.dart';
import 'package:vimg_dart/src/avif_animation.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/video_configuration.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-ivf-');
  try {
    final av1 = _checkAv1(temp);
    final vp8 = _checkVp8(temp);
    _checkInvalid(temp, av1);
    if (arguments.isNotEmpty) {
      await _checkCli(arguments.single, temp, av1, width: 96, height: 64);
      await _checkCli(arguments.single, temp, vp8, width: 32, height: 24);
    }
  } finally {
    temp.deleteSync(recursive: true);
  }
}

File _checkAv1(Directory temp) {
  final original = Video('test/fixtures/av1-stsd-source.mp4');
  try {
    final packets = original.packets().toList();
    final order = {for (final (i, packet) in packets.indexed) packet: i};
    final rgb = {
      for (final frame in original.decodeSelected(packets))
        order[frame.packet]!: frame.frame.getBytes(),
    };
    final payloads = [
      for (final p in packets) original.file.read(p.offset, p.size),
    ];
    if (!readAv1Obus(payloads.first).any((obu) => obu.type == 1)) {
      final config = isoVideoConfiguration(IsoMedia(original.file), 'av1')!;
      payloads[0] = Uint8List.fromList([...config.skip(4), ...payloads.first]);
    }
    const stamps = [500, -20, 300, 750];
    final path = File('${temp.path}/av1.ivf')
      ..writeAsBytesSync(
        _ivf(
          'AV01',
          96,
          64,
          2000,
          2,
          [for (final (i, payload) in payloads.indexed) (stamps[i], payload)],
          headerSize: 40,
          declaredFrames: 0xffffffff,
        ),
      );
    final video = Video(path.path);
    try {
      final stream = video.metadata.streams.single;
      check(
        stream.codec == 'av1' && stream.timeBase == '1/1000',
        'IVF AV1 metadata',
      );
      check(
        video.metadata.duration == 0.970,
        'IVF duration from actual stamps',
      );
      final keys = video.packets(preview: true).toList();
      check(
        keys.length == 1 && keys.single.timestamp!.pts == 500,
        'AV1 keyframe preview',
      );
      _same(video.decode(keys.single, preview: true).getBytes(), rgb[0]!);
      final frames = video.packets().toList();
      const presentation = [1, 2, 0, 3];
      const durations = [320, 200, 250, 200];
      check(frames.length == presentation.length, 'IVF AV1 packet count');
      for (final (i, frame) in frames.indexed) {
        final pts = stamps[presentation[i]];
        check(frame.timestamp!.pts == pts, 'IVF raw PTS at $i');
        check(frame.seconds == (pts + 20) / 1000, 'IVF normalized time at $i');
        check(
          frame.timestamp!.duration == durations[i],
          'IVF frame duration at $i',
        );
      }
      final result = video.decodeSelected(frames).toList();
      check(result.length == frames.length, 'IVF AV1 decoded frame count');
      for (final frame in result) {
        _same(
          frame.frame.getBytes(),
          rgb[stamps.indexOf(frame.packet.timestamp!.pts)]!,
        );
      }
    } finally {
      video.close();
    }
    return File('${temp.path}/av1-regular.ivf')
      ..writeAsBytesSync(_ivf('AV01', 96, 64, 4, 1, payloads.indexed.toList()));
  } finally {
    original.close();
  }
}

File _checkVp8(Directory temp) {
  final webp = [
    for (final color in [0x0055aa, 0x552200, 0xaaaa22, 0x227744])
      image.WebPEncoder(lossless: false).encode(
        image.Image(
          width: 32,
          height: 24,
        )..clear(image.ColorRgb8(color >> 16, (color >> 8) & 255, color & 255)),
      ),
  ];
  final payloads = [for (final data in webp) _vp8Chunk(data)];
  final path = File('${temp.path}/vp8.ivf')
    ..writeAsBytesSync(_ivf('VP80', 32, 24, 4, 1, payloads.indexed.toList()));
  final video = Video(path.path);
  try {
    check(
      video.metadata.duration == 1 && video.codec == 'vp8',
      'VP8 IVF metadata',
    );
    final packets = video.packets().toList();
    check(packets.length == payloads.length, 'VP8 IVF frame count');
    final result = video.decodeSelected(packets).toList();
    check(result.length == payloads.length, 'VP8 all-intra capture');
    for (final (i, frame) in result.indexed) {
      _same(
        frame.frame.getBytes(),
        image.decodeWebP(webp[i])!.getBytes(order: image.ChannelOrder.rgb),
      );
    }
  } finally {
    video.close();
  }

  final inter = File('${temp.path}/vp8-inter.ivf')
    ..writeAsBytesSync(
      _ivf('VP80', 32, 24, 4, 1, [
        (0, payloads.first),
        (1, Uint8List.fromList([0x11, 0, 0])),
      ]),
    );
  final predicted = Video(inter.path);
  try {
    final preview = predicted.packets(preview: true).single;
    _same(
      predicted.decode(preview, preview: true).getBytes(),
      image.decodeWebP(webp.first)!.getBytes(order: image.ChannelOrder.rgb),
    );
    try {
      predicted.packets().toList();
      throw StateError('Exposed inter-coded VP8 capture');
    } on UnsupportedError {
      // Inter pictures require a reference decoder.
    }
  } finally {
    predicted.close();
  }
  return path;
}

Uint8List _vp8Chunk(Uint8List webp) {
  final header = ByteData.sublistView(webp);
  for (var at = 12; at + 8 < webp.length;) {
    final length = header.getUint32(at + 4, Endian.little);
    if (header.getUint32(at) == 0x56503820) {
      return Uint8List.sublistView(webp, at + 8, at + 8 + length);
    }
    at += 8 + length + (length & 1);
  }
  throw StateError('Missing lossy WebP chunk');
}

Uint8List _ivf(
  String codec,
  int width,
  int height,
  int rate,
  int scale,
  List<(int, Uint8List)> frames, {
  int headerSize = 32,
  int? declaredFrames,
}) {
  final bytes = Uint8List(headerSize)
    ..setRange(0, 4, 'DKIF'.codeUnits)
    ..setRange(8, 12, codec.codeUnits);
  ByteData.sublistView(bytes)
    ..setUint16(6, headerSize, Endian.little)
    ..setUint16(12, width, Endian.little)
    ..setUint16(14, height, Endian.little)
    ..setUint32(16, rate, Endian.little)
    ..setUint32(20, scale, Endian.little)
    ..setUint32(24, declaredFrames ?? frames.length, Endian.little);
  final output = BytesBuilder(copy: false)..add(bytes);
  for (final (pts, data) in frames) {
    final header = ByteData(12)
      ..setUint32(0, data.length, Endian.little)
      ..setInt64(4, pts, Endian.little);
    output
      ..add(header.buffer.asUint8List())
      ..add(data);
  }
  return output.takeBytes();
}

void _checkInvalid(Directory temp, File source) {
  final original = source.readAsBytesSync();
  final path = File('${temp.path}/broken.ivf');
  for (final (bytes, reason) in [
    (
      Uint8List.sublistView(original, 0, original.length - 1),
      'Invalid IVF frame extent',
    ),
    (
      Uint8List.fromList(original)..[16] = 0,
      'Invalid IVF dimensions or time base',
    ),
  ]) {
    path.writeAsBytesSync(bytes);
    Video? video;
    try {
      video = Video(path.path);
      video.metadata;
      throw StateError('Accepted broken IVF input');
    } on FormatException catch (error) {
      check(error.message == reason, reason);
    } finally {
      video?.close();
    }
  }
}

Future<void> _checkCli(
  String cli,
  Directory temp,
  File input, {
  required int width,
  required int height,
}) async {
  Future<String> run(List<String> args) async {
    final result = await Process.run(cli, [...args, input.path]);
    check(result.exitCode == 0, '$args: ${result.stderr}');
    return result.stdout as String;
  }

  final prefix = '${temp.path}/${input.uri.pathSegments.last}';
  final jpg = File('$prefix.jpg');
  final preview =
      jsonDecode(await run(['preview', '--output', jpg.path])) as Map;
  check(preview['preview_written'] == true, 'IVF JPEG written');
  final imageFile = image.decodeJpg(jpg.readAsBytesSync())!;
  check(
    (imageFile.width, imageFile.height) == (width, height),
    'IVF JPEG dimensions',
  );
  await run([
    'extract',
    '-n1',
    '-f2',
    '-t500ms',
    '--output-dir',
    '$prefix-frames',
  ]);
  check(Directory('$prefix-frames').listSync().length == 2, 'IVF BMP captures');
  await run([
    'vcs',
    '-n1',
    '-f2',
    '-t500ms',
    '-c1',
    '-H16',
    '-o',
    '$prefix.avif',
  ]);
  final sheet = AvifAnimation.open('$prefix.avif');
  try {
    check(
      sheet.height == 16 && sheet.frameCount == 2,
      'IVF AVIF contact sheet',
    );
  } finally {
    sheet.close();
  }
}

void _same(List<int> actual, List<int> expected) {
  check(actual.length == expected.length, 'IVF pixel count');
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) throw StateError('IVF RGB pixel at $i');
  }
}

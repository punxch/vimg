import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/matroska_frames.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/vp8/decoder.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _native = 'test/fixtures/vp8-alpha.webm';
const _staggered = 'test/fixtures/vp8-alpha-staggered.webm';
const _width = 97;
const _height = 67;

// FNV-1a over the alpha planes decoded with FFmpeg's libvpx decoder.
// dart format off
const _nativeMasks = [
  0x2f8a132d, 0x0b84637f, 0xa10484fa, 0xe92282bf, 0xfe7a184a, 0x130bc82f,
  0x762acc72, 0x24d3c6db, 0x93cdd397, 0x21bfa172, 0xa5e70740,
];

const _staggeredMasks = [
  0x2f8a132d, 0x0b84637f, 0xa10484fa, 0x6427365e, 0x81e6b564, 0x78a54033,
  0xce779bf2, 0x271c79b2, 0x786a9dff, 0x5b44f05c, 0xaf7b5975,
];
// dart format on

Future<void> main(List<String> arguments) async {
  await _checkVideo(_native, _nativeMasks, staggered: false);
  await _checkVideo(_staggered, _staggeredMasks, staggered: true);
  if (arguments.firstOrNull case final cli?) await _checkCli(cli);
}

Future<void> _checkVideo(
  String path,
  List<int> masks, {
  required bool staggered,
}) async {
  final video = Video(path);
  final workers = VideoCaptureDecoder(
    video,
    threads: 2,
    scaler: YuvImageScaler(height: 33),
    includeOriginal: true,
  );
  try {
    final packets = video.packets().toList();
    final positions = {for (final (i, packet) in packets.indexed) packet: i};
    check(packets.length == masks.length, '$path displayed frames');
    var additions = 0, mismatchedKeys = 0;
    matroskaFrames(
      Matroska(video.file),
      onAlpha: (packet, addition) {
        check(positions.containsKey(packet), '$path alpha association');
        final color = vp8FrameTag(video.file.read(packet.offset, 3));
        final alpha = vp8FrameTag(video.file.read(addition.data, 3));
        if (color.key && !alpha.key) mismatchedKeys++;
        additions++;
      },
    ).toList();
    check(
      additions == packets.length && (mismatchedKeys > 0) == staggered,
      '$path independent keyframes',
    );

    for (final (index, packet) in packets.indexed) {
      final frame = video.decode(packet);
      check(
        frame.width == _width && frame.height == _height,
        '$path dimensions',
      );
      check(_alphaHash(frame) == masks[index], '$path opacity at frame $index');
    }

    const targets = [2, 3, 6, 10];
    final decoded = <int>{};
    await for (final result in workers.decode([
      for (final i in targets.reversed) packets[i],
    ])) {
      final index = positions[result.packet]!;
      check(decoded.add(index), '$path unique parallel capture');
      check(
        _alphaHash(result.original!) == masks[index],
        '$path parallel opacity at $index',
      );
      check(
        result.frame.hasAlpha && result.frame.height == 33,
        '$path scaled alpha frame',
      );
      check(
        result.frame.any((pixel) => pixel.a < 200),
        '$path scaled transparency',
      );
    }
    check(decoded.length == targets.length, '$path parallel capture count');
  } finally {
    await workers.close();
    video.close();
  }
}

int _alphaHash(image.Image frame) {
  check(frame.hasAlpha, 'VP8 alpha channel');
  var hash = 0x811c9dc5;
  for (final pixel in frame) {
    hash = ((hash ^ pixel.a.toInt()) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

Future<void> _checkCli(String cli) async {
  final temp = Directory.systemTemp.createTempSync('vimg-vp8-alpha-');
  Future<void> run(List<String> arguments) async {
    final result = await Process.run(cli, arguments);
    check(result.exitCode == 0, '${result.stderr}');
  }

  try {
    final jpeg = '${temp.path}/preview.jpg';
    final avif = '${temp.path}/contact.avif';
    final captures = '${temp.path}/frames';
    await run(['preview', '--output', jpeg, _staggered]);
    check(
      image.decodeJpg(File(jpeg).readAsBytesSync())?.width == _width,
      'VP8 alpha JPEG preview',
    );
    await run(['extract', '-n3', '-T2', '--output-dir', captures, _staggered]);
    final frames = Directory(captures).listSync().whereType<File>().toList();
    check(frames.length == 3, 'VP8 alpha BMP count');
    for (final path in frames) {
      final bmp = image.decodeBmp(path.readAsBytesSync())!;
      check(
        _staggeredMasks.contains(_alphaHash(bmp)),
        'VP8 BMP exact transparency',
      );
    }
    await run([
      'vcs',
      '-c2',
      '-n3',
      '-H32',
      '-f3',
      '-t500ms',
      '-o',
      avif,
      _native,
    ]);
    final output = File(avif).readAsBytesSync();
    check(
      ascii.decode(output.sublist(4, 12)) == 'ftypavis',
      'VP8 alpha AVIF contact sheet',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/h264/access_unit.dart';
import 'package:vimg_dart/src/h264/container.dart';
import 'package:vimg_dart/src/h264/idr_picture.dart';
import 'package:vimg_dart/src/iso_frames.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/matroska_frames.dart';

import 'fixtures.dart';

// Synthetic 78×50 YUV encoded with x264 High Profile, two IDR frames and two
// slices per frame. Checksums use FFmpeg's decoded, cropped YUV420p planes
// with deblocking enabled.
const _expected = [
  [0xbf89f3e5, 0xd17539ad, 0xe0ee3d2d],
  [0x1124f8a0, 0x4679dbc8, 0x248ac689],
];

void _checkPlanes(String input) {
  final handle = File(input).openSync();
  try {
    final file = BinaryFile(handle);
    final isMatroska = input.endsWith('.mkv');
    final matroska = isMatroska ? Matroska(file) : null;
    final iso = isMatroska ? null : IsoMedia(file);
    final config = matroska == null
        ? isoAvcConfiguration(iso!)
        : matroskaAvcConfiguration(matroska);
    final packets = matroska == null
        ? isoFrames(iso!)
        : matroskaFrames(matroska);
    final decoder = H264IdrDecoder(AvcConfiguration(config!));
    var frames = 0;
    for (final packet in packets) {
      check(frames < _expected.length, 'Unexpected AVC packet');
      final picture = decoder.decode(file.read(packet.offset, packet.size))!;
      final sps = picture.sps;
      check(
        sps.profile == 100 && sps.width == 78 && sps.height == 50,
        'H.264 dimensions and profile',
      );
      for (final (index, plane) in [
        (0, picture.y),
        (1, picture.cb),
        (2, picture.cr),
      ]) {
        final shift = index == 0 ? 0 : 1;
        final stride = picture.stride >> shift;
        final hash = _checksum(
          plane,
          stride,
          ((sps.cropTop >> shift) * stride) + (sps.cropLeft >> shift),
          sps.width >> shift,
          sps.height >> shift,
        );
        check(
          hash == _expected[frames][index],
          'H.264 frame $frames plane $index differs from FFmpeg: ${hash.toRadixString(16)}',
        );
      }
      frames++;
    }
    check(frames == _expected.length, 'H.264 fixture frame count');
  } finally {
    handle.closeSync();
  }
}

int _checksum(Uint8List plane, int stride, int offset, int width, int height) {
  var hash = 0x811c9dc5;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      hash =
          ((hash ^ plane[offset + y * stride + x]) * 0x01000193) & 0xffffffff;
    }
  }
  return hash;
}

Future<void> main(List<String> arguments) async {
  const mkv = 'test/fixtures/cabac-idr.mkv';
  const mp4 = 'test/fixtures/cabac-idr.mp4';
  _checkPlanes(mkv);
  _checkPlanes(mp4);

  final directory = Directory.systemTemp.createTempSync('vimg-h264-test-');
  Future<String> run(List<String> args) async {
    final result = await Process.run(
      arguments.firstOrNull ?? Platform.resolvedExecutable,
      [if (arguments.isEmpty) 'bin/vimg.dart', ...args],
    );
    check(result.exitCode == 0, 'H.264 CLI failed: ${result.stderr}');
    return result.stdout as String;
  }

  try {
    final jpeg = File('${directory.path}/preview.jpg');
    for (final input in [mkv, mp4]) {
      final response =
          jsonDecode(
                await run([
                  'preview',
                  '--output',
                  jpeg.path,
                  '--max-width',
                  '39',
                  input,
                ]),
              )
              as Map;
      check(
        response['preview_written'] == true,
        'H.264 preview response: $response',
      );
      final decoded = image.decodeJpg(jpeg.readAsBytesSync())!;
      check(
        decoded.width == 39 && decoded.height == 25,
        'H.264 JPEG preview dimensions',
      );
    }

    final output = '${directory.path}/frames';
    await run(['extract', '-n1', '-t500ms', '--output-dir', output, mkv]);
    final bmp = Directory(output).listSync().single as File;
    final frame = image.decodeBmp(bmp.readAsBytesSync())!;
    check(frame.width == 78 && frame.height == 50, 'H.264 extracted BMP');

    final avif = File('${directory.path}/grid.avif');
    await run([
      'vcs',
      '-c2',
      '-n2',
      '-H24',
      '-f2',
      '-t500ms',
      '-o',
      avif.path,
      mp4,
    ]);
    check(
      ascii.decode(avif.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'H.264 animated contact sheet',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

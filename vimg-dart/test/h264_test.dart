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
const _idrPlanes = [
  [0xbf89f3e5, 0xd17539ad, 0xe0ee3d2d],
  [0x1124f8a0, 0x4679dbc8, 0x248ac689],
];

// Twelve frames using multiple references, weighted prediction and two slices.
const _pPlanes = [
  [0xb31104a6, 0x487edb44, 0x8f405e49],
  [0x99d0f526, 0x3ee4a477, 0x5ca5f999],
  [0x0f705928, 0x2d9b6e65, 0xc9253506],
  [0xe80c67ac, 0x5033de0e, 0xb98831d7],
  [0x34dee6fe, 0xd5cc08a9, 0x3e4f59ee],
  [0xd6310950, 0x8d4c5161, 0xe1e92887],
  [0xa50e40d6, 0x7a7cc41f, 0xdd4742df],
  [0x5c14d537, 0x99a1e53e, 0x3e3fff1f],
  [0xfb7d5331, 0x4279441e, 0x8459ff13],
  [0x7b5bd543, 0x6862dd3a, 0xf1985475],
  [0xd7365a8e, 0xe93b2a4c, 0x63899bdd],
  [0x0b3a07f4, 0xa6299768, 0x6165d8b5],
];

// Reference B pictures, implicit weights, spatial direct motion and two slices.
const _spatialBPlanes = [
  [0xd8ba8846, 0xc4a51824, 0xca288f69],
  [0x061d47fb, 0x5d2c2283, 0x33c08b57],
  [0x0f091492, 0x7dbfe7aa, 0xf8049edd],
  [0x70f1a5c8, 0xc5ec89e7, 0x9f9322fe],
  [0x27ab7865, 0x2d903402, 0x82b865fe],
  [0x2dbe44f2, 0x69e8c53d, 0xfd2e6885],
  [0x1544cecd, 0xe529fd22, 0x13963487],
  [0xc9c5a734, 0x1860b8d7, 0xc46c30c2],
  [0xba0078c4, 0x914f7a67, 0x7da69ea3],
  [0x2766d6df, 0x8b921aad, 0xce465826],
  [0x45733304, 0x54f8da98, 0x2f34e70e],
  [0xb3b8513e, 0xa86e9702, 0xa54c3f9f],
  [0x00185cff, 0x3e50cf6c, 0x31a213ef],
  [0x5f06c145, 0xf74834c9, 0x17ae6d1a],
  [0x3003848c, 0x0e34ecf1, 0xefce8d51],
  [0x34b3f49e, 0x5b97073d, 0xaa428190],
  [0x574916d9, 0x6e270572, 0xf6bc19c4],
];

// Temporal direct motion with an MP4 composition offset table.
const _temporalBPlanes = [
  [0x8bc55aa5, 0x4ebf3135, 0x0c0fab46],
  [0xc7631710, 0xfa9391c2, 0x7b7dace2],
  [0xaa91f8fb, 0x46435fc4, 0x28e440d8],
  [0xf4c25807, 0xabb4f2e2, 0xdc11f2a3],
  [0x272e0991, 0x04b2b1ed, 0xc61b06c2],
  [0x9c049078, 0xb807ac9e, 0x7e0d361a],
  [0xbc877cfb, 0xd5ffdc1a, 0xd1722ed4],
  [0xbae53dd6, 0xb5564d84, 0xc2ee0270],
  [0x91bcf4a1, 0xc9de3887, 0xdb141798],
  [0x0608d54d, 0x191445ca, 0xcdbd321c],
  [0xbfb32b70, 0x73ce0c78, 0x17a3dec7],
  [0x103621eb, 0x845265ff, 0x45e24e89],
  [0x7fa43a3b, 0xbcdf2c56, 0x0c38d255],
  [0xc62c84fe, 0x61e19c3d, 0xf64d0b5c],
  [0x6edd3b94, 0xb2e34ec1, 0x20e9661a],
  [0x75fe7b7a, 0xdaaf4c68, 0x97a18080],
  [0xeff7cd2e, 0xc5d312c6, 0xc104e449],
];

void _checkPlanes(
  String input,
  List<List<int>> expected, {
  bool inter = false,
  (int, int) dimensions = (78, 50),
}) {
  final handle = File(input).openSync();
  try {
    final file = BinaryFile(handle);
    final isMatroska = input.endsWith('.mkv');
    final matroska = isMatroska ? Matroska(file) : null;
    final iso = isMatroska ? null : IsoMedia(file);
    final config = matroska == null
        ? isoAvcConfiguration(iso!)
        : matroskaAvcConfiguration(matroska);
    final packets =
        (matroska == null ? isoFrames(iso!) : matroskaFrames(matroska))
            .toList();
    final display = [...packets]
      ..sort((a, b) => a.seconds.compareTo(b.seconds));
    final indexes = {for (var i = 0; i < display.length; i++) display[i]: i};
    check(indexes.length == expected.length, 'H.264 fixture frame count');
    final avc = AvcConfiguration(config!);
    final decode = inter
        ? H264StreamDecoder(avc).decode
        : H264IdrDecoder(avc).decode;
    for (final packet in packets) {
      final frame = indexes[packet]!;
      final picture = decode(file.read(packet.offset, packet.size))!;
      final sps = picture.sps;
      check(
        sps.profile == 100 && (sps.width, sps.height) == dimensions,
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
          hash == expected[frame][index],
          'H.264 $input frame $frame plane $index differs from FFmpeg: ${hash.toRadixString(16)}',
        );
      }
    }
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
  const interMkv = 'test/fixtures/cabac-p.mkv';
  const interMp4 = 'test/fixtures/cabac-p.mp4';
  const spatial = 'test/fixtures/cabac-b-spatial.mkv';
  const temporal = 'test/fixtures/cabac-b-temporal.mp4';
  _checkPlanes(mkv, _idrPlanes);
  _checkPlanes(mp4, _idrPlanes);
  _checkPlanes(interMkv, _pPlanes, inter: true);
  _checkPlanes(interMp4, _pPlanes, inter: true);
  _checkPlanes(spatial, _spatialBPlanes, inter: true, dimensions: (166, 110));
  _checkPlanes(temporal, _temporalBPlanes, inter: true, dimensions: (166, 110));

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
    await run(['extract', '-n1', '-t500ms', '--output-dir', output, interMkv]);
    final bmp = Directory(output).listSync().single as File;
    final frame = image.decodeBmp(bmp.readAsBytesSync())!;
    check(frame.width == 78 && frame.height == 50, 'H.264 extracted BMP');

    final avif = File('${directory.path}/grid.avif');
    final kept = '${directory.path}/kept';
    await run([
      'vcs',
      '-c2',
      '-n2',
      '-H24',
      '-f3',
      '-t500ms',
      '--keep',
      '--output-dir',
      kept,
      '-o',
      avif.path,
      temporal,
    ]);
    check(
      ascii.decode(avif.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'H.264 animated contact sheet',
    );
    check(
      Directory(kept).listSync().length == 6,
      'H.264 kept B-frame captures',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

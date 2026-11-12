import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/h264/access_unit.dart';
import 'package:vimg_dart/src/video_configuration.dart';
import 'package:vimg_dart/src/h264/idr_picture.dart';
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

// Baseline I/P with two slices and multiple reference pictures.
const _cavlcBaselinePlanes = [
  [0x10cbd312, 0x50f12dd2, 0x807a7f4f],
  [0x4c03e113, 0x0eb332ae, 0x7c617f94],
  [0x47fbc934, 0x1a4987c0, 0xf5ee9455],
  [0xb1c64ee1, 0x047adb3b, 0x7fc2bf15],
  [0xc36ea976, 0xd030b7dc, 0x60685890],
  [0x5fa23879, 0x1a8c707d, 0x36801772],
  [0x8b844433, 0x23f965b3, 0x7962f9d4],
  [0xfc7c04a0, 0x7aa69598, 0xb0569c85],
  [0x5f9a7aba, 0x9396c075, 0xe68fc870],
  [0x7ca03dad, 0x0445eb52, 0xf1f81a92],
  [0xf7cb8561, 0x6d2021cf, 0x730fdc11],
  [0x317a9073, 0x4bc34d9c, 0xf0a33e51],
  [0x32921e1e, 0x292b9e13, 0xf390d681],
  [0xffdf8dc6, 0xbee2e104, 0x0ba8411d],
  [0x330e1594, 0x4a28b8e3, 0x60491e63],
  [0xa89c5b77, 0x4cbc38bc, 0x9940fa4c],
  [0x4120a30e, 0xe371215a, 0xaeed232b],
];

// High Profile I/P/B with 8×8 transforms, two slices and reference B pictures.
const _cavlcHighPlanes = [
  [0x19dadf59, 0x990a7386, 0xcc5fae9f],
  [0xf966bb60, 0x7d05e55b, 0x5f239a97],
  [0x3f4675cf, 0xc97ab978, 0xfcf81f21],
  [0xaafab400, 0xbfdbf354, 0xb67de6e7],
  [0x71b5e73a, 0x88ebd7c6, 0x2558bf67],
  [0xf4017d3f, 0xc780e07b, 0xa0e01471],
  [0xeabeff43, 0xd7f7c93e, 0x47e095a3],
  [0x7b6726fe, 0x1f367434, 0x7cb5c348],
  [0x6f699b21, 0x92955d69, 0xe83e60f8],
  [0x22ffcbd3, 0x137be89e, 0x29cbe22b],
  [0x61de7875, 0x321ba124, 0x36d05f58],
  [0x88888c0b, 0x6e46572b, 0x78e8b1af],
  [0x77a469b2, 0x97523f20, 0x3432c6d8],
  [0x0c91b004, 0xf6d91a23, 0xba3a5238],
  [0xfafcedd3, 0x9c11855a, 0x3d2490ba],
  [0x910dfcc7, 0x342e2d04, 0xb0d3b433],
  [0x2e581ec3, 0xa76e0486, 0xc17aa016],
];

void _checkPlanes(
  String input,
  List<List<int>> expected, {
  bool inter = false,
  bool cabac = true,
  int profile = 100,
  (int, int) dimensions = (78, 50),
}) {
  final handle = File(input).openSync();
  try {
    final file = BinaryFile(handle);
    final isMatroska = input.endsWith('.mkv');
    final matroska = isMatroska ? Matroska(file) : null;
    final iso = isMatroska ? null : IsoMedia(file);
    final config = matroska == null
        ? isoVideoConfiguration(iso!, 'h264')
        : matroskaVideoConfiguration(matroska, 'h264');
    final packets =
        (matroska == null ? isoFrames(iso!) : matroskaFrames(matroska))
            .toList();
    final display = [...packets]
      ..sort((a, b) => a.seconds.compareTo(b.seconds));
    final indexes = {for (var i = 0; i < display.length; i++) display[i]: i};
    check(indexes.length == expected.length, 'H.264 fixture frame count');
    final avc = AvcConfiguration(config!);
    check(
      avc.pictures.values.every((pps) => pps.cabac == cabac),
      'H.264 fixture entropy mode',
    );
    final decode = inter
        ? H264StreamDecoder(avc).decode
        : H264IdrDecoder(avc).decode;
    for (final packet in packets) {
      final frame = indexes[packet]!;
      final picture = decode(file.read(packet.offset, packet.size))!;
      final sps = picture.sps;
      check(
        sps.profile == profile && (sps.width, sps.height) == dimensions,
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
  const cavlcBaseline = 'test/fixtures/cavlc-baseline.mp4';
  const cavlcHigh = 'test/fixtures/cavlc-high.mkv';
  _checkPlanes(mkv, _idrPlanes);
  _checkPlanes(mp4, _idrPlanes);
  _checkPlanes(interMkv, _pPlanes, inter: true);
  _checkPlanes(interMp4, _pPlanes, inter: true);
  _checkPlanes(spatial, _spatialBPlanes, inter: true, dimensions: (166, 110));
  _checkPlanes(temporal, _temporalBPlanes, inter: true, dimensions: (166, 110));
  _checkPlanes(
    cavlcBaseline,
    _cavlcBaselinePlanes,
    inter: true,
    cabac: false,
    profile: 66,
    dimensions: (166, 110),
  );
  _checkPlanes(
    cavlcHigh,
    _cavlcHighPlanes,
    inter: true,
    cabac: false,
    dimensions: (166, 110),
  );

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
    for (final (input, width, height) in [
      (mkv, 39, 25),
      (mp4, 39, 25),
      (cavlcBaseline, 83, 55),
    ]) {
      final response =
          jsonDecode(
                await run([
                  'preview',
                  '--output',
                  jpeg.path,
                  '--max-width',
                  '$width',
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
        decoded.width == width && decoded.height == height,
        'H.264 JPEG preview dimensions',
      );
    }

    for (final (input, width, height) in [
      (interMkv, 78, 50),
      (cavlcBaseline, 166, 110),
    ]) {
      final output = '${directory.path}/frames-$width';
      await run(['extract', '-n1', '-t500ms', '--output-dir', output, input]);
      final bmp = Directory(output).listSync().single as File;
      final frame = image.decodeBmp(bmp.readAsBytesSync())!;
      check(
        frame.width == width && frame.height == height,
        'H.264 extracted BMP',
      );
    }

    for (final (mode, input) in [('cabac', temporal), ('cavlc', cavlcHigh)]) {
      final avif = File('${directory.path}/grid-$mode.avif');
      final kept = '${directory.path}/kept-$mode';
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
        input,
      ]);
      check(
        ascii.decode(avif.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
        'H.264 animated contact sheet',
      );
      final captures = Directory(kept).listSync().cast<File>();
      check(captures.length == 6, 'H.264 kept B-frame captures');
      for (final capture in captures) {
        final frame = image.decodeBmp(capture.readAsBytesSync())!;
        check(
          frame.width == 166 && frame.height == 110,
          'H.264 --keep retains the original capture dimensions',
        );
      }
    }
  } finally {
    directory.deleteSync(recursive: true);
  }
}

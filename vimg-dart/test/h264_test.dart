import 'dart:convert';
import 'dart:io';

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

// 10-bit ramps, motion and fades with I/P/B pictures, cropping and two slices.
// The CAVLC stream also exercises negative slice QP.
const _high10CabacPlanes = [
  [0x756f8f3a, 0x4b9da04c, 0xe1f970ce],
  [0xb40fd956, 0x38490590, 0xa237e644],
  [0xb46018f9, 0xbb254034, 0xddd5af28],
  [0x868a4dcf, 0xdcbf7c61, 0x8b30a5e4],
  [0x086f9872, 0x3920483b, 0xf189ac7e],
  [0x104ad48c, 0x124732f5, 0x0681c858],
  [0x3d261238, 0x2c827d95, 0x8ffe2994],
  [0x2bdf0f1a, 0x58d4936c, 0xcb11850b],
  [0x2a7b487a, 0x68e305e0, 0x99695540],
  [0x1df90ead, 0xe4752130, 0x1d4dee77],
  [0xad28cfcd, 0x9b769ee4, 0x812cef96],
  [0x74edc0a0, 0x5b421c15, 0x95028451],
  [0x591f50e3, 0xbb493c54, 0x704fe875],
  [0x9b8030c8, 0xa806497f, 0x9d260c1c],
  [0x84e200a8, 0x946b2f58, 0xc8b2e298],
  [0x5babd3fd, 0x8a7ee623, 0xb031b9ff],
];

const _high10CavlcPlanes = [
  [0x33f100d9, 0x0ab8775f, 0x817d1ec6],
  [0xeec2729c, 0xa6032d3e, 0x226ed26b],
  [0x1309362c, 0x837dcddf, 0x676e72b2],
  [0xa1e0667f, 0x10d70287, 0xcc469c44],
  [0xa1534b6c, 0x94f87484, 0x652a2997],
  [0x8e4ec8d0, 0xc3a9a11c, 0x2c8d8694],
  [0x612801b6, 0x22c07c7f, 0x59ced4fc],
  [0x76cd3f18, 0x9893e6cb, 0xe4998b10],
  [0x21b6dc9e, 0xc4995c55, 0xfe851dd8],
  [0x048add8a, 0x4e4db0d7, 0x4beef889],
  [0x3c4955b1, 0x220058d4, 0xd7f64246],
  [0x8c57d7be, 0xadd7df31, 0x54291ca8],
  [0x69a3ebda, 0xf94ec89c, 0x42a8f9fa],
  [0xbba32d5a, 0x5f4bb4b6, 0x6bf252c9],
  [0xb429479a, 0xd5623563, 0xd921cd13],
  [0x058ec3fd, 0xe34f9946, 0x08a60635],
];

// High 10 monochrome with intra and inter prediction.
const _high10MonochromePlanes = [
  [0xe21637d1],
  [0x99197636],
  [0xe68843f7],
  [0x49c02a90],
  [0x1eb66953],
  [0x4788d1fc],
];

// One 9-bit picture with two I_PCM macroblocks.
const _high10Pcm9Planes = [
  [0x10b95145, 0x21b90145, 0x2ec7f3c5],
];

// Checksums of the original raw input to x264 --qp 0. Both streams use
// 4×4, 8×8 and 16×16 intra prediction and 4×4 and 8×8 inter residuals.
const _losslessCabacPlanes = [
  [0xf5f6873b, 0xf07bfb90, 0xc6bc45bc],
  [0x1aeed8cb, 0xc0f291ba, 0xe5b25de4],
  [0x99626e4b, 0xb5bc6f38, 0x1a385298],
  [0xab95326f, 0x32c9ce02, 0xe6a21398],
  [0x9cf2e71b, 0x8cae6a00, 0x74087f7c],
  [0x0008e3d7, 0xf16df162, 0x19f2e51c],
  [0x00e5516b, 0x0d366060, 0xbab05eb0],
];

const _losslessCavlcPlanes = [
  [0x33544995, 0xf5a3bdb0, 0xe921d259],
  [0x1cb2e1dd, 0x2dcb4c1b, 0x5a1a93d0],
  [0xd28fda1d, 0x2337e4e2, 0xf16e6c33],
  [0xd82b624d, 0xe7490309, 0x31024d5a],
  [0x622ad135, 0x50108408, 0xe76d4f39],
  [0x447c691d, 0xd1d6d28b, 0x3fee51e8],
  [0x1c614efd, 0xf29e0aaa, 0x96f3f7f3],
];

void _checkPlanes(
  String input,
  List<List<int>> expected, {
  bool inter = false,
  bool cabac = true,
  int profile = 100,
  int depth = 8,
  bool monochrome = false,
  bool lossless = false,
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
        sps.profile == profile &&
            sps.lumaDepth == depth &&
            sps.chromaDepth == depth &&
            sps.chromaFormat == (monochrome ? 0 : 1) &&
            sps.transformBypass == lossless &&
            (sps.width, sps.height) == dimensions,
        'H.264 dimensions, bit depth and profile',
      );
      for (final (index, plane) in [
        (0, picture.y),
        if (!monochrome) ...[(1, picture.cb), (2, picture.cr)],
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
          'H.264 $input frame $frame plane $index differs from reference: ${hash.toRadixString(16)}',
        );
      }
    }
  } finally {
    handle.closeSync();
  }
}

int _checksum(List<int> plane, int stride, int offset, int width, int height) {
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
  const high10Cabac = 'test/fixtures/high10-cabac.mkv';
  const high10Cavlc = 'test/fixtures/high10-cavlc.mp4';
  const high10Monochrome = 'test/fixtures/high10-mono.mkv';
  const losslessCabac = 'test/fixtures/lossless-avc-cabac.mkv';
  const losslessCavlc = 'test/fixtures/lossless-avc-cavlc.mp4';
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

  _checkPlanes(
    high10Cabac,
    _high10CabacPlanes,
    inter: true,
    profile: 110,
    depth: 10,
    dimensions: (94, 62),
  );
  _checkPlanes(
    high10Cavlc,
    _high10CavlcPlanes,
    inter: true,
    cabac: false,
    profile: 110,
    depth: 10,
    dimensions: (94, 62),
  );

  _checkPlanes(
    high10Monochrome,
    _high10MonochromePlanes,
    inter: true,
    profile: 110,
    depth: 10,
    monochrome: true,
    dimensions: (94, 62),
  );
  _checkPlanes(
    'test/fixtures/high10-pcm9.mp4',
    _high10Pcm9Planes,
    cabac: false,
    profile: 110,
    depth: 9,
    dimensions: (32, 16),
  );

  _checkPlanes(
    losslessCabac,
    _losslessCabacPlanes,
    inter: true,
    lossless: true,
    profile: 244,
    dimensions: (94, 62),
  );
  _checkPlanes(
    losslessCavlc,
    _losslessCavlcPlanes,
    inter: true,
    cabac: false,
    lossless: true,
    profile: 244,
    depth: 10,
    dimensions: (94, 62),
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
      (high10Cabac, 47, 31),
      (high10Monochrome, 47, 31),
      (losslessCabac, 47, 31),
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
      (high10Cavlc, 94, 62),
      (losslessCavlc, 94, 62),
      (cavlcBaseline, 166, 110),
    ]) {
      final name = input.split('/').last;
      final output = '${directory.path}/frames-$name';
      await run(['extract', '-n1', '-t500ms', '--output-dir', output, input]);
      final bmp = Directory(output).listSync().single as File;
      final frame = image.decodeBmp(bmp.readAsBytesSync())!;
      check(
        frame.width == width && frame.height == height,
        'H.264 extracted BMP',
      );
    }

    for (final (mode, input, width, height) in [
      ('cabac', temporal, 166, 110),
      ('cavlc', cavlcHigh, 166, 110),
      ('high10', high10Cabac, 94, 62),
      ('lossless', losslessCavlc, 94, 62),
    ]) {
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
          frame.width == width && frame.height == height,
          'H.264 --keep retains the original capture dimensions',
        );
      }
    }
  } finally {
    directory.deleteSync(recursive: true);
  }
}

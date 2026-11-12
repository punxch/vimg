import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/hevc/access_unit.dart';
import 'package:vimg_dart/src/hevc/cabac.dart';
import 'package:vimg_dart/src/hevc/contexts.dart';
import 'package:vimg_dart/src/hevc/decode_picture.dart';
import 'package:vimg_dart/src/hevc/nal.dart';
import 'package:vimg_dart/src/hevc/picture.dart';
import 'package:vimg_dart/src/hevc/picture_order.dart';
import 'package:vimg_dart/src/hevc/slice_header.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/matroska_frames.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/video_configuration.dart';

import 'fixtures.dart';

// x265 encode order and FFmpeg trace_headers for the two synthetic clips.
const _mainPocs = [0, 3, 2, 1, 6, 5, 4, 8, 7, 11, 10, 9, 14, 13, 12, 16, 15];
const _mainQps = [
  29,
  29,
  31,
  32,
  29,
  31,
  32,
  28,
  32,
  29,
  31,
  32,
  29,
  31,
  32,
  28,
  32,
];
const _mainNalTypes = [20, 1, 1, 0, 1, 1, 0, 21, 8, 1, 1, 0, 1, 1, 0, 21, 8];
const _mainEntries = [
  1697,
  1274,
  479,
  262,
  918,
  322,
  447,
  1769,
  154,
  721,
  291,
  213,
  445,
  321,
  225,
  1577,
  227,
];

const _main = 'test/fixtures/hevc-main.mkv';
const _main10 = 'test/fixtures/hevc-main10.mp4';
const _allIntra = 'test/fixtures/hevc-all-intra.mkv';
const _pcmTiles = 'test/fixtures/hevc-pcm-tiles.mkv';
const _main422 = 'test/fixtures/hevc-422-10.mkv';
const _main444 = 'test/fixtures/hevc-444-12.mp4';

// FFmpeg's cropped YUV planes, with all signalled loop filters applied.
const _mainPixels = [
  [0x59eda39e, 0xcf9ede00, 0x6efc8edf],
  [0x4782a590, 0x93f22eb0, 0x9b8a2498],
  [0x99136796, 0xf10cbc42, 0x13b985e2],
  [0xe5cbc37b, 0x793b468a, 0x202b5d1f],
  [0x089f1ad1, 0x1f66e631, 0xad6ed05c],
  [0xe32a9f74, 0x05d5af9a, 0x1dcb2c79],
  [0x02ec3d35, 0x5c78898a, 0xed104a30],
  [0x27232321, 0x5b29c31f, 0x95717888],
  [0x55ad8459, 0x1ee482e3, 0xd2ff8a30],
  [0x589dfa17, 0x6dc1a53b, 0x3d230724],
  [0xcd97a416, 0x1945f28a, 0x0774a7d4],
  [0x116d681c, 0x2e9ed56a, 0xb73b1f13],
  [0x0f02d055, 0x014881bc, 0x671f7287],
  [0x4d028159, 0x1bb89ae5, 0xf99ebd78],
  [0x4b8b262d, 0x2fcb018f, 0xd5671ef0],
  [0x39b27a9d, 0xa54979d1, 0x08460125],
  [0xac8b7cdf, 0xf2e17a01, 0x8bd68d11],
];
const _main10Pixels = [
  [0xf9e6edad, 0x0587d4fe, 0xb89451b0],
  [0xb6dbf8b5, 0x8c43718f, 0xd43b0727],
  [0x88f460e0, 0xde9fa9c0, 0x57594ed6],
  [0x6071961c, 0xf662b52a, 0x8d22cbb5],
  [0x3ba34192, 0x96abc6d6, 0x46a01c2e],
  [0x942a9fde, 0x1439c331, 0xc76dddb8],
  [0x2987d303, 0x881d0080, 0xcef5f016],
  [0x1861732a, 0xe7914fa5, 0xebffb2d4],
  [0xeacac47e, 0xd87aecf5, 0xb090d620],
  [0x05522c00, 0xd83f2a1d, 0xa4557f6b],
  [0x874d7df2, 0xe865a8df, 0x734d4385],
  [0x4e1714c3, 0x79e2e246, 0x48f75eaf],
];
const _allIntraPixels = [
  [0x699a9741, 0x0291ec9b, 0x48e00d81],
  [0xb7705191, 0xb2a831fe, 0x729f8832],
  [0x9286709a, 0xf6bc2ec8, 0xd2610260],
  [0x7c9d9ffb, 0xfd58bebf, 0xd2e6c798],
  [0x07666432, 0x145a7c72, 0xb0143536],
];

Future<void> main(List<String> arguments) async {
  _check(_main, main10: false);
  _check(_main10, main10: true);
  _checkIntraClip(_allIntra, _allIntraPixels);
  _checkIntraClip(_pcmTiles, [
    [0x00729694, 0x036a662d, 0x8a7f1505],
  ]);
  _checkInterClip('test/fixtures/hevc-inter-tiles.mkv', [
    [0x1e051d05, 0xbb0d91d8, 0x6c1c1a14],
    [0x689cdc77, 0x7d1b1e81, 0x7d5020d2],
    [0x65f2f207, 0xe131f650, 0xa94f3a99],
    [0x9b5c161d, 0xf22d0492, 0xf2576d30],
  ]);
  _checkInterClip('test/fixtures/hevc-inter-weighted.mkv', [
    [0x6599cd9f, 0xe0d60351, 0x73bce97a],
    [0xba3a7ef9, 0x9f1d744c, 0x5408e280],
    [0x834affc8, 0xf80a395a, 0xff503e8e],
    [0xa94b4f8c, 0x8c8b967c, 0x0e25c458],
    [0xea6420d4, 0x4b5d5892, 0x7a6fa18f],
    [0x2b913e92, 0xdd80d4bf, 0xf5b301be],
  ]);
  // Two closed GOPs with I/P/B pictures, SAO, deblocking and a cropped CTU
  // boundary. Plane hashes use FFmpeg's decoded samples in presentation order.
  _checkInterClip(
    _main422,
    [
      [0xfa39ea15, 0xa51f714d, 0xa51f714d],
      [0x3ff5eec5, 0xdeb9b78e, 0x33dddf14],
      [0x4a8af374, 0x40b05f9f, 0x30a478f7],
      [0x82998cb9, 0x0b6157eb, 0x1e90595b],
      [0x02c6cf59, 0x4ae72c39, 0x2c8b4d60],
      [0xa94304c9, 0xc6ab24db, 0xd9a40f21],
      [0xc032f741, 0x9511f98a, 0x1f7e2ed6],
      [0x6c9cbaad, 0x52fa47a9, 0xe0179e48],
      [0x43892d51, 0x0f75fbd9, 0xad117ae4],
      [0x41b588ba, 0xf8d2b559, 0xab8702d9],
      [0x43ad4010, 0x9a0a4ebc, 0x4a5b36d9],
      [0x94a0cbea, 0xc2a8a3bf, 0x200df3e5],
      [0x7b05cab6, 0xc57fd107, 0x7d35367c],
      [0xf156590a, 0x656610dc, 0x46ad8736],
      [0x7cbc763b, 0xccbbb949, 0x0b1a6b65],
      [0xda9a2e09, 0xcab375f4, 0x2b02a818],
    ],
    format: 2,
    depth: 10,
  );
  _checkInterClip(
    _main444,
    [
      [0x11043139, 0xa781c015, 0xa781c015],
      [0x537c3e0d, 0x3ad6f109, 0x05f021fd],
      [0x6448a965, 0x032144be, 0xc001a187],
      [0x90e2d128, 0x0ec98754, 0x99072b34],
      [0xe8c58867, 0x1bb75d99, 0xce13c8f5],
      [0x83da50b0, 0xceef8629, 0xbecff2cc],
      [0xbbd2f362, 0x0df7ab7f, 0x9bfb1e47],
      [0xd3f09456, 0x9b0a81b5, 0x0aafa6ce],
      [0x8ccd7124, 0x158dd996, 0x868cc623],
      [0x67fe5817, 0x9fa267dc, 0xba1e9a1c],
      [0x8a4a038c, 0x481dbca0, 0x4f9c982f],
      [0xbc7383ea, 0x83ef9edf, 0x31e15c68],
      [0xfe074175, 0xf23a3796, 0x3d6712f3],
      [0x627ae710, 0x3044b8b4, 0xe0406ff6],
      [0x502c0db2, 0x45451ef5, 0x7afef9bc],
      [0x5755ec86, 0x1207b95a, 0x7955a1a9],
    ],
    format: 3,
    depth: 12,
  );
  await _checkCli(arguments);
}

void _check(String path, {required bool main10}) {
  final handle = File(path).openSync();
  try {
    final file = BinaryFile(handle);
    final mkv = main10 ? null : Matroska(file);
    final iso = main10 ? IsoMedia(file) : null;
    final config = mkv != null
        ? matroskaVideoConfiguration(mkv, 'hevc')!
        : isoVideoConfiguration(iso!, 'hevc')!;
    final parser = HevcConfiguration(config);
    final decoder = HevcIntraDecoder(HevcConfiguration(config));
    final stream = HevcStreamDecoder(HevcConfiguration(config));
    final rgb = <int, Uint8List>{};
    final expected = main10 ? _main10Pixels : _mainPixels;
    final vps = parser.videos.values.single;
    final sps = parser.sequences.values.single;
    final pps = parser.pictures.values.single;
    final depth = main10 ? 10 : 8;
    check(vps.profile.id == (main10 ? 2 : 1), 'HEVC VPS profile');
    check((sps.width, sps.height) == (166, 110), 'HEVC conformance crop');
    check(
      (sps.codedWidth, sps.codedHeight) == (168, 112),
      'HEVC coded dimensions',
    );
    check(
      (sps.lumaDepth, sps.chromaDepth) == (depth, depth),
      'HEVC bit depths',
    );
    check(
      (sps.ctbWidth, sps.ctbHeight) == (3, 2) && pps.wavefront,
      'HEVC CTU and WPP configuration',
    );
    _expectFormatError(
      () => HevcConfiguration(
        Uint8List.sublistView(config, 0, config.length - 1),
      ),
    );

    final order = HevcPictureOrder();
    HevcPictureOrder? seek;
    var index = 0;
    for (final packet in mkv != null ? matroskaFrames(mkv) : isoFrames(iso!)) {
      final bytes = file.read(packet.offset, packet.size);
      final slices = parser.slices(bytes);
      check(slices.length == (main10 ? 2 : 1), 'HEVC slice count');
      final first = slices.first;
      final expectedPoc = main10 ? index : _mainPocs[index];
      final actual = order.observe(first);
      check(
        actual.poc == expectedPoc && actual.output && !actual.discardRasl,
        'HEVC decode-order POC',
      );
      check(packet.seconds == expectedPoc / 8, 'HEVC container PTS');
      final expectedNal = main10
          ? (index == 0 ? 20 : (index == 6 ? 21 : 1))
          : _mainNalTypes[index];
      final random = expectedNal >= 16;
      check(
        first.nal.type == expectedNal &&
            parser.containsRandomAccess(
                  packet.offset,
                  packet.size,
                  file.unsigned,
                ) ==
                random,
        'HEVC IRAP detection',
      );
      final picture = stream.decode(bytes)!;
      _checkPixels(
        picture,
        expected[expectedPoc],
        '$path picture $expectedPoc',
      );
      rgb[expectedPoc] = picture.rgb().getBytes();
      if (random) {
        _checkPixels(
          decoder.decode(bytes)!,
          expected[expectedPoc],
          '$path standalone picture $expectedPoc',
        );
      }
      final qp = main10 ? (index == 6 ? 27 : 29) : _mainQps[index];
      for (final (sliceIndex, slice) in slices.indexed) {
        check(
          slice.address == 3 * sliceIndex && slice.parameters.qp == qp,
          'HEVC slice position and QP',
        );
        final streams = slice.substreams().toList();
        check(
          streams.length == (main10 ? 1 : 2),
          'HEVC entropy substream count',
        );
        if (!main10) {
          check(
            streams.first.bytes.length == _mainEntries[index],
            'HEVC WPP entry point',
          );
        }
        final cabac = HevcCabac(streams.first, slice.parameters);
        if (!main10 && index < 3) {
          check(
            cabac.copyModels()[HevcContext.splitCuFlag.offset] ==
                [2, 38, 42][index],
            'HEVC I/P/B CABAC initialization',
          );
        }
      }
      if (!main10 && index == 0) _checkPrevention(first);
      if (!main10 && index == 7) seek = HevcPictureOrder();
      if (!main10 && seek != null && index <= 9) {
        final afterSeek = seek.observe(first);
        check(
          afterSeek.poc == expectedPoc && afterSeek.discardRasl == (index == 8),
          'HEVC CRA leading picture',
        );
      }
      index++;
    }
    check(index == (main10 ? 12 : _mainPocs.length), 'HEVC sample count');
    _checkTimeline(
      path,
      rgb,
      main10
          ? [
              [2, 6, 11],
            ]
          : [
              [7],
              [8, 7, 9],
              [2, 8, 15],
              [11],
            ],
    );
  } finally {
    handle.closeSync();
  }
}

void _checkTimeline(
  String path,
  Map<int, Uint8List> expected,
  List<List<int>> selections,
) {
  final video = Video(path);
  try {
    final packets = video.packets().toList();
    for (final (index, packet) in packets.indexed) {
      check(packet.seconds == index / 8, 'HEVC timeline is in display order');
    }
    for (final indexes in selections) {
      final decoded = video
          .decodeSelected(indexes.map((i) => packets[i]))
          .toList();
      final selected = indexes.map((i) => packets[i]).toSet();
      check(decoded.length == selected.length, 'HEVC sparse decode count');
      for (final result in decoded) {
        check(selected.remove(result.packet), 'HEVC sparse decode identity');
        final index = (result.packet.seconds * 8).round();
        final bytes = result.frame.getBytes();
        final oracle = expected[index]!;
        check(
          bytes.length == oracle.length &&
              bytes.asMap().entries.every((e) => e.value == oracle[e.key]),
          'HEVC picture $index differs after a seek',
        );
      }
    }
  } finally {
    video.close();
  }
}

void _checkIntraClip(String path, List<List<int>> expected) {
  final handle = File(path).openSync();
  try {
    final file = BinaryFile(handle);
    final mkv = Matroska(file);
    final decoder = HevcIntraDecoder(
      HevcConfiguration(matroskaVideoConfiguration(mkv, 'hevc')!),
    );
    var index = 0;
    for (final packet in matroskaFrames(mkv)) {
      final picture = decoder.decode(file.read(packet.offset, packet.size))!;
      _checkPixels(picture, expected[index], '$path picture $index');
      index++;
    }
    check(index == expected.length, 'HEVC intra fixture frame count');
  } finally {
    handle.closeSync();
  }
}

void _checkInterClip(
  String path,
  List<List<int>> expected, {
  int format = 1,
  int depth = 8,
}) {
  final handle = File(path).openSync();
  try {
    final file = BinaryFile(handle);
    final mkv = path.endsWith('.mkv') ? Matroska(file) : null;
    final iso = mkv == null ? IsoMedia(file) : null;
    final configuration = mkv == null
        ? isoVideoConfiguration(iso!, 'hevc')!
        : matroskaVideoConfiguration(mkv, 'hevc')!;
    final decoder = HevcStreamDecoder(HevcConfiguration(configuration));
    final packets = mkv == null ? isoFrames(iso!) : matroskaFrames(mkv);
    final seen = <int>{};
    for (final packet in packets) {
      final index = (packet.seconds * 8).round();
      check(seen.add(index), 'HEVC fixture PTS must be unique');
      final picture = decoder.decode(file.read(packet.offset, packet.size))!;
      final sps = picture.sps;
      check(
        (sps.chromaArrayType, sps.lumaDepth, sps.chromaDepth) ==
            (format, depth, depth),
        'HEVC sample format and bit depth',
      );
      _checkPixels(picture, expected[index], '$path picture $index');
    }
    check(seen.length == expected.length, 'HEVC inter fixture frame count');
  } finally {
    handle.closeSync();
  }
}

void _checkPixels(HevcPicture picture, List<int> expected, String name) {
  final sps = picture.sps;
  for (final (index, plane) in [
    picture.luma,
    picture.cb!,
    picture.cr!,
  ].indexed) {
    final sx = index == 0 ? 0 : sps.chromaShiftX;
    final sy = index == 0 ? 0 : sps.chromaShiftY;
    final width = sps.width >> sx, height = sps.height >> sy;
    final top = sps.crop.top >> sy, left = sps.crop.left >> sx;
    var hash = 0x811c9dc5;
    for (var row = 0; row < height; row++) {
      final start = (top + row) * plane.width + left;
      for (var col = 0; col < width; col++) {
        hash = ((hash ^ plane.samples[start + col]) * 0x01000193) & 0xffffffff;
      }
    }
    check(
      hash == expected[index],
      'HEVC $name plane $index differs from FFmpeg',
    );
  }
}

Future<void> _checkCli(List<String> arguments) async {
  final directory = Directory.systemTemp.createTempSync('vimg-hevc-test-');
  Future<String> run(List<String> options) async {
    final result = await Process.run(
      arguments.firstOrNull ?? Platform.resolvedExecutable,
      [if (arguments.isEmpty) 'bin/vimg.dart', ...options],
    );
    check(result.exitCode == 0, 'HEVC CLI failed: ${result.stderr}');
    return result.stdout as String;
  }

  try {
    for (final (input, skip, height) in [
      (_main, 0, 55),
      (_main, 50, 55),
      (_main10, 0, 55),
      (_main422, 50, 63),
      (_main444, 50, 63),
    ]) {
      final jpeg = File('${directory.path}/preview.jpg');
      final response =
          jsonDecode(
                await run([
                  'preview',
                  '--output',
                  jpeg.path,
                  '--max-width',
                  '83',
                  '--skip',
                  '$skip',
                  input,
                ]),
              )
              as Map;
      check(response['preview_written'] == true, 'HEVC preview response');
      final decoded = image.decodeJpg(jpeg.readAsBytesSync())!;
      check(
        (decoded.width, decoded.height) == (83, height),
        'HEVC JPEG dimensions',
      );
    }
    for (final (index, (input, width, height)) in [
      (_allIntra, 166, 110),
      (_main, 166, 110),
      (_main10, 166, 110),
      (_main422, 130, 98),
      (_main444, 130, 98),
    ].indexed) {
      final output = '${directory.path}/frames-$index';
      await run(['extract', '-n2', '-t200ms', '--output-dir', output, input]);
      final files = Directory(output).listSync().cast<File>();
      check(files.length == 2, 'HEVC BMP count');
      for (final file in files) {
        final bmp = image.decodeBmp(file.readAsBytesSync())!;
        check(
          (bmp.width, bmp.height) == (width, height),
          'HEVC BMP dimensions',
        );
      }
    }
    final avif = File('${directory.path}/grid.avif');
    await run([
      'vcs',
      '-c2',
      '-n2',
      '-H24',
      '-f3',
      '-t400ms',
      '-o',
      avif.path,
      _main444,
    ]);
    check(
      ascii.decode(avif.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'HEVC animated contact sheet',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

void _checkPrevention(HevcSliceHeader original) {
  final nal = HevcNal(Uint8List.fromList([0x28, 1, 0x80, 0, 0, 3, 1, 0xf0, 1]));
  final bits = nal.rbsp()..readStopBit();
  final slice = HevcSliceHeader(
    nal: original.nal,
    sps: original.sps,
    pps: original.pps,
    first: true,
    dependent: false,
    address: 0,
    discardPrior: false,
    parameters: original.parameters,
    entryLengths: [4],
    bits: bits,
  );
  final streams = slice.substreams().toList();
  check(
    streams.first.read(24) == 1 && streams.last.read(16) == 0xf001,
    'HEVC entry point with prevention byte',
  );
}

void _expectFormatError(void Function() run) {
  try {
    run();
  } on FormatException {
    return;
  }
  throw StateError('Expected malformed HEVC data to fail');
}

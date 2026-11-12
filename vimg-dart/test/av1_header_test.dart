import 'dart:io';
import 'dart:typed_data';

import 'package:vimg_dart/src/av1/access_units.dart';
import 'package:vimg_dart/src/av1/bitstream.dart';
import 'package:vimg_dart/src/av1/frame_header.dart';
import 'package:vimg_dart/src/av1/range_decoder.dart';
import 'package:vimg_dart/src/avif_animation.dart';

import 'fixtures.dart';

// FFmpeg testsrc2 at 256×144, 20 fps, 17 frames, yuv420p10le.
// SVT-AV1 with CRF 33, preset 10, hierarchical levels 3, 2×2 tiles and
// film grain level 8. The IVF packets were copied into AVIF with FFmpeg.
// Fields below were checked against FFmpeg trace_headers.
const _fixture = 'test/fixtures/av1-svt-tiled.avif';
const _frames = [
  // Order hint, existing slot, presentation sample, quantizer, refresh, tile bytes.
  (0, -1, 0, 66, 255, 3933),
  (8, -1, 1, 81, 2, 3487),
  (4, -1, 1, 108, 16, 1767),
  (2, -1, 1, 116, 32, 1294),
  (1, -1, 1, 132, 0, 1011),
  (2, 5, 2, 116, 0, 0),
  (3, -1, 3, 132, 0, 1038),
  (4, 4, 4, 108, 0, 0),
  (6, -1, 5, 116, 32, 1279),
  (5, -1, 5, 132, 0, 1248),
  (6, 5, 6, 116, 0, 0),
  (7, -1, 7, 132, 0, 925),
  (8, 1, 8, 81, 0, 0),
  (16, -1, 9, 100, 4, 2509),
  (12, -1, 9, 106, 8, 1889),
  (10, -1, 9, 116, 32, 1558),
  (9, -1, 9, 132, 0, 1054),
  (10, 5, 10, 116, 0, 0),
  (11, -1, 11, 132, 0, 1043),
  (12, 3, 12, 106, 0, 0),
  (14, -1, 13, 116, 32, 1537),
  (13, -1, 13, 132, 0, 1103),
  (14, 5, 14, 116, 0, 0),
  (15, -1, 15, 132, 0, 1077),
  (16, 2, 16, 100, 0, 0),
];

void main() {
  _checkAnimation();
  _checkEntropy();
}

void _checkAnimation() {
  final animation = AvifAnimation.open(_fixture);
  try {
    check(
      animation.frameCount == 17 && animation.frameRate == '20/1',
      'SVT-AV1 animation timing',
    );
    final decoded = <int, Av1FrameHeader>{};
    var count = 0, presented = 0;
    for (final sample in animation.codedFrames()) {
      final (order, existing, packet, qp, refresh, tileBytes) =
          _frames[count++];
      final frame = sample.frame, header = frame.header;
      final size = header.size, color = frame.sequence.color;
      check(
        (
              size.width,
              size.height,
              color.depth,
              color.subsamplingX,
              color.subsamplingY,
            ) ==
            (256, 144, 10, 1, 1),
        'AV1 10-bit 4:2:0 coded size',
      );
      check(
        header.orderHint == order &&
            (frame.syntax.existingSlot ?? -1) == existing &&
            header.parameters.quantization.base == qp &&
            frame.refreshFlags == refresh,
        'AV1 frame header and refresh flags',
      );
      check(sample.packet.timestamp!.pts == packet * 512, 'AV1 sample PTS');
      check(
        frame.tiles.fold(0, (sum, tile) => sum + tile.payload.length) ==
            tileBytes,
        'AV1 tile data extents',
      );
      if (existing < 0) {
        check(
          frame.tiles.length == 4 && header.tiles.sizeBytes == 2,
          'AV1 2×2 tile layout and length width',
        );
        check(
          header.parameters.filmGrain != null && header.refreshContext,
          'AV1 film grain and context update',
        );
        decoded[order] = header;
      } else {
        check(
          identical(decoded[order], header),
          'AV1 show-existing resolves the stored header',
        );
      }
      if (sample.present) check(order == presented++, 'AV1 presentation order');
      if (count == 1) {
        check(
          header.parameters.filmGrain!.seed == 7391 &&
              header.tiles.contextTile == 3 &&
              header.parameters.deltaQShift == 0,
          'AV1 key frame grain and tile context',
        );
        _checkTileGroups(sample.packet.offset, sample.packet.size, frame);
      }
    }
    check(
      count == _frames.length && presented == 17,
      'AV1 coded and displayed frame counts',
    );
  } finally {
    animation.close();
  }
}

void _checkTileGroups(int offset, int size, Av1CodedFrame expected) {
  final file = File(_fixture).openSync();
  final Uint8List data;
  try {
    file.setPositionSync(offset);
    data = file.readSync(size);
  } finally {
    file.closeSync();
  }
  final obus = readAv1Obus(data).toList();
  final sequence = obus.firstWhere((obu) => obu.type == 1);
  final input = Av1Bits(obus.firstWhere((obu) => obu.type == 6).payload);
  final header = BitWriter();
  // FFmpeg's first frame header starts at bit 24 and ends before bit 1022.
  for (var i = 0; i < 998; i++) {
    header.write(input.read(1), 1);
  }
  final separateHeader = obu(3, header.finish(trailingBit: true));
  Uint8List group(int first, int last) {
    final header = BitWriter()
      ..write(1, 1)
      ..write(first, 2)
      ..write(last, 2);
    final bytes = BytesBuilder(copy: false)..add(header.finish());
    for (var index = first; index <= last; index++) {
      final payload = expected.tiles[index].payload;
      if (index != last) {
        final length = ByteData(2)
          ..setUint16(0, payload.length - 1, Endian.little);
        bytes.add(length.buffer.asUint8List());
      }
      bytes.add(payload);
    }
    return obu(4, bytes.takeBytes());
  }

  final top = group(0, 1), bottom = group(2, 3);
  Av1AccessUnits parser() =>
      Av1AccessUnits()..configure(obu(1, sequence.payload));
  final frame = parser()
      .readSample(Uint8List.fromList([...separateHeader, ...top, ...bottom]))
      .single;
  check(frame.tiles.length == 4, 'AV1 split groups cover the tile layout');
  for (final (i, tile) in frame.tiles.indexed) {
    final reference = expected.tiles[i].payload;
    check(
      tile.index == i &&
          tile.payload.length == reference.length &&
          tile.payload.asMap().entries.every(
            (e) => e.value == reference[e.key],
          ),
      'AV1 split group tile extent and payload',
    );
  }
  _expectFormat(
    () => parser()
        .readSample(Uint8List.fromList([...separateHeader, ...bottom, ...top]))
        .toList(),
  );
  _expectFormat(
    () => parser()
        .readSample(Uint8List.fromList([...separateHeader, ...top]))
        .toList(),
  );
}

void _checkEntropy() {
  // Two interleaved Q15 tables and fixed-probability bits, generated by
  // OxideAV's AV1 SymbolWriter at f0b4af463f8d7f1495325cd53954101ddb99100a.
  const adaptive = [
    74,
    0,
    117,
    176,
    17,
    242,
    31,
    75,
    103,
    141,
    62,
    120,
    168,
    114,
    51,
    27,
    45,
    189,
    191,
    97,
    220,
    168,
  ];
  const fixed = [
    73,
    178,
    139,
    35,
    7,
    116,
    13,
    195,
    17,
    120,
    147,
    219,
    119,
    249,
    53,
    79,
    127,
    141,
    161,
    222,
    202,
    49,
    209,
    122,
    105,
    52,
  ];
  for (final (data, update) in [(adaptive, true), (fixed, false)]) {
    final decoder = RangeDecoder(
      Av1Bits(Uint8List.fromList(data)),
      updateCdf: update,
    );
    final first = Av1Cdf([8192, 16384, 24576]), second = Av1Cdf([20000]);
    Av1Cdf? snapshot;
    for (var i = 0; i < 64; i++) {
      check(
        decoder.adaptive(first) == (i * i + 3 * i + 1) % 4,
        'AV1 four-symbol CDF',
      );
      check(decoder.adaptive(second) == (i ^ (i >> 1)) & 1, 'AV1 binary CDF');
      if (i % 7 == 0)
        check(decoder.literal(1) == i % 2, 'AV1 non-adaptive literal');
      if (i == 19) snapshot = first.copy();
    }
    decoder.finish();
    check(
      first.observations == (update ? 32 : 0) &&
          second.cumulative.single == (update ? 16862 : 20000),
      'AV1 CDF update mode and adaptation cap',
    );
    check(
      first.cumulative.join(',') ==
          (update ? '3004,16186,19169' : '8192,16384,24576'),
      'AV1 final CDF',
    );
    check(
      snapshot!.observations == (update ? 20 : 0) &&
          snapshot.cumulative.join(',') ==
              (update ? '4635,16176,20805' : '8192,16384,24576'),
      'AV1 saved CDF remains independent of subsequent symbols',
    );
  }
}

void _expectFormat(void Function() action) {
  try {
    action();
  } on FormatException {
    return;
  }
  throw StateError('Expected AV1 format error');
}

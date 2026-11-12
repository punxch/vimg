import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'access_units.dart';
import 'bitstream.dart';
import 'frame_header.dart';
import 'palette_cdf.dart';
import 'palette_reader.dart';
import 'range_decoder.dart';

/// Decode the lossless, palette-predicted AV1 profile written by vimg.
final class Av1PaletteDecoder {
  final _units = Av1AccessUnits();

  void configure(Uint8List config) => _units.configure(config);

  image.Image decode(Uint8List sample) {
    final coded = _units.readSample(sample).toList();
    if (coded.length != 1)
      throw const FormatException(
        'Expected one AV1 palette frame in the sample',
      );
    return decodePaletteFrame(coded.single);
  }
}

image.Image decodePaletteFrame(Av1CodedFrame frame) {
  final sequence = frame.sequence;
  final color = sequence.color;
  final header = frame.header;
  final size = header.size;
  _expect(
    color.depth == 8 &&
        color.fullRange &&
        color.matrix == 0 &&
        color.subsamplingX == 0 &&
        color.subsamplingY == 0,
    'color profile',
  );
  _expect(
    header.type == Av1FrameType.key &&
        header.showFrame &&
        frame.syntax.existingSlot == null,
    'non-key or hidden picture',
  );
  _expect(header.disableCdfUpdate, 'adaptive frame CDFs');
  _expect(
    header.screenContent && !header.intrabc && !sequence.tools.superblock128,
    'superblock size and intra block copy',
  );
  _expect(
    frame.tiles.length == 1 &&
        header.parameters.codedLossless &&
        !header.parameters.segmentation.enabled &&
        header.parameters.quantization.matrix == null &&
        header.parameters.filmGrain == null &&
        size.superresDenominator == 8,
    'tiles, quantization or post-processing',
  );
  final width = size.width, height = size.height;
  _expect(
    width <= 4096 && height <= 2304 && width * height <= 8912896,
    'dimensions above the palette decoder limit',
  );
  return _PaletteTileDecoder(
    width,
    height,
    RangeDecoder(Av1Bits(frame.tiles.single.payload), updateCdf: false),
  ).decode();
}

typedef _Colors = ({List<int> green, List<int> blue});

final class _PaletteTileDecoder {
  _PaletteTileDecoder(this.width, this.height, this._range);

  final int width, height;
  final RangeDecoder _range;
  late final _blocksWide = (width + 7) ~/ 8;
  late final _blocksHigh = (height + 7) ~/ 8;
  late final _neighbors = List<_Colors?>.filled(
    _blocksWide * _blocksHigh,
    null,
  );
  late final _pixels = Uint8List(width * height * 3);
  late final _palette = Av1PaletteReader(_range, 8);
  final _greenMap = Uint8List(64);
  final _chromaMap = Uint8List(64);

  image.Image decode() {
    for (var row = 0; row < _blocksHigh; row += 8) {
      for (var col = 0; col < _blocksWide; col += 8) {
        _partition(row, col, 3);
      }
    }
    _range.finish();
    return image.Image.fromBytes(
      width: width,
      height: height,
      bytes: _pixels.buffer,
      order: image.ChannelOrder.rgb,
    );
  }

  void _partition(int row, int col, int logSize) {
    if (row >= _blocksHigh || col >= _blocksWide) return;
    if (logSize == 0) {
      _expect(_range.symbol(partitionCdf[0][0]) == 0, 'sub-8×8 partitions');
      _block(row, col);
      return;
    }
    final half = 1 << (logSize - 1);
    final bottom = row + half < _blocksHigh;
    final right = col + half < _blocksWide;
    final context = (row == 0 ? 0 : 1) + (col == 0 ? 0 : 2);
    final cdf = partitionCdf[logSize][context];
    if (bottom && right) {
      _expect(_range.symbol(cdf) == 3, 'non-split partition');
    } else if (bottom || right) {
      _expect(
        _range.symbol(partitionEdgeCdf(cdf, rightEdge: bottom)) == 1,
        'non-split picture edge',
      );
    }
    _partition(row, col, logSize - 1);
    _partition(row, col + half, logSize - 1);
    _partition(row + half, col, logSize - 1);
    _partition(row + half, col + half, logSize - 1);
  }

  void _block(int row, int col) {
    final offset = row * _blocksWide + col;
    final context = (row == 0 ? 0 : 1) + (col == 0 ? 0 : 1);
    _expect(_range.symbol(skipCdf[context]) == 1, 'transform residual');
    _expect(_range.symbol(keyframeDcCdf) == 0, 'luma intra mode');
    _expect(_range.symbol(chromaDcCdf) == 0, 'chroma intra mode');

    final above = row % 8 == 0 ? null : _neighbors[offset - _blocksWide];
    final left = col == 0 ? null : _neighbors[offset - 1];
    _expect(
      _range.symbol(paletteLumaModeCdf[context]) == 1,
      'luma palette mode',
    );
    final green = _palette.colors(
      _range.symbol(paletteLumaSizeCdf) + 2,
      above?.green,
      left?.green,
      chroma: false,
    );
    _expect(_range.symbol(paletteChromaModeCdf) == 1, 'chroma palette mode');
    final blue = _palette.colors(
      _range.symbol(paletteChromaSizeCdf) + 2,
      above?.blue,
      left?.blue,
      chroma: true,
    );
    final red = _palette.vColors(blue.length);
    _palette.readMap(
      _greenMap,
      green.length,
      8,
      8,
      visibleWidth: 8,
      visibleHeight: 8,
      chroma: false,
    );
    _palette.readMap(
      _chromaMap,
      blue.length,
      8,
      8,
      visibleWidth: 8,
      visibleHeight: 8,
      chroma: true,
    );
    _neighbors[offset] = (green: green, blue: blue);

    final x = col * 8, y = row * 8;
    final w = math.min(8, width - x), h = math.min(8, height - y);
    for (var dy = 0; dy < h; dy++) {
      var destination = ((y + dy) * width + x) * 3;
      for (var dx = 0; dx < w; dx++) {
        final i = dy * 8 + dx;
        final uv = _chromaMap[i];
        _pixels[destination++] = red[uv];
        _pixels[destination++] = green[_greenMap[i]];
        _pixels[destination++] = blue[uv];
      }
    }
  }
}

void _expect(bool supported, String feature) {
  if (!supported)
    throw UnsupportedError('AV1 palette decoder cannot read $feature');
}

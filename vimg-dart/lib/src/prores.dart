import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'yuv_image.dart';

part 'prores_entropy.dart';
part 'prores_transform.dart';

/// One decoded RDD 36 frame in studio-range YCbCr, with optional source alpha.
final class ProResPicture {
  ProResPicture._(
    this.width,
    this.height,
    this.subsamplingX,
    this.matrix,
    this.alphaDepth,
    bool preserveAlpha,
  ) : depth = subsamplingX == 0 ? 12 : 10,
      y = Uint16List(width * height),
      cb = Uint16List(((width + subsamplingX) >> subsamplingX) * height),
      cr = Uint16List(((width + subsamplingX) >> subsamplingX) * height),
      alpha = alphaDepth > 0 && preserveAlpha
          ? Uint16List(width * height)
          : null;

  final int width, height, subsamplingX, matrix, depth, alphaDepth;
  final Uint16List y, cb, cr;
  final Uint16List? alpha;

  int get chromaStride => (width + subsamplingX) >> subsamplingX;

  image.Image rgb({YuvImageScaler? scaler, bool includeAlpha = true}) =>
      yuvImage(
        y: y,
        cb: cb,
        cr: cr,
        stride: width,
        chromaStride: chromaStride,
        width: width,
        height: height,
        cropLeft: 0,
        cropTop: 0,
        matrix: matrix,
        fullRange: false,
        lumaDepth: depth,
        chromaDepth: depth,
        subsamplingX: subsamplingX,
        subsamplingY: 0,
        alpha: includeAlpha ? alpha : null,
        alphaDepth: alphaDepth,
        scaler: scaler,
      );
}

/// Decode Apple ProRes picture data using SMPTE RDD 36:2022.
ProResPicture decodeProRes(
  Uint8List bytes, {
  bool allowBareFrame = false,
  bool preserveAlpha = true,
}) => _ProResDecoder(
  bytes,
).decode(allowBareFrame: allowBareFrame, preserveAlpha: preserveAlpha);

final class _ProResDecoder {
  _ProResDecoder(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  late final ProResPicture picture;
  late final int frameEnd;
  late final List<int> lumaWeights, chromaWeights, scan;
  final _entropy = _ProResCoefficients();
  final _transform = _ProResTransform();

  ProResPicture decode({
    required bool allowBareFrame,
    required bool preserveAlpha,
  }) {
    var header = 0;
    if (bytes.length >= 8 && data.getUint32(4) == 0x69637066) {
      header = 8;
      frameEnd = data.getUint32(0);
    } else if (allowBareFrame) {
      // Matroska blocks may omit the frame size and 'icpf' identifier.
      frameEnd = bytes.length;
    } else {
      throw const FormatException('Missing ProRes frame identifier');
    }
    if (frameEnd > bytes.length || frameEnd < header + 20) {
      throw const FormatException('Invalid ProRes frame size');
    }
    final headerSize = data.getUint16(header);
    final matrices = bytes[header + 19];
    final hasLuma = (matrices & 2) != 0, hasChroma = (matrices & 1) != 0;
    final matrixBytes = (hasLuma ? 64 : 0) + (hasChroma ? 64 : 0);
    if (headerSize < 20 + matrixBytes || header + headerSize > frameEnd) {
      throw const FormatException('Invalid ProRes frame header size');
    }
    final version = bytes[header + 3];
    if (version > 1) {
      throw FormatException('Unsupported ProRes bitstream version $version');
    }
    final width = data.getUint16(header + 8);
    final height = data.getUint16(header + 10);
    final format = bytes[header + 12] >> 6;
    final interlace = (bytes[header + 12] >> 2) & 3;
    final alphaType = bytes[header + 17] & 15;
    if (width == 0 || height == 0 || width * height > 100000000) {
      throw const FormatException('Invalid ProRes picture dimensions');
    }
    if (format < 2 ||
        interlace == 3 ||
        alphaType > 2 ||
        (version == 0 && (format != 2 || alphaType != 0))) {
      throw const FormatException('Invalid ProRes picture format');
    }

    final matrix = bytes[header + 16];
    picture = ProResPicture._(
      width,
      height,
      3 - format,
      matrix == 0 ? 2 : matrix,
      alphaType * 8,
      preserveAlpha,
    );
    final weightsStart = header + 20;
    lumaWeights = hasLuma ? _weights(weightsStart) : _defaultProResWeights;
    chromaWeights = hasChroma
        ? _weights(weightsStart + (hasLuma ? 64 : 0))
        : lumaWeights;
    scan = interlace == 0 ? _progressiveScan : _fieldScan;
    final start = header + headerSize;
    final rowStep = interlace == 0 ? 1 : 2;
    final firstRow = interlace == 2 ? 1 : 0;
    final next = _decodePicture(start, rowStep, firstRow);
    if (rowStep == 2) _decodePicture(next, rowStep, 1 - firstRow);
    return picture;
  }

  List<int> _weights(int offset) {
    final weights = Uint8List.sublistView(bytes, offset, offset + 64);
    if (weights.any((weight) => weight < 2 || weight > 63)) {
      throw const FormatException('Invalid ProRes quantization weight');
    }
    return weights;
  }

  int _decodePicture(int offset, int rowStep, int field) {
    if (frameEnd - offset < 8) {
      throw const FormatException('Truncated ProRes picture header');
    }
    final headerSize = bytes[offset] >> 3;
    final size = data.getUint32(offset + 1);
    final end = offset + size;
    if (headerSize < 8 || size < headerSize || end > frameEnd) {
      throw const FormatException('Invalid ProRes picture size');
    }
    final pictureHeight = (picture.height + rowStep - 1 - field) ~/ rowStep;
    final mbRows = (pictureHeight + 15) >> 4;
    final mbColumns = (picture.width + 15) >> 4;
    final sliceWidths = <int>[];
    var left = mbColumns;
    var mbPerSlice = 1 << ((bytes[offset + 7] >> 4) & 3);
    while (left > 0) {
      while (mbPerSlice > left) {
        mbPerSlice >>= 1;
      }
      sliceWidths.add(mbPerSlice);
      left -= mbPerSlice;
    }
    // The 16-bit slice count field is deprecated. Geometry determines the
    // number of entries even if the frame holds more than 65535 slices.
    var table = offset + headerSize;
    var slice = table + 2 * mbRows * sliceWidths.length;
    if (slice > end)
      throw const FormatException('Truncated ProRes slice table');
    for (var row = 0; row < mbRows; row++) {
      final planeRow = row * 16;
      final rows = math.min(16, pictureHeight - planeRow);
      var column = 0;
      for (final mbs in sliceWidths) {
        final size = data.getUint16(table);
        table += 2;
        if (size < 6 || size > end - slice) {
          throw const FormatException('Invalid ProRes slice extent');
        }
        _decodeSlice(
          slice,
          size,
          column,
          planeRow * rowStep + field,
          rows,
          rowStep,
          mbs,
        );
        column += mbs * 16;
        slice += size;
      }
    }
    if (slice != end) {
      throw const FormatException('ProRes slices do not cover the picture');
    }
    return end;
  }

  void _decodeSlice(
    int start,
    int size,
    int x,
    int y,
    int rows,
    int rowStep,
    int mbs,
  ) {
    final header = bytes[start] >> 3;
    final index = bytes[start + 1];
    final ySize = data.getUint16(start + 2);
    final cbSize = data.getUint16(start + 4);
    final hasAlpha = picture.alphaDepth > 0;
    if (header < (hasAlpha ? 8 : 6) ||
        header > size ||
        index == 0 ||
        index > 224 ||
        ySize == 0) {
      throw const FormatException('Invalid ProRes slice header');
    }
    final scale = index <= 128 ? index : (index - 96) * 4;
    final crSize = hasAlpha
        ? data.getUint16(start + 6)
        : size - header - ySize - cbSize;
    final alphaSize = size - header - ySize - cbSize - crSize;
    if (crSize < 0 || alphaSize < (hasAlpha ? 1 : 0)) {
      throw const FormatException('Invalid ProRes component data size');
    }

    final yStart = start + header;
    final cbStart = yStart + ySize;
    final crStart = cbStart + cbSize;
    _decodeColor(
      yStart,
      ySize,
      picture.y,
      lumaWeights,
      picture.width,
      x,
      y,
      rowStep,
      mbs,
      scale,
      chroma: false,
    );
    final cx = x >> picture.subsamplingX;
    final cw = picture.chromaStride;
    _decodeColor(
      cbStart,
      cbSize,
      picture.cb,
      chromaWeights,
      cw,
      cx,
      y,
      rowStep,
      mbs,
      scale,
      chroma: true,
    );
    _decodeColor(
      crStart,
      crSize,
      picture.cr,
      chromaWeights,
      cw,
      cx,
      y,
      rowStep,
      mbs,
      scale,
      chroma: true,
    );
    if (picture.alpha case final alpha?) {
      _decodeProResAlpha(
        _ProResBits(bytes, crStart + crSize, start + size),
        alpha,
        picture.alphaDepth,
        picture.width,
        x,
        y,
        rowStep,
        mbs * 16,
        rows,
      );
    }
  }

  void _decodeColor(
    int offset,
    int size,
    Uint16List plane,
    List<int> weights,
    int stride,
    int x,
    int y,
    int rowStep,
    int mbs,
    int scale, {
    required bool chroma,
  }) {
    final blocksWide = chroma && picture.subsamplingX != 0 ? 1 : 2;
    final blocksPerMb = blocksWide * 2;
    final count = mbs * blocksPerMb;
    _entropy.decode(_ProResBits(bytes, offset, offset + size), count, scan);
    for (var mb = 0; mb < mbs; mb++) {
      for (var block = 0; block < blocksPerMb; block++) {
        final (bx, by) = chroma
            ? (block >> 1, block & 1)
            : (block & 1, block >> 1);
        final blockX = x + (mb * blocksWide + bx) * 8;
        final blockY = y + by * 8 * rowStep;
        final coefficientBlock = mb * blocksPerMb + block;
        _transform.write(
          plane,
          stride,
          picture.height,
          blockX,
          blockY,
          rowStep,
          _entropy.values,
          coefficientBlock * 64,
          weights,
          scale,
          picture.depth,
          _entropy.rows[coefficientBlock],
        );
      }
    }
  }
}

final _defaultProResWeights = List<int>.filled(64, 4, growable: false);

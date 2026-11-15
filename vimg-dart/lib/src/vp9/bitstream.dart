import 'dart:typed_data';

/// A coded frame's byte extent within a VP9 container packet.
typedef Vp9FrameExtent = ({int offset, int length});

/// VP9 §6.1 distinguishes single frames from packets with a superframe index.
List<Vp9FrameExtent> vp9FrameExtents(
  int length,
  Uint8List Function(int offset, int length) read,
) {
  if (length < 1) throw const FormatException('Empty VP9 packet');
  final marker = read(length - 1, 1).single;
  if (marker & 0xe0 != 0xc0) return [(offset: 0, length: length)];
  final count = (marker & 7) + 1;
  final width = ((marker >> 3) & 3) + 1;
  final indexLength = 2 + count * width;
  final indexOffset = length - indexLength;
  if (indexOffset < 0) {
    throw const FormatException('Truncated VP9 superframe index');
  }
  final index = read(indexOffset, indexLength);
  if (index.first != marker) {
    throw const FormatException('Mismatched VP9 superframe index markers');
  }
  final frames = <Vp9FrameExtent>[];
  var offset = 0;
  for (var i = 0; i < count; i++) {
    var size = 0;
    for (var j = 0; j < width; j++) {
      size |= index[1 + i * width + j] << (8 * j);
    }
    if (size == 0 || size > indexOffset - offset) {
      throw const FormatException('Invalid VP9 superframe size');
    }
    frames.add((offset: offset, length: size));
    offset += size;
  }
  if (offset != indexOffset) {
    throw const FormatException('VP9 superframe sizes do not cover packet');
  }
  return frames;
}

typedef Vp9FrameTag = ({int profile, int? existing, bool key, bool shown});

Vp9FrameTag vp9FrameTag(Uint8List bytes) => _readTag(Vp9Bits(bytes));

Vp9FrameTag _readTag(Vp9Bits bits) {
  if (bits.read(2) != 2) {
    throw const FormatException('Invalid VP9 frame marker');
  }
  final profile = bits.read(1) | (bits.read(1) << 1);
  if (profile == 3) bits.reservedZero();
  if (bits.flag()) {
    return (profile: profile, existing: bits.read(3), key: false, shown: true);
  }
  return (
    profile: profile,
    existing: null,
    key: !bits.flag(),
    shown: bits.flag(),
  );
}

/// The visible picture in a packet can follow hidden reference updates.
typedef Vp9PacketTag = ({bool shown, bool key, Vp9FrameExtent? preview});

Vp9PacketTag vp9PacketTag(
  int length,
  Uint8List Function(int offset, int length) read,
) {
  var shown = 0;
  var key = false;
  Vp9FrameExtent? preview, displayReference;
  for (final frame in vp9FrameExtents(length, read)) {
    final tag = vp9FrameTag(
      read(frame.offset, frame.length < 2 ? frame.length : 2),
    );
    key |= tag.key;
    if (tag.existing == null) displayReference = tag.key ? frame : null;
    if (tag.shown) {
      shown++;
      preview = displayReference;
    }
  }
  return (shown: shown > 0, key: key, preview: shown == 1 ? preview : null);
}

typedef Vp9Color = ({int depth, int space, bool fullRange, int subX, int subY});

typedef Vp9Quantization = ({int base, int yDc, int uvDc, int uvAc});

typedef Vp9LoopFilter = ({
  int level,
  int sharpness,
  bool deltaEnabled,
  List<int?> referenceDeltas,
  List<int?> modeDeltas,
});

typedef Vp9Segmentation = ({
  bool enabled,
  List<int>? tree,
  List<int>? prediction,
  bool absolute,
  List<List<int?>>? features,
});

final class Vp9FrameHeader {
  Vp9FrameHeader._(
    this.tag,
    this.errorResilient,
    this.intra,
    this.refreshMask,
    this.color,
    this.width,
    this.height,
    this.renderWidth,
    this.renderHeight,
    this.references,
    this.referenceBiases,
    this.highPrecisionMotion,
    this.interpolation,
    this.resetContext,
    this.frameContext,
    this.refreshContext,
    this.parallel,
    this.filter,
    this.quantization,
    this.segmentation,
    this.tileColumnLog,
    this.tileRowLog,
    this.compressedHeaderOffset,
    this.compressedHeaderLength,
  );

  final Vp9FrameTag tag;
  final bool errorResilient, intra;
  final int refreshMask;
  final Vp9Color color;
  final int width, height, renderWidth, renderHeight;
  final List<int> references;
  final List<bool> referenceBiases;
  final bool highPrecisionMotion;
  final int? interpolation; // Null for a per-block switchable filter.
  final int resetContext, frameContext;
  final bool refreshContext, parallel;
  final Vp9LoopFilter filter;
  final Vp9Quantization quantization;
  final Vp9Segmentation segmentation;
  final int tileColumnLog, tileRowLog;
  final int compressedHeaderOffset, compressedHeaderLength;

  bool get lossless =>
      quantization.base == 0 &&
      quantization.yDc == 0 &&
      quantization.uvDc == 0 &&
      quantization.uvAc == 0;

  int get miColumns => (width + 7) >> 3;
  int get miRows => (height + 7) >> 3;

  /// Returns null for a show-existing-frame command with no coded picture.
  static Vp9FrameHeader? read(
    Uint8List bytes, {
    Vp9FrameHeader? Function(int index)? reference,
  }) {
    final bits = Vp9Bits(bytes);
    final tag = _readTag(bits);
    if (tag.existing != null) {
      bits.align();
      for (var i = bits.byteOffset; i < bytes.length; i++) {
        if (bytes[i] != 0) {
          throw const FormatException('Invalid VP9 show-existing padding');
        }
      }
      return null;
    }
    final errorResilient = bits.flag();
    final intra = tag.key || (!tag.shown && bits.flag());
    final resetContext = tag.key || errorResilient ? 0 : bits.read(2);
    final Vp9Color color;
    final int refreshMask;
    final references = <int>[];
    final biases = <bool>[];
    (int, int)? inheritedSize;
    if (intra) {
      if (bits.read(24) != 0x498342) {
        throw const FormatException('Invalid VP9 intra sync code');
      }
      color = tag.key || tag.profile > 0
          ? _readColor(bits, tag.profile)
          : (depth: 8, space: 1, fullRange: false, subX: 1, subY: 1);
      refreshMask = tag.key ? 255 : bits.read(8);
    } else {
      refreshMask = bits.read(8);
      for (var i = 0; i < 3; i++) {
        references.add(bits.read(3));
        final bias = bits.flag();
        biases.add(!errorResilient && bias);
      }
      Vp9FrameHeader getReference(int index) =>
          reference?.call(index) ??
          (throw const FormatException('Missing VP9 reference header'));
      color = getReference(references.first).color;
      for (final index in references) {
        if (bits.flag()) {
          final header = getReference(index);
          inheritedSize = (header.width, header.height);
          break;
        }
      }
    }
    final (width, height) =
        inheritedSize ?? (bits.read(16) + 1, bits.read(16) + 1);
    final (renderWidth, renderHeight) = bits.flag()
        ? (bits.read(16) + 1, bits.read(16) + 1)
        : (width, height);
    final highPrecision = !intra && bits.flag();
    final interpolation = intra || bits.flag() ? null : bits.read(2);
    final refreshContext = !errorResilient && bits.flag();
    final parallel = errorResilient || bits.flag();
    final context = bits.read(2);
    final filter = _readLoopFilter(bits);
    final quant = (
      base: bits.read(8),
      yDc: bits.flag() ? bits.signed(4) : 0,
      uvDc: bits.flag() ? bits.signed(4) : 0,
      uvAc: bits.flag() ? bits.signed(4) : 0,
    );
    final segmentation = _readSegmentation(bits);
    final sbColumns = (width + 63) >> 6;
    var minColumns = 0, maxColumns = 0;
    while ((64 << minColumns) < sbColumns) {
      minColumns++;
    }
    while ((sbColumns >> (maxColumns + 1)) >= 4) {
      maxColumns++;
    }
    var tileColumns = minColumns;
    while (tileColumns < maxColumns && bits.flag()) {
      tileColumns++;
    }
    final tileRows = bits.flag() ? 1 + bits.read(1) : 0;
    final headerLength = bits.read(16);
    bits.align();
    final headerOffset = bits.byteOffset;
    if (headerLength == 0 || headerLength >= bytes.length - headerOffset) {
      throw const FormatException('Invalid VP9 compressed header size');
    }
    return Vp9FrameHeader._(
      tag,
      errorResilient,
      intra,
      refreshMask,
      color,
      width,
      height,
      renderWidth,
      renderHeight,
      references,
      biases,
      highPrecision,
      interpolation,
      resetContext,
      context,
      refreshContext,
      parallel,
      filter,
      quant,
      segmentation,
      tileColumns,
      tileRows,
      headerOffset,
      headerLength,
    );
  }

  Iterable<({int row, int column, int offset, int length})> tiles(
    Uint8List bytes,
  ) sync* {
    final columns = 1 << tileColumnLog, rows = 1 << tileRowLog;
    final data = ByteData.sublistView(bytes);
    var offset = compressedHeaderOffset + compressedHeaderLength;
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        var length = bytes.length - offset;
        if (row != rows - 1 || column != columns - 1) {
          if (length < 4) {
            throw const FormatException('Truncated VP9 tile size');
          }
          length = data.getUint32(offset);
          offset += 4;
        }
        if (length < 1 || length > bytes.length - offset) {
          throw const FormatException('Invalid VP9 tile extent');
        }
        yield (row: row, column: column, offset: offset, length: length);
        offset += length;
      }
    }
  }
}

Vp9Color _readColor(Vp9Bits bits, int profile) {
  final depth = profile < 2 ? 8 : (bits.flag() ? 12 : 10);
  final space = bits.read(3);
  final rgb = space == 7;
  final fullRange = rgb || bits.flag();
  var subX = 1, subY = 1;
  if (profile.isOdd) {
    subX = rgb ? 0 : bits.read(1);
    subY = rgb ? 0 : bits.read(1);
    bits.reservedZero();
    if (subX == 1 && subY == 1) {
      throw const FormatException('Invalid VP9 chroma subsampling for profile');
    }
  } else if (rgb) {
    throw const FormatException('Invalid VP9 RGB profile');
  }
  return (
    depth: depth,
    space: space,
    fullRange: fullRange,
    subX: subX,
    subY: subY,
  );
}

Vp9LoopFilter _readLoopFilter(Vp9Bits bits) {
  final level = bits.read(6);
  final sharpness = bits.read(3);
  final enabled = bits.flag();
  final update = enabled && bits.flag();
  return (
    level: level,
    sharpness: sharpness,
    deltaEnabled: enabled,
    referenceDeltas: [
      for (var i = 0; i < 4; i++) update && bits.flag() ? bits.signed(6) : null,
    ],
    modeDeltas: [
      for (var i = 0; i < 2; i++) update && bits.flag() ? bits.signed(6) : null,
    ],
  );
}

Vp9Segmentation _readSegmentation(Vp9Bits bits) {
  final enabled = bits.flag();
  final updateMap = enabled && bits.flag();
  int probability() => bits.flag() ? bits.read(8) : 255;
  final tree = updateMap ? List<int>.generate(7, (_) => probability()) : null;
  final prediction = updateMap && bits.flag()
      ? List<int>.generate(3, (_) => probability())
      : null;
  final updateData = enabled && bits.flag();
  final absolute = updateData && bits.flag();
  return (
    enabled: enabled,
    tree: tree,
    prediction: prediction,
    absolute: absolute,
    features: updateData
        ? List.generate(
            8,
            (_) => [
              bits.flag() ? bits.signed(8) : null,
              bits.flag() ? bits.signed(6) : null,
              bits.flag() ? bits.read(2) : null,
              bits.flag() ? 0 : null,
            ],
          )
        : null,
  );
}

final class Vp9Bits {
  Vp9Bits(this._bytes);

  final Uint8List _bytes;
  int _position = 0;
  int get byteOffset => (_position + 7) >> 3;

  int read(int count) {
    if (_position + count > _bytes.length * 8) {
      throw const FormatException('Truncated VP9 uncompressed header');
    }
    var value = 0;
    for (var i = 0; i < count; i++, _position++) {
      value =
          (value << 1) |
          ((_bytes[_position >> 3] >> (7 - (_position & 7))) & 1);
    }
    return value;
  }

  bool flag() => read(1) != 0;

  int signed(int width) {
    final magnitude = read(width);
    return flag() ? -magnitude : magnitude;
  }

  void reservedZero() {
    if (flag()) throw const FormatException('Nonzero reserved VP9 header bit');
  }

  void align() {
    if (read((-_position) & 7) != 0) {
      throw const FormatException('Nonzero VP9 header padding');
    }
  }
}

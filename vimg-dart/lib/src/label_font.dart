part of 'grid_label.dart';

typedef _Point = ({double x, double y});
typedef _Edge = ({_Point from, _Point? control, _Point to});
typedef _Bounds = ({int left, int top, int right, int bottom});

/// Reads the unhinted TrueType outlines from the bundled Cantarell face.
final class _LabelFont {
  _LabelFont(this.data) {
    final tables = <String, int>{};
    for (var i = 0; i < _uint16(4); i++) {
      final entry = 12 + i * 16;
      final tag = String.fromCharCodes([
        for (var j = 0; j < 4; j++) data.getUint8(entry + j),
      ]);
      tables[tag] = data.getUint32(entry + 8);
    }
    final metrics = tables['hhea']!;
    ascent = _int16(metrics + 4);
    descent = _int16(metrics + 6);
    lineGap = _int16(metrics + 8);
    _metricsCount = _uint16(metrics + 34);
    _metrics = tables['hmtx']!;
    _glyphs = tables['glyf']!;
    _locations = tables['loca']!;
    _longOffsets = _int16(tables['head']! + 50) != 0;
    final mapping = tables['cmap']!;
    _cmap = _unicodeMap(mapping);
    _segments = _uint16(_cmap + 6) ~/ 2;
  }

  final ByteData data;
  late final int ascent, descent, lineGap;
  late final int _metrics, _metricsCount, _glyphs, _locations, _cmap, _segments;
  late final bool _longOffsets;
  final _outlines = <int, _GlyphOutline?>{};

  int _uint16(int offset) => data.getUint16(offset);
  int _int16(int offset) => data.getInt16(offset);

  int _unicodeMap(int mapping) {
    for (var i = 0; i < _uint16(mapping + 2); i++) {
      final record = mapping + 4 + i * 8;
      final platform = _uint16(record);
      final encoding = _uint16(record + 2);
      final offset = mapping + data.getUint32(record + 4);
      if ((platform == 0 || (platform == 3 && encoding == 1)) &&
          _uint16(offset) == 4) {
        return offset;
      }
    }
    throw StateError('Cantarell is missing its Unicode character map');
  }

  int glyphId(int rune) {
    if (rune > 0xffff) return 0;
    final endCodes = _cmap + 14;
    final startCodes = endCodes + _segments * 2 + 2;
    var low = 0, high = _segments;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (rune <= _uint16(endCodes + middle * 2)) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    final start = _uint16(startCodes + low * 2);
    if (rune < start) return 0;
    final delta = _int16(startCodes + (_segments + low) * 2);
    final pointer = startCodes + (_segments * 2 + low) * 2;
    final range = _uint16(pointer);
    final glyph = range == 0
        ? rune
        : _uint16(pointer + range + (rune - start) * 2);
    return glyph == 0 && range != 0 ? 0 : (glyph + delta) & 0xffff;
  }

  int advance(int glyph) =>
      _uint16(_metrics + math.min(glyph, _metricsCount - 1) * 4);

  int _location(int glyph) =>
      _glyphs +
      (_longOffsets
          ? data.getUint32(_locations + 4 * glyph)
          : 2 * _uint16(_locations + 2 * glyph));

  _GlyphOutline? outline(int glyph) => _outlines.putIfAbsent(glyph, () {
    final offset = _location(glyph);
    if (offset == _location(glyph + 1)) return null;
    final count = _int16(offset);
    final edges = count < 0
        ? _components(offset + 10)
        : _simpleOutline(offset + 10, count);
    return edges.isEmpty ? null : _GlyphOutline(edges);
  });

  List<_Edge> _simpleOutline(int offset, int count) {
    if (count == 0) return const [];
    final ends = List.generate(count, (i) => _uint16(offset + 2 * i));
    final size = ends.last + 1;
    if (size <= 1) return const [];
    offset += 2 * count;
    offset += 2 + _uint16(offset); // Skip hinting instructions.
    final flags = Uint8List(size);
    for (var i = 0; i < size;) {
      final flag = data.getUint8(offset++);
      final repeat = (flag & 8) == 0 ? 1 : 1 + data.getUint8(offset++);
      flags.fillRange(i, i + repeat, flag);
      i += repeat;
    }
    Int32List coordinates(int short, int same) {
      final values = Int32List(size);
      var value = 0;
      for (var i = 0; i < size; i++) {
        final flag = flags[i];
        if ((flag & short) != 0) {
          final distance = data.getUint8(offset++);
          value += (flag & same) == 0 ? -distance : distance;
        } else if ((flag & same) == 0) {
          value += _int16(offset);
          offset += 2;
        }
        values[i] = value;
      }
      return values;
    }

    final x = coordinates(2, 16), y = coordinates(4, 32);
    _Point point(int index) => (x: x[index].toDouble(), y: y[index].toDouble());
    bool onCurve(int index) => (flags[index] & 1) != 0;
    final edges = <_Edge>[];
    var first = 0;
    for (final end in ends) {
      final firstPoint = point(first), lastPoint = point(end);
      // Adjacent off-curve points imply a midpoint on the curve.
      final start = onCurve(first)
          ? firstPoint
          : onCurve(end)
          ? lastPoint
          : _midpoint(lastPoint, firstPoint);
      var from = start;
      _Point? control;
      for (var i = first; i <= end; i++) {
        final next = point(i);
        if (onCurve(i)) {
          edges.add((from: from, control: control, to: next));
          from = next;
          control = null;
        } else {
          if (control != null) {
            final middle = _midpoint(control, next);
            edges.add((from: from, control: control, to: middle));
            from = middle;
          }
          control = next;
        }
      }
      edges.add((from: from, control: control, to: start));
      first = end + 1;
    }
    return edges;
  }

  List<_Edge> _components(int offset) {
    final edges = <_Edge>[];
    var flags = 0;
    do {
      flags = _uint16(offset);
      final component = _uint16(offset + 2);
      offset += 4;
      // Every component in this face uses signed XY offsets.
      final words = (flags & 1) != 0;
      final x = words ? _int16(offset) : data.getInt8(offset);
      final y = words ? _int16(offset + 2) : data.getInt8(offset + 1);
      offset += words ? 4 : 2;
      double scale() {
        final value = _int16(offset) / 16384;
        offset += 2;
        return value;
      }

      final uniform = (flags & 8) == 0 ? 1.0 : scale();
      final (a, b, c, d) = switch (flags & 0xc0) {
        0x80 => (scale(), scale(), scale(), scale()),
        0x40 => (scale(), 0.0, 0.0, scale()),
        _ => (uniform, 0.0, 0.0, uniform),
      };
      _Point transform(_Point p) =>
          (x: a * p.x + c * p.y + x, y: b * p.x + d * p.y + y);
      for (final edge in outline(component)?.edges ?? const <_Edge>[]) {
        edges.add((
          from: transform(edge.from),
          control: edge.control == null ? null : transform(edge.control!),
          to: transform(edge.to),
        ));
      }
    } while ((flags & 32) != 0);
    return edges;
  }
}

_Point _midpoint(_Point a, _Point b) =>
    (x: (a.x + b.x) / 2, y: (a.y + b.y) / 2);

final class _GlyphOutline {
  _GlyphOutline(this.edges) {
    var left = double.infinity, top = double.negativeInfinity;
    var right = double.negativeInfinity, bottom = double.infinity;
    void include(_Point p) {
      left = math.min(left, p.x);
      right = math.max(right, p.x);
      top = math.max(top, p.y);
      bottom = math.min(bottom, p.y);
    }

    for (final edge in edges) {
      include(edge.from);
      include(edge.to);
      if (edge.control case final p?) include(p);
    }
    bounds = (
      left: left.truncate(),
      top: top.truncate(),
      right: right.truncate(),
      bottom: bottom.truncate(),
    );
  }

  final List<_Edge> edges;
  late final _Bounds bounds;
}

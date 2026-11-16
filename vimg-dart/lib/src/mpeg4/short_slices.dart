part of 'decoder.dart';

typedef _H263Slice = ({H263GroupHeader header, int data, int end});

extension _H263Slices on _H263Macroblocks {
  Iterable<int> _macroblockOrder() sync* {
    if (!header.format.rectangularSlices &&
        !header.format.arbitrarySlices &&
        !header.format.independentSegments &&
        !header.format.partitioned &&
        !(header.erps != null && header.format.structured)) {
      for (var index = 0; index < _count; index++) {
        _startMacroblock(index);
        yield index;
      }
      return;
    }
    final (:layout, :counts) = _preparedSlices;
    final sac = _sac;
    for (final (i, slice) in layout.indexed) {
      final group = slice.header;
      _sliceStart = group.address;
      if (i != 0) {
        _bits.position = slice.data;
        _beginGroup(group);
      } else if (group.erps case final erps?) {
        _setErpsGroup(erps);
      }
      _validateTemporalSegments(reference);
      final count = counts[group.address]!;
      final partitions = header.format.partitioned
          ? _readDataPartitions(count, slice.end)
          : null;
      for (var mb = 0; mb < count; mb++) {
        final address = _sliceAddressAt(group, mb);
        _filterSlices?[address] = _sliceStart;
        _partition = partitions?[mb];
        yield address;
        if (_bits.position > slice.end) {
          throw const FormatException('H.263+ macroblock exceeds its slice');
        }
      }
      _partition = null;
      if (sac == null) _finishSlice(slice.end);
    }
  }

  ({List<_H263Slice> layout, Map<int, int> counts}) _prepareSlices() {
    final layout = _sliceLayout();
    final counts = _sliceMacroblockCounts(layout.map((slice) => slice.header));
    final owners = _sliceOwners = Uint16List(_count);
    for (final slice in layout) {
      final group = slice.header;
      for (var i = 0; i < counts[group.address]!; i++) {
        final address = _sliceAddressAt(group, i);
        if (owners[address] != 0) {
          throw const FormatException('Overlapping H.263+ slices');
        }
        owners[address] = group.address + 1;
      }
    }
    if (header.format.independentSegments) _setSegmentBounds(layout, counts);
    return (layout: layout, counts: counts);
  }

  int _sliceAddressAt(H263GroupHeader slice, int offset) {
    final width = slice.width;
    return slice.address +
        (width == null ? offset : offset ~/ width * _columns + offset % width);
  }

  List<_H263Slice> _sliceLayout() {
    final first = header.firstSlice;
    var current = (
      address: first?.address ?? 0,
      width: first?.width,
      quant: header.quant,
      temporal: header.predictionTemporal,
      erps: first?.erps ?? header.erps,
    );
    var data = _bits.position;
    final layout = <_H263Slice>[];
    for (final unit in h263GroupUnits(header, _bits.bytes)) {
      layout.add((header: current, data: data, end: unit.start));
      final group = unit.header;
      if (group == null) return layout;
      if (!header.format.arbitrarySlices && group.address <= current.address) {
        throw const FormatException('H.263+ slice addresses are out of order');
      }
      current = group;
      data = unit.data;
    }
    layout.add((header: current, data: data, end: _bits.bytes.length * 8));
    return layout;
  }

  Map<int, int> _sliceMacroblockCounts(Iterable<H263GroupHeader> groups) {
    final ordered = groups.toList()
      ..sort((a, b) => a.address.compareTo(b.address));
    final counts = <int, int>{};
    final nextRow = List<int>.filled(_columns, _rows);
    var nextAddress = _count, covered = 0;
    for (final slice in ordered.reversed) {
      final address = slice.address;
      if (address >= nextAddress) {
        throw const FormatException('Duplicate H.263+ slice address');
      }
      final width = slice.width;
      final int count;
      if (width == null) {
        count = nextAddress - address;
      } else {
        // The first lower slice intersecting any column is the bottom edge
        // of this rectangle. A conforming layout tiles the entire picture.
        final x = address % _columns, y = address ~/ _columns;
        var bottom = _rows;
        for (var column = x; column < x + width; column++) {
          bottom = math.min(bottom, nextRow[column]);
          nextRow[column] = y;
        }
        if (bottom <= y) {
          throw const FormatException('Overlapping H.263+ rectangles');
        }
        count = width * (bottom - y);
      }
      counts[address] = count;
      covered += count;
      nextAddress = address;
    }
    if (covered != _count) {
      throw const FormatException('H.263+ slices do not cover the picture');
    }
    return counts;
  }

  void _finishSlice(int end) {
    final multiple = _multiplePrediction;
    final stuffing = multiple ? 11 : (header.intra ? 9 : 10);
    // Annex U inserts PR0=0 after COD=0, even for a stuffing macroblock.
    final word = multiple ? 0x201 : 1;
    while (!header.format.partitioned && end - _bits.position >= stuffing) {
      if (_bits.read(stuffing) != word) {
        throw const FormatException('Unexpected data after H.263+ slice');
      }
    }
    final remaining = end - _bits.position;
    if (remaining > 7 || _bits.read(remaining) != 0) {
      throw const FormatException('Invalid H.263+ slice alignment');
    }
  }

  bool _inCurrentSegment(int x, int y) {
    if (x < 0 || x >= _columns || y < 0 || y >= _rows) return false;
    final address = y * _columns + x;
    final owners = _sliceOwners;
    return owners == null
        ? address >= _sliceStart
        : owners[address] == _sliceStart + 1;
  }

  _Vector _h263MotionPrediction(
    _PictureMotion motion,
    int x,
    int y,
    int block,
  ) {
    if (_sliceOwners == null) {
      return _motionPrediction(
        motion,
        _columns,
        _sliceStart,
        x,
        y,
        block,
        h263: true,
      );
    }
    final bx = x * 2 + (block & 1), by = y * 2 + (block >> 1);
    final cx = bx + const [2, 1, 1, -1][block];
    bool inSegment(int x, int y) => _inCurrentSegment(x >> 1, y >> 1);
    final left = inSegment(bx - 1, by) ? motion.at(bx - 1, by) : _zeroVector;
    final top = inSegment(bx, by - 1) ? motion.at(bx, by - 1) : left;
    final topRight = cx >= 2 * _columns
        ? _zeroVector
        : inSegment(cx, by - 1)
        ? motion.at(cx, by - 1)
        : left;
    return _medianVector(left, top, topRight);
  }
}

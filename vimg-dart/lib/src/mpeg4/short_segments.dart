part of 'decoder.dart';

extension _H263IndependentSegments on _H263Macroblocks {
  void _setSegmentBounds(List<_H263Slice> layout, Map<int, int> counts) {
    final size = header.macroblockSize;
    final width = (picture.width + 15) & -16;
    final height = (picture.height + 15) & -16;
    final segments = <_MotionBounds>{};
    for (final slice in layout) {
      final group = slice.header;
      final columns = group.width ?? _columns;
      final left = group.address % _columns * size;
      final top = group.address ~/ _columns * size;
      final right = left + columns * size;
      final bottom = top + (counts[group.address]! ~/ columns) * size;
      _segmentBounds[group.address] = (
        left: left,
        top: top,
        right: right,
        bottom: bottom,
      );
      // Store the segmentation of the 16-sample padded reference. The
      // extra RRU padding is only needed while decoding a 32-sample grid.
      segments.add((
        left: left,
        top: top,
        right: math.min(right, width),
        bottom: math.min(bottom, height),
      ));
    }
    picture._segments = segments;
  }

  _MotionBounds? _boundsAt(int index) => header.format.independentSegments
      ? _segmentBounds[_sliceOwners![index] - 1]
      : null;

  void _validateTemporalSegments(H263Picture? reference) {
    final segments = picture._segments;
    if (segments == null ||
        reference == null ||
        _validatedReferences.contains(reference))
      return;
    final past = reference._segments;
    if (past == null ||
        segments.length != past.length ||
        !past.containsAll(segments)) {
      throw const FormatException(
        'H.263+ temporal reference changed independent segment boundaries',
      );
    }
    _validatedReferences.add(reference);
  }

  Iterable<_MotionBounds> _upwardSegments(H263Picture lower) {
    final (layout: layout, counts: _) = _preparedSlices;
    final lowerSegments = lower._segments;
    if (lowerSegments == null) {
      throw const FormatException(
        'H.263+ independent enhancement needs an independent lower layer',
      );
    }
    final bounds = layout.map((slice) => _segmentBounds[slice.header.address]!);
    if (!header.enhancementIntra) return bounds;
    final shiftX = lower.width == picture.width ? 0 : 1;
    final shiftY = lower.height == picture.height ? 0 : 1;
    for (final segment in bounds) {
      final left = segment.left >> shiftX, top = segment.top >> shiftY;
      final right = math.min(segment.right, picture.width) >> shiftX;
      final bottom = math.min(segment.bottom, picture.height) >> shiftY;
      if (!lowerSegments.any(
        (source) =>
            source.left <= left &&
            source.top <= top &&
            source.right >= right &&
            source.bottom >= bottom,
      )) {
        throw const FormatException(
          'H.263+ independent EI segment crosses a lower-layer segment',
        );
      }
    }
    return bounds;
  }
}

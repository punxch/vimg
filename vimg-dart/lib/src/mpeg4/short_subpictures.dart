part of 'decoder.dart';

typedef _H263ReferencePixels =
    List<int> Function(int plane, int lumaStride, int lumaHeight);

typedef _H263SampleTile = ({int width, int lumaSize, Uint8List samples});

final class _H263SubPictures {
  _H263SubPictures(
    this.tileWidth,
    this.tileHeight,
    this.columns,
    this.stride,
    this.height,
    this.tiles,
    this.active,
  );

  final int tileWidth, tileHeight, columns, stride, height, active;
  final List<_H263SampleTile?> tiles;

  static H263Picture remove(
    H263Picture source,
    H263ErpsBufferSize size,
    String bitmap,
  ) {
    final prior = source._subPictures;
    final width = size.width * 16, height = size.height * 16;
    final (:columns, rows: _) = h263ErpsGrid(size, (
      source.width,
      source.height,
    ));
    final tiles = <_H263SampleTile?>[];
    var active = 0;
    for (var index = 0; index < bitmap.length; index++) {
      if (bitmap.codeUnitAt(index) == 49) {
        tiles.add(null);
        continue;
      }
      final data = prior == null
          ? _copyTile(source, width, height, index % columns, index ~/ columns)
          : prior.tiles[index];
      if (data == null) {
        throw const FormatException(
          'H.263+ ERPS bitmap restores an unused sub-picture',
        );
      }
      tiles.add(data);
      active++;
    }
    final subPictures = _H263SubPictures(
      width,
      height,
      columns,
      source.stride,
      source.rows * 16,
      tiles,
      active,
    );
    return H263Picture._reference(
      source.format,
      subPictures.plane,
      reduced: false,
      subPictures: subPictures,
    ).._segments = source._segments;
  }

  static _H263SampleTile _copyTile(
    H263Picture source,
    int tileWidth,
    int tileHeight,
    int column,
    int row,
  ) {
    final left = column * tileWidth, top = row * tileHeight;
    final width = math.min(tileWidth, source.stride - left);
    final height = math.min(tileHeight, source.rows * 16 - top);
    // The buffer counts an edge tile as one unit. Its samples need storage
    // only up to the coded picture edge.
    final lumaSize = width * height;
    final samples = Uint8List(lumaSize * 3 ~/ 2);
    for (var plane = 0; plane < 3; plane++) {
      final sub = plane == 0 ? 0 : 1;
      final stride = source.stride >> sub;
      final length = width >> sub, lines = height >> sub;
      final from = (top >> sub) * stride + (left >> sub);
      final input = source.planes[plane];
      final offset = plane == 0 ? 0 : lumaSize + (plane - 1) * length * lines;
      for (var y = 0; y < lines; y++) {
        final start = offset + y * length;
        samples.setRange(start, start + length, input, from + y * stride);
      }
    }
    return (width: width, lumaSize: lumaSize, samples: samples);
  }

  List<int> plane(int index, int lumaStride, int lumaHeight) =>
      _H263SubPicturePlane(this, index, lumaStride, lumaHeight);
}

abstract class _H263ReadOnlyPlane extends ListBase<int> {
  @override
  set length(int value) => throw UnsupportedError('Read-only reference plane');

  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('Read-only reference plane');
}

final class _H263SubPicturePlane extends _H263ReadOnlyPlane {
  _H263SubPicturePlane(this.source, this._plane, int lumaStride, int lumaHeight)
    : _stride = lumaStride >> (_plane == 0 ? 0 : 1),
      _height = lumaHeight >> (_plane == 0 ? 0 : 1);

  final _H263SubPictures source;
  final int _plane, _stride, _height;
  late final _sub = _plane == 0 ? 0 : 1;
  late final _canonicalStride = source.stride >> _sub;
  late final _canonicalHeight = source.height >> _sub;
  late final _width = source.tileWidth >> _sub;
  late final _lines = source.tileHeight >> _sub;

  @override
  int get length => _stride * _height;

  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final x = math.min(index % _stride, _canonicalStride - 1);
    final y = math.min(index ~/ _stride, _canonicalHeight - 1);
    final area = source.tiles[(y ~/ _lines) * source.columns + x ~/ _width];
    if (area == null) {
      throw const FormatException(
        'H.263+ motion references an unused ERPS sub-picture',
      );
    }
    final (width: width, lumaSize: lumaSize, samples: samples) = area;
    final offset = _plane == 0 ? 0 : lumaSize + (_plane - 1) * (lumaSize >> 2);
    return samples[offset + y % _lines * (width >> _sub) + x % _width];
  }
}

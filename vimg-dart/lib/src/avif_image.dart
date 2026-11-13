import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'av1/access_units.dart';
import 'av1/picture_decoder.dart';
import 'binary_file.dart';
import 'iso_media.dart';

/// Decode the primary image item, which also serves as an animation's cover.
/// Return null when the input is a different image format.
image.Image? readAvifImage(String path) {
  final handle = File(path).openSync();
  try {
    final file = BinaryFile(handle);
    if (file.length < 8) return null;
    final media = IsoMedia(file);
    final firstTag = media.tag(4);
    if (!const {'ftyp', 'free', 'skip', 'wide'}.contains(firstTag)) return null;
    final boxes = media.boxes(0, file.length);
    final type = boxes
        .skipWhile((box) => const {'free', 'skip', 'wide'}.contains(box.type))
        .firstOrNull;
    if (type == null || type.type != 'ftyp' || !isAvifBrand(media, type)) {
      return null;
    }
    final meta = boxes.where((box) => box.type == 'meta').firstOrNull;
    if (meta == null) {
      throw const FormatException('Missing AVIF image metadata');
    }
    return _AvifItems(media, meta).decodePrimary();
  } finally {
    handle.closeSync();
  }
}

bool isAvifBrand(IsoMedia media, MediaBox box) {
  media.requireBytes(box, 8);
  if ((box.end - box.data) % 4 != 0) {
    throw const FormatException('Invalid AVIF brand list');
  }
  for (var at = box.data; at < box.end; at += 4) {
    if (at == box.data + 4) continue; // minor version
    final tag = media.tag(at);
    if (tag == 'avif' || tag == 'avis') return true;
  }
  return false;
}

Uint8List avifConfiguration(IsoMedia media, MediaBox box) {
  media.requireBytes(box, 4);
  final length = box.end - box.data - 4;
  if (media.file.unsigned(box.data, 1) != 0x81 || length > 1024 * 1024) {
    throw const FormatException('Invalid AVIF AV1 configuration');
  }
  return media.file.read(box.data + 4, length);
}

typedef _Extent = ({int offset, int length});
typedef _Location = ({
  int method,
  int dataReference,
  int base,
  List<_Extent> extents,
});
typedef _Reference = ({String type, int from, List<int> to});
typedef _Association = ({MediaBox box, bool essential});
typedef _Color = ({int matrix, bool fullRange});

final class _AvifItems {
  _AvifItems(this.media, MediaBox meta)
    : boxes = media.children(meta, skip: 4).toList();

  final IsoMedia media;
  final List<MediaBox> boxes;
  BinaryFile get file => media.file;
  late final _types = _itemTypes();
  late final _locations = _itemLocations();
  late final _properties = _itemProperties();
  late final _references = _itemReferences();
  static const _maxItemBytes = 64 * 1024 * 1024;
  static const _maxImagePixels = 32 * 1024 * 1024;

  MediaBox? _box(String type) =>
      boxes.where((box) => box.type == type).firstOrNull;

  _Fields _required(String type) => _Fields(
    file,
    _box(type) ?? (throw FormatException('Missing AVIF $type box')),
  );

  image.Image decodePrimary() {
    final pitm = _required('pitm');
    final primary = pitm.read(pitm.version(1) == 0 ? 2 : 4);
    var pixels = _decodeItem(primary);
    final alpha = _references
        .where((r) => r.type == 'auxl' && r.to.contains(primary))
        .map((r) => r.from)
        .where(_isAlpha)
        .firstOrNull;
    if (alpha != null) {
      final opacity = _decodeItem(alpha, alpha: true);
      if (pixels.width != opacity.width || pixels.height != opacity.height) {
        throw const FormatException('AVIF alpha dimensions differ from color');
      }
      final premultiplied = _references.any(
        (r) => r.type == 'prem' && r.from == primary && r.to.contains(alpha),
      );
      pixels = pixels.convert(numChannels: 4);
      for (final pixel in pixels) {
        final a = opacity.getPixel(pixel.x, pixel.y).r.toInt();
        if (premultiplied && a > 0 && a < 255) {
          pixel.setRgb(
            math.min(255, (pixel.r * 255 / a).round()),
            math.min(255, (pixel.g * 255 / a).round()),
            math.min(255, (pixel.b * 255 / a).round()),
          );
        }
        pixel.a = a;
      }
    }
    for (final property in _propertiesOf(primary)) {
      switch (property.type) {
        case 'clap':
          pixels = _crop(pixels, property);
        case 'irot':
          final angle = _Fields(file, property).read(1);
          if (angle > 3) throw const FormatException('Invalid AVIF rotation');
          if (angle != 0) pixels = image.copyRotate(pixels, angle: -90 * angle);
        case 'imir':
          final axis = _Fields(file, property).read(1);
          pixels = switch (axis) {
            0 => image.flipVertical(pixels),
            1 => image.flipHorizontal(pixels),
            _ => throw const FormatException('Invalid AVIF mirror axis'),
          };
      }
    }
    return pixels;
  }

  bool _isAlpha(int id) {
    final type = _property(id, 'auxC');
    if (type == null) return false;
    final fields = _Fields(file, type)..version(0);
    final bytes = file.read(
      fields.offset,
      math.min(128, type.end - fields.offset),
    );
    final end = bytes.indexOf(0);
    return end >= 0 &&
        ascii.decode(bytes.sublist(0, end), allowInvalid: true) ==
            'urn:mpeg:mpegB:cicp:systems:auxiliary:alpha';
  }

  Iterable<MediaBox> _propertiesOf(int id) =>
      (_properties[id] ?? const <_Association>[]).map((entry) => entry.box);

  MediaBox? _property(int id, String type) =>
      _propertiesOf(id).where((box) => box.type == type).firstOrNull;

  void _checkProperties(int id) {
    for (final (:box, :essential)
        in _properties[id] ?? const <_Association>[]) {
      if (essential &&
          !const {
            'av1C',
            'ispe',
            'pixi',
            'colr',
            'pasp',
            'auxC',
            'clap',
            'irot',
            'imir',
            'a1op',
            'lsel',
          }.contains(box.type)) {
        throw FormatException(
          'Unsupported essential AVIF property: ${box.type}',
        );
      }
    }
  }

  _Color? _color(int id) {
    for (final box in _propertiesOf(id)) {
      if (box.type != 'colr') continue;
      final fields = _Fields(file, box);
      if (fields.read(4) != 0x6e636c78) continue; // nclx
      fields.read(4); // primaries and transfer do not affect YUV to RGB
      return (matrix: fields.read(2), fullRange: fields.read(1) & 0x80 != 0);
    }
    return null;
  }

  image.Image _decodeItem(int id, {bool alpha = false}) {
    final color = alpha ? null : _color(id);
    return switch (_types[id]) {
      'av01' => _decodeCoded(id, color, alpha: alpha),
      'grid' => _decodeGrid(id, color, alpha: alpha),
      final type => throw FormatException('Unsupported AVIF image item: $type'),
    };
  }

  image.Image _decodeCoded(int id, _Color? color, {required bool alpha}) {
    _checkProperties(id);
    if (_types[id] != 'av01') {
      throw const FormatException('AVIF grid requires coded AV1 tiles');
    }
    final configuration = _property(id, 'av1C');
    if (configuration == null) {
      throw const FormatException('Missing AVIF image configuration');
    }
    final op = _property(id, 'a1op');
    final operatingPoint = op == null ? 0 : _Fields(file, op).read(1);
    final selector = _property(id, 'lsel');
    final layer = selector == null ? 0xffff : _Fields(file, selector).read(2);
    if (layer != 0xffff && layer > 3) {
      throw const FormatException('Invalid AVIF layer selector');
    }
    final units = Av1AccessUnits(operatingPoint: operatingPoint)
      ..configure(avifConfiguration(media, configuration));
    final decoder = Av1StreamDecoder();
    Av1CodedFrame? selected;
    Av1Picture? displayed;
    for (final frame in units.readSample(_itemBytes(id))) {
      final picture = decoder.decode(frame);
      if (frame.shown && (layer == 0xffff || layer == frame.spatialId)) {
        selected = frame;
        displayed = picture;
      }
    }
    if (displayed == null) {
      throw const FormatException('Missing displayed AVIF item frame');
    }
    final dimensions = _property(id, 'ispe');
    if (dimensions != null) {
      final fields = _Fields(file, dimensions)..version(0);
      final width = fields.read(4), height = fields.read(4);
      if (displayed.planes[0].width != width ||
          displayed.planes[0].height != height) {
        throw const FormatException('AVIF item dimensions differ from ispe');
      }
    }
    if (alpha) return _opacity(displayed);
    return applyAv1FilmGrain(
      displayed,
      selected!.header.parameters.filmGrain,
    ).rgb(matrix: color?.matrix, fullRange: color?.fullRange);
  }

  image.Image _opacity(Av1Picture picture) {
    if (!picture.color.monochrome) {
      throw const FormatException('Expected monochrome AVIF alpha');
    }
    final plane = picture.planes[0];
    final depth = picture.color.depth;
    final shift = depth - 8;
    final minimum = picture.color.fullRange ? 0 : 16 << shift;
    final range = picture.color.fullRange ? (1 << depth) - 1 : 219 << shift;
    final output = image.Image(width: plane.width, height: plane.height);
    for (final pixel in output) {
      final value = plane.samples[pixel.y * plane.stride + pixel.x] - minimum;
      final opacity = ((value * 255 + (range >> 1)) ~/ range).clamp(0, 255);
      pixel.setRgb(opacity, opacity, opacity);
    }
    return output;
  }

  image.Image _decodeGrid(int id, _Color? color, {required bool alpha}) {
    _checkProperties(id);
    final header = _itemBytes(id, limit: 12);
    if (header.length < 4 || header[0] != 0 || header[1] > 1) {
      throw const FormatException('Invalid AVIF grid header');
    }
    final rows = header[2] + 1, columns = header[3] + 1;
    final wide = header[1] == 1;
    if (header.length != (wide ? 12 : 8)) {
      throw const FormatException('Invalid AVIF grid dimensions');
    }
    final data = ByteData.sublistView(header);
    final width = wide ? data.getUint32(4) : data.getUint16(4);
    final height = wide ? data.getUint32(8) : data.getUint16(6);
    if (width == 0 || height == 0 || width > _maxImagePixels ~/ height) {
      throw const FormatException('AVIF grid exceeds the decoder size limit');
    }
    final tiles = [
      for (final ref in _references)
        if (ref.type == 'dimg' && ref.from == id) ...ref.to,
    ];
    if (tiles.length != rows * columns) {
      throw const FormatException('AVIF grid tile count differs from layout');
    }
    final first = _decodeCoded(
      tiles.first,
      color ?? (alpha ? null : _color(tiles.first)),
      alpha: alpha,
    );
    final w = first.width, h = first.height;
    if (width <= w * (columns - 1) ||
        width > w * columns ||
        height <= h * (rows - 1) ||
        height > h * rows) {
      throw const FormatException('AVIF grid tiles do not cover the image');
    }
    final output = image.Image(width: width, height: height);
    for (final (index, tile) in tiles.indexed) {
      final pixels = index == 0
          ? first
          : _decodeCoded(
              tile,
              color ?? (alpha ? null : _color(tile)),
              alpha: alpha,
            );
      if (pixels.width != w || pixels.height != h) {
        throw const FormatException('AVIF grid tiles differ in dimensions');
      }
      final x = index % columns * w, y = index ~/ columns * h;
      final copyWidth = math.min(w, width - x),
          copyHeight = math.min(h, height - y);
      image.compositeImage(
        output,
        pixels,
        dstX: x,
        dstY: y,
        dstW: copyWidth,
        dstH: copyHeight,
        srcW: copyWidth,
        srcH: copyHeight,
        blend: image.BlendMode.direct,
      );
    }
    return output;
  }

  image.Image _crop(image.Image source, MediaBox property) {
    final fields = _Fields(file, property);
    double fraction({bool signed = false}) {
      final raw = fields.read(4);
      final n = signed && raw >= 0x80000000 ? raw - 0x100000000 : raw;
      final d = fields.read(4);
      if (d == 0) throw const FormatException('Invalid AVIF clean aperture');
      return n / d;
    }

    final w = fraction(), h = fraction();
    final left = (source.width - w) / 2 + fraction(signed: true);
    final top = (source.height - h) / 2 + fraction(signed: true);
    if (w <= 0 ||
        h <= 0 ||
        left < 0 ||
        top < 0 ||
        left + w > source.width ||
        top + h > source.height ||
        [w, h, left, top].any((value) => value != value.round())) {
      throw const FormatException('Invalid AVIF clean aperture');
    }
    return image.copyCrop(
      source,
      x: left.toInt(),
      y: top.toInt(),
      width: w.toInt(),
      height: h.toInt(),
    );
  }

  Map<int, String> _itemTypes() {
    final info = _required('iinf');
    final count = info.read(info.version(1) == 0 ? 2 : 4);
    final entries = media.boxes(info.offset, info.box.end);
    final types = <int, String>{};
    var seen = 0;
    for (final entry in entries) {
      if (seen++ >= count || entry.type != 'infe') {
        throw const FormatException('Invalid AVIF item information table');
      }
      final fields = _Fields(file, entry);
      final version = fields.version(3);
      if (version < 2) continue; // old metadata entries lack an item type
      final id = fields.read(version == 2 ? 2 : 4);
      final protected = fields.read(2);
      final typeAt = fields.offset;
      fields.read(4);
      if (types.containsKey(id)) {
        throw const FormatException('Duplicate AVIF item ID');
      }
      types[id] = protected == 0 ? media.tag(typeAt) : 'protected';
    }
    if (seen != count) throw const FormatException('Truncated AVIF item table');
    return types;
  }

  Map<int, _Location> _itemLocations() {
    final fields = _required('iloc');
    final version = fields.version(2);
    final sizes = fields.read(2);
    final offsetSize = sizes >> 12, lengthSize = (sizes >> 8) & 15;
    final baseSize = (sizes >> 4) & 15;
    final indexSize = version == 0 ? 0 : sizes & 15;
    if ([offsetSize, lengthSize, baseSize, indexSize].any((n) => n > 8)) {
      throw const FormatException('Invalid AVIF item location widths');
    }
    final idSize = version == 2 ? 4 : 2;
    final count = fields.read(idSize);
    final items = <int, _Location>{};
    var extentBudget = 100000;
    for (var i = 0; i < count; i++) {
      final id = fields.read(idSize);
      final method = version == 0 ? 0 : fields.read(2);
      final dataReference = fields.read(2);
      final base = fields.read(baseSize);
      final extents = fields.read(2);
      extentBudget -= extents;
      if (extentBudget < 0 || items.containsKey(id)) {
        throw const FormatException('Invalid or oversized AVIF item locations');
      }
      final ranges = <_Extent>[];
      for (var j = 0; j < extents; j++) {
        fields.read(indexSize);
        ranges.add((
          offset: fields.read(offsetSize),
          length: fields.read(lengthSize),
        ));
      }
      items[id] = (
        method: method,
        dataReference: dataReference,
        base: base,
        extents: ranges,
      );
    }
    return items;
  }

  Uint8List _itemBytes(int id, {int limit = _maxItemBytes}) {
    final location = _locations[id];
    if (location == null || location.extents.isEmpty) {
      throw const FormatException('Missing AVIF item data');
    }
    if (location.method > 1 || location.dataReference != 0) {
      throw const FormatException('Unsupported AVIF item data location');
    }
    final inline = location.method == 0
        ? null
        : _box('idat') ??
              (throw const FormatException('Missing AVIF idat box'));
    final origin = inline?.data ?? 0;
    final available = (inline?.end ?? file.length) - origin;
    if (location.base < 0 || location.base > available) {
      throw const FormatException('AVIF item base is out of bounds');
    }
    final end = available - location.base;
    final parts = BytesBuilder(copy: false);
    for (final extent in location.extents) {
      if (extent.offset < 0 || extent.offset > end || extent.length < 0) {
        throw const FormatException('AVIF item extent is out of bounds');
      }
      final remaining = end - extent.offset;
      final size = extent.length == 0 ? remaining : extent.length;
      if (size > remaining || size > limit - parts.length) {
        throw const FormatException('Invalid or oversized AVIF item extent');
      }
      parts.add(file.read(origin + location.base + extent.offset, size));
    }
    return parts.takeBytes();
  }

  Map<int, List<_Association>> _itemProperties() {
    final iprp = _box('iprp');
    final ipco = media.child(iprp, 'ipco');
    if (iprp == null || ipco == null) return {};
    final properties = media.children(ipco).toList();
    final associated = <int, List<_Association>>{};
    for (final ipma in media.children(iprp).where((b) => b.type == 'ipma')) {
      final fields = _Fields(file, ipma);
      final idSize = fields.version(1) == 0 ? 2 : 4;
      final indexSize = file.unsigned(ipma.data + 1, 3) & 1 != 0 ? 2 : 1;
      final mask = (1 << (indexSize * 8 - 1)) - 1;
      final count = fields.read(4);
      for (var i = 0; i < count; i++) {
        final id = fields.read(idSize);
        final size = fields.read(1);
        final selected = associated.putIfAbsent(id, () => []);
        for (var j = 0; j < size; j++) {
          final association = fields.read(indexSize);
          final index = association & mask;
          if (index > properties.length) {
            throw const FormatException('Invalid AVIF item property index');
          }
          if (index == 0) continue;
          selected.add((
            box: properties[index - 1],
            essential: association > mask,
          ));
        }
      }
    }
    return associated;
  }

  List<_Reference> _itemReferences() {
    final box = _box('iref');
    if (box == null) return [];
    final fields = _Fields(file, box);
    final idSize = fields.version(1) == 0 ? 2 : 4;
    return [
      for (final ref in media.boxes(fields.offset, box.end))
        if (const {'auxl', 'prem', 'dimg'}.contains(ref.type))
          _reference(ref, idSize),
    ];
  }

  _Reference _reference(MediaBox box, int idSize) {
    final fields = _Fields(file, box);
    final from = fields.read(idSize);
    final count = fields.read(2);
    return (
      type: box.type,
      from: from,
      to: [for (var i = 0; i < count; i++) fields.read(idSize)],
    );
  }
}

final class _Fields {
  _Fields(this.file, this.box) : offset = box.data;

  final BinaryFile file;
  final MediaBox box;
  int offset;

  int read(int size) {
    if (size == 0) return 0;
    if (size > box.end - offset) {
      throw FormatException('Truncated AVIF ${box.type} box');
    }
    final value = file.unsigned(offset, size);
    offset += size;
    return value;
  }

  int version(int maximum) {
    final value = read(4) >> 24;
    if (value > maximum) {
      throw FormatException('Unsupported AVIF ${box.type} version $value');
    }
    return value;
  }
}

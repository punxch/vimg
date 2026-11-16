part of 'decoder.dart';

typedef _H263NumberedReference = ({int number, _H263Reference frame});

final class _H263ErpsBuffer {
  var _short = <int, _H263NumberedReference>{};
  var _long = <int, _H263NumberedReference>{};
  var _longLimit = 0;
  H263ErpsBufferSize? _size;
  (int, int)? _dimensions;
  var _used = 0;

  void checkResamplingCapacity(H263Format format) {
    final size = _size!;
    final (:columns, :rows) = h263ErpsGrid(size, (format.width, format.height));
    if (_used + columns * rows > size.capacity) {
      throw const FormatException(
        'H.263+ ERPS buffer has no room for resampling',
      );
    }
  }

  List<_H263Reference> ordered(H263Erps selection) {
    final front = <_H263NumberedReference>{};
    for (final (:longTerm, :index) in selection.remapping) {
      final entry = (longTerm ? _long : _short)[index];
      if (entry == null) {
        throw FormatException('Missing H.263+ ERPS reference index $index');
      }
      if (!front.add(entry)) {
        throw const FormatException('Duplicate H.263+ ERPS remapping');
      }
    }
    final indices = _long.keys.toList()..sort();
    return [
      for (final entry in front) entry.frame,
      for (final entry in _short.values.toList().reversed)
        if (!front.contains(entry)) entry.frame,
      for (final index in indices)
        if (!front.contains(_long[index]!)) _long[index]!.frame,
    ];
  }

  void save(H263Erps selection, _H263Reference frame) {
    final change = selection.size;
    final reset = change?.reset == true;
    final size = change ?? _size;
    if (size == null || _size == null && !reset) {
      throw const FormatException('Missing initial H.263+ ERPS buffer reset');
    }
    final dimensions = (frame.picture.width, frame.picture.height);
    if (!reset &&
        (size.width != _size!.width ||
            size.height != _size!.height ||
            dimensions != _dimensions)) {
      throw const FormatException(
        'H.263+ ERPS buffer geometry changed without reset',
      );
    }
    final (:columns, :rows) = h263ErpsGrid(size, dimensions);
    final count = columns * rows;
    int occupied(_H263NumberedReference entry) =>
        entry.frame.picture._subPictures?.active ?? count;

    final short = reset ? <int, _H263NumberedReference>{} : {..._short};
    final long = reset ? <int, _H263NumberedReference>{} : {..._long};
    final number = selection.number;
    if (short.containsKey(number)) {
      throw const FormatException(
        'Duplicate H.263+ ERPS short-term picture number',
      );
    }
    short[number] = (number: number, frame: frame);
    var longLimit = _longLimit;
    for (final (:operation, :argument, :destination, size: _, :removal)
        in selection.commands) {
      switch (operation) {
        case H263ErpsOperation.removeShort:
          short.remove(argument);
        case H263ErpsOperation.removeLong:
          long.remove(argument);
        case H263ErpsOperation.removeShortRegions:
        case H263ErpsOperation.removeLongRegions:
          final references = operation == H263ErpsOperation.removeShortRegions
              ? short
              : long;
          if (references[argument] case final entry?) {
            final old = entry.frame;
            final remaining = _H263SubPictures.remove(
              old.picture,
              size,
              removal!,
            );
            references[argument] = (
              number: entry.number,
              frame: (
                picture: remaining,
                temporal: old.temporal,
                resamplingRound: old.resamplingRound,
                reduced: old.reduced,
                motion: old.motion,
                intraWithMotion: old.intraWithMotion,
              ),
            );
          }
        case H263ErpsOperation.assignLong:
          if (destination! >= longLimit) {
            throw const FormatException(
              'H.263+ ERPS long-term index exceeds limit',
            );
          }
          final entry = short.remove(argument);
          if (entry == null) {
            if (long[destination]?.number != argument) {
              throw const FormatException(
                'Missing H.263+ ERPS picture for long-term assignment',
              );
            }
          } else {
            long[destination] = entry;
          }
        case H263ErpsOperation.limitLong:
          longLimit = argument;
          long.removeWhere((index, _) => index >= longLimit);
        case H263ErpsOperation.resize:
          // Geometry and resets are validated before changing the buffer.
          break;
      }
    }
    var used = [
      ...short.values,
      ...long.values,
    ].fold(0, (total, entry) => total + occupied(entry));
    if (selection.sliding) {
      while (short.length > 1 && used > size.capacity) {
        used -= occupied(short.remove(short.keys.first)!);
      }
    }
    if (used > size.capacity) {
      throw const FormatException('H.263+ ERPS reference buffer full');
    }
    _short = short;
    _long = long;
    _longLimit = longLimit;
    _size = size;
    _dimensions = dimensions;
    _used = used;
  }
}

typedef _H263ErpsGroup = ({
  H263Erps syntax,
  List<_H263Reference> references,
  int backwardCount,
});

final class _H263ErpsSelection {
  _H263ErpsSelection(this.header, this.buffer, this.latest);

  final H263Header header;
  final _H263ErpsBuffer buffer;
  final _H263Reference? latest;
  final _resolved = <H263Picture, H263Picture>{};
  var _resampled = false;
  late final picture = _select(header.erps!);

  _H263ErpsGroup select(H263Erps layer) =>
      identical(layer, header.erps) ? picture : _select(layer);

  _H263ErpsGroup _select(H263Erps layer) => (
    syntax: layer,
    references: buffer.ordered(layer),
    backwardCount: header.bidirectional ? (layer.twoBackward ? 2 : 1) : 0,
  );

  _H263Reference _at(_H263ErpsGroup group, int index) {
    if (index >= group.references.length) {
      throw FormatException('Missing H.263+ ERPS prediction reference $index');
    }
    return group.references[index];
  }

  _H263Reference backward(_H263ErpsGroup group, int index) {
    final source = _at(group, index);
    if (!_h263Matches(source.picture, header.format)) {
      throw const FormatException(
        'Invalid H.263+ ERPS backward reference size',
      );
    }
    return source;
  }

  _H263Forward forward(_H263ErpsGroup group, int index) {
    final source = _at(group, group.backwardCount + index);
    final warp =
        header.resampling != null ||
        !_h263Matches(source.picture, header.format);
    if (warp &&
        (header.erps!.multiple ||
            group.syntax.multiple ||
            source != _at(picture, picture.backwardCount))) {
      throw const FormatException(
        'H.263+ ERPS resampling requires one reference picture',
      );
    }
    final reference = _resolved.putIfAbsent(source.picture, () {
      if ((_resampled || warp) && _resolved.isNotEmpty) {
        throw const FormatException(
          'H.263+ ERPS resampling requires one reference picture',
        );
      }
      if (warp) buffer.checkResamplingCapacity(header.format);
      _resampled = warp;
      final round = header.bidirectional
          ? backward(picture, 0).resamplingRound
          : header.noRound;
      return _h263PredictionReference(
        source.picture,
        header,
        round ?? header.noRound,
      );
    });
    return (
      picture: reference,
      offset: header.pb?.offset ?? 0,
      distance: header.pb == null
          ? 0
          : h263PbDistance(latest!.temporal, header),
    );
  }

  ({int offset, int distance}) directTiming() {
    final ahead = backward(picture, 0).temporal;
    final behind = _at(picture, picture.backwardCount).temporal;
    final wrap = header.format.customClock ? 1024 : 256;
    final distance = (ahead - behind) % wrap;
    if (distance == 0) {
      throw const FormatException(
        'Invalid H.263+ ERPS direct prediction interval',
      );
    }
    return (
      offset: (header.temporalReference - behind) % wrap,
      distance: distance,
    );
  }
}

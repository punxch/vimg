part of 'decoder.dart';

typedef _H263NumberedReference = ({int number, _H263Reference frame});

final class _H263ErpsBuffer {
  var _short = <int, _H263NumberedReference>{};
  var _long = <int, _H263NumberedReference>{};
  var _longLimit = 0;
  H263ErpsBufferSize? _size;

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
    if (16 * size.width < frame.picture.width ||
        16 * size.height < frame.picture.height) {
      throw UnsupportedError('H.263+ ERPS sub-picture buffering');
    }
    if (!reset &&
        (size.width != _size!.width || size.height != _size!.height)) {
      throw const FormatException(
        'H.263+ ERPS buffer geometry changed without reset',
      );
    }

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
    for (final (:operation, :argument, :destination, size: _)
        in selection.commands) {
      switch (operation) {
        case H263ErpsOperation.removeShort:
          short.remove(argument);
        case H263ErpsOperation.removeLong:
          long.remove(argument);
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
    if (selection.sliding) {
      while (short.length > 1 && short.length + long.length > size.capacity) {
        short.remove(short.keys.first);
      }
    }
    if (short.length + long.length > size.capacity) {
      throw const FormatException('H.263+ ERPS reference buffer full');
    }
    _short = short;
    _long = long;
    _longLimit = longLimit;
    _size = size;
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

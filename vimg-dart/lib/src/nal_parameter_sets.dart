import 'dart:typed_data';

/// Keep one length-prefixed snapshot per change in the parameter sets.
final class NalParameterSets {
  NalParameterSets({this.lengthBytes = 4});

  final int lengthBytes;
  final _sets = <(int, int), Uint8List>{};
  Uint8List? _snapshot;

  void update((int, int) key, Uint8List nal) {
    final previous = _sets[key];
    if (previous != null &&
        previous.length == nal.length &&
        nal.indexed.every((byte) => previous[byte.$1] == byte.$2)) {
      return;
    }
    _sets[key] = Uint8List.fromList(nal);
    _snapshot = null;
  }

  Uint8List? snapshot() => _sets.isEmpty
      ? null
      : _snapshot ??= lengthPrefixNals(_sets.values, lengthBytes: lengthBytes);
}

Uint8List lengthPrefixNals(Iterable<Uint8List> nals, {int lengthBytes = 4}) {
  final buffer = Uint8List(
    nals.fold(0, (size, nal) => size + lengthBytes + nal.length),
  );
  var offset = 0;
  for (final nal in nals) {
    for (var i = lengthBytes - 1; i >= 0; i--) {
      buffer[offset++] = nal.length >> (8 * i);
    }
    buffer.setRange(offset, offset + nal.length, nal);
    offset += nal.length;
  }
  return buffer;
}

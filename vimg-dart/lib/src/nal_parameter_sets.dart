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

Uint8List annexBToLengthPrefixed(Uint8List bytes) {
  final nals = <Uint8List>[];
  var start = -1, zeros = 0;
  for (var i = 0; i < bytes.length; i++) {
    final byte = bytes[i];
    if (byte == 0) {
      zeros++;
      continue;
    }
    if (byte == 1 && zeros >= 2) {
      if (start >= 0 && i - zeros > start) {
        nals.add(Uint8List.sublistView(bytes, start, i - zeros));
      }
      start = i + 1;
    }
    zeros = 0;
  }
  if (start >= 0 && bytes.length - zeros > start) {
    nals.add(Uint8List.sublistView(bytes, start, bytes.length - zeros));
  }
  if (nals.isEmpty) throw const FormatException('Missing Annex B NAL units');
  return lengthPrefixNals(nals);
}

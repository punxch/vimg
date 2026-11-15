part of 'mpeg_systems.dart';

/// Read slice headers in decode order, then order the displayed pictures by
/// POC within each reset epoch. CRA pictures can retain the previous epoch.
List<int> _nalDisplayOrder(
  List<_AccessUnit> frames,
  Map<int, Uint8List> configurations,
  String codec,
  Uint8List Function(_AccessUnit) read,
) {
  final first = frames.indexWhere(
    (frame) => configurations.containsKey(frame.offset),
  );
  if (first < 0) {
    throw const FormatException('Missing MPEG video random-access picture');
  }
  final initial = configurations[frames[first].offset]!;
  final avc = codec == 'h264' ? AvcConfiguration.inBand(initial) : null;
  final hevc = codec == 'hevc' ? HevcConfiguration.inBand(initial) : null;
  final avcReferences = ReferenceState();
  final hevcOrder = HevcPictureOrder();
  final pictures = <({int index, int epoch, int poc})>[];
  var epoch = 0;
  for (var i = first; i < frames.length; i++) {
    final frame = frames[i];
    if (frame.size <= 0 || frame.size > 64 * 1024 * 1024) {
      throw const FormatException('Invalid MPEG access unit size');
    }
    final bytes = read(frame);
    if (hevc != null) {
      final slice = hevc.slices(bytes).firstOrNull;
      if (slice == null)
        throw const FormatException('Missing HEVC picture order');
      final order = hevcOrder.observe(slice);
      if (order.reset) epoch++;
      if (order.output) pictures.add((index: i, epoch: epoch, poc: order.poc));
    } else {
      final order = _avcDisplayOrder(avc!, avcReferences, bytes);
      if (order.reset) epoch++;
      pictures.add((index: i, epoch: epoch, poc: order.poc));
    }
  }
  if (pictures.isEmpty) {
    throw const FormatException('MPEG video has no display pictures');
  }
  pictures.sort((a, b) {
    final epoch = a.epoch.compareTo(b.epoch);
    if (epoch != 0) return epoch;
    final poc = a.poc.compareTo(b.poc);
    return poc == 0 ? a.index.compareTo(b.index) : poc;
  });
  return [for (final picture in pictures) picture.index];
}

({int poc, bool reset}) _avcDisplayOrder(
  AvcConfiguration configuration,
  ReferenceState references,
  Uint8List sample,
) {
  SliceHeader? previous;
  int? poc;
  var reset = false;
  for (final nal in configuration.nals(sample)) {
    final type = nal[0] & 31;
    if (type == 7 || type == 8) {
      configuration.store(nal);
    } else if (type == 1 || type == 5) {
      final slice = SliceHeader(nal, configuration.pictures);
      if (slice.colorPlane != 0 || previous?.samePicture(slice) == true) {
        continue;
      }
      final pending = references.begin(slice);
      references.commit(pending, null);
      final clearsNumber = slice.marking?.any((entry) => entry.op == 5) == true;
      reset |= pending.idrStart || clearsNumber;
      final fieldOrder = pending.pocFor(slice.bottomField);
      poc = clearsNumber ? 0 : math.min(poc ?? fieldOrder, fieldOrder);
      previous = slice;
    }
  }
  if (poc == null) throw const FormatException('Missing H.264 picture order');
  return (poc: poc, reset: reset);
}

int? _displayPeriod(Map<int, int>? stamps) {
  if (stamps == null) return null;
  final cadence = <int, int>{};
  MapEntry<int, int>? previous;
  for (final stamp in stamps.entries) {
    final last = previous;
    if (last != null) {
      final step = ((stamp.value - last.value) / (stamp.key - last.key))
          .round();
      if (step > 0) cadence.update(step, (n) => n + 1, ifAbsent: () => 1);
    }
    previous = stamp;
  }
  return _mode(cadence);
}

int? _mode(Map<int, int> counts) => counts.entries.fold(null, (mode, entry) {
  if (mode == null || entry.value > counts[mode]!) return entry.key;
  if (entry.value == counts[mode]! && entry.key < mode) return entry.key;
  return mode;
});

List<int> _nalPresentationTimes(
  int count,
  List<int> order,
  Map<int, int> stamps,
  (int, int)? timing,
  int period,
) {
  final display = _presentationTimes(order.length, stamps, timing, period);
  final physical = List.filled(count, display.first);
  for (final (i, index) in order.indexed) {
    physical[index] = display[i];
  }
  return physical;
}

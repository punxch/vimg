part of 'matroska.dart';

const _cuesId = 0x1c53bb6b;

typedef MatroskaCue = ({
  int clusterOffset,
  int? relativePosition,
  int? blockNumber,
  int ticks,
  int timestampScale,
  int trackNumber,
  int? defaultDuration,
  EbmlElement? codecState,
});

typedef MatroskaCaptureIndex = ({
  List<({MatroskaCue cue, double latest})> cues,
  List<({int offset, double earliest})> clusters,
  double secondsPerTick,
});

extension MatroskaCues on Matroska {
  /// Begin at the closest indexed keyframe strictly before the target.
  /// The caller scans forward from this point so sparse Cues still work.
  MatroskaCue? previewCue(int seconds) {
    if (seconds <= 0) return null;
    final source = _cueSource();
    if (source == null) return null;
    final (:cues, :trackNumber, :track) = source;
    Map<int, EbmlElement>? position;
    var anchorTicks = -1;
    final secondsPerTick = _timestampScale / 1e9;
    for (final (:ticks, :entry) in _cuePositions(cues, trackNumber)) {
      if (ticks * secondsPerTick >= seconds) break;
      if (entry == null || ticks < anchorTicks) continue;
      if (ticks == anchorTicks) return null;
      anchorTicks = ticks;
      position = entry;
    }
    if (position == null) return null;
    final anchor = _resolveCue(position, anchorTicks, trackNumber, track);
    if (anchor == null ||
        element(anchor.clusterOffset, _segmentRoot.end).id != matroskaCluster) {
      return null;
    }
    return anchor;
  }

  MatroskaCaptureIndex? captureIndex() {
    final source = _cueSource();
    if (source == null) return null;
    final (:cues, :trackNumber, :track) = source;
    // The bounds below are for individual frames expressed in Segment Ticks.
    if (number(track[0x9c]) != 0 ||
        (floating(track[0x23314f]) ?? 1) != 1 ||
        (number(track[0x56aa]) ?? 0) != 0) {
      return null;
    }
    final secondsPerTick = _timestampScale / 1e9;
    final earliestByOffset = <({int offset, double earliest})>[];
    final times = <int, int>{};
    var offset = _segmentRoot.data, previousTime = -1;
    for (final child in segmentElements()) {
      final start = offset;
      offset = child.end;
      if (child.id != matroskaCluster) continue;
      final time = clusterTimestamp(child);
      if (time < 0 || time < previousTime || time > 0x7fffffffffff7fff) {
        return null;
      }
      previousTime = time;
      times[start] = time;
      earliestByOffset.add((
        offset: start,
        earliest: (time - 32768) * secondsPerTick,
      ));
    }
    final anchors = <({MatroskaCue cue, double latest})>[];
    var previousTicks = -1, previousOffset = -1;
    for (final (:ticks, :entry) in _cuePositions(cues, trackNumber)) {
      if (entry == null) continue;
      final cue = _resolveCue(entry, ticks, trackNumber, track);
      if (cue == null ||
          cue.clusterOffset < previousOffset ||
          ticks <= previousTicks) {
        return null;
      }
      final clusterTime = times[cue.clusterOffset];
      if (clusterTime == null ||
          ticks < clusterTime - 32768 ||
          ticks > clusterTime + 32767) {
        return null;
      }
      previousTicks = ticks;
      previousOffset = cue.clusterOffset;
      // Block timestamps are signed 16-bit offsets from the cluster timestamp.
      anchors.add((cue: cue, latest: (clusterTime + 32767) * secondsPerTick));
    }
    if (anchors.isEmpty) return null;
    return (
      cues: anchors,
      clusters: earliestByOffset,
      secondsPerTick: secondsPerTick,
    );
  }

  ({EbmlElement cues, int trackNumber, Map<int, EbmlElement> track})?
  _cueSource() {
    metadata();
    final cues = _cues;
    if (cues == null ||
        cues.unknownSize ||
        cues.end - cues.data > 4 * 1024 * 1024) {
      return null;
    }
    final track = firstVideoTrack;
    if (track == null) return null;
    final number = this.number(track[0xd7]);
    if (number == null || number <= 0) return null;
    return (cues: cues, trackNumber: number, track: track);
  }

  Iterable<({int ticks, Map<int, EbmlElement>? entry})> _cuePositions(
    EbmlElement cues,
    int trackNumber,
  ) sync* {
    for (final point in elements(cues.data, cues.end)) {
      if (point.id != 0xbb) continue;
      int? ticks;
      Map<int, EbmlElement>? position;
      for (final child in elements(point.data, point.end)) {
        if (child.id == 0xb3) {
          if (ticks != null) throw const FormatException('Duplicate CueTime');
          ticks = number(child);
        } else if (child.id == 0xb7) {
          final entry = fields(child);
          if (number(entry[0xf7]) != trackNumber) continue;
          if (position != null) {
            throw const FormatException(
              'Duplicate cue position for video track',
            );
          }
          position = entry;
        }
      }
      if (ticks == null || ticks < 0) {
        throw const FormatException('Invalid CueTime');
      }
      yield (ticks: ticks, entry: position);
    }
  }

  MatroskaCue? _resolveCue(
    Map<int, EbmlElement> anchor,
    int ticks,
    int trackNumber,
    Map<int, EbmlElement> track,
  ) {
    if (anchor.containsKey(0xdb)) return null;
    final root = _segmentRoot;
    final cluster = number(anchor[0xf1]);
    final relative = number(anchor[0xf0]);
    final block = number(anchor[0x5378]);
    final stateOffset = number(anchor[0xea]) ?? 0;
    final length = root.end - root.data;
    if (cluster == null ||
        cluster < 0 ||
        cluster >= length ||
        (relative != null && relative < 0) ||
        (block != null && block <= 0) ||
        stateOffset < 0 ||
        stateOffset >= length) {
      return null;
    }
    final clusterOffset = root.data + cluster;
    EbmlElement? state;
    if (stateOffset != 0) {
      state = element(root.data + stateOffset, root.end);
      if (state.id != 0xa4) return null;
    }
    return (
      clusterOffset: clusterOffset,
      relativePosition: relative,
      blockNumber: block,
      ticks: ticks,
      timestampScale: _timestampScale,
      trackNumber: trackNumber,
      defaultDuration: number(track[0x23e383]),
      codecState: state,
    );
  }

  Uint8List codecState(EbmlElement state) {
    final length = state.end - state.data;
    if (state.unknownSize || length == 0 || length > 1024 * 1024) {
      throw const FormatException('Invalid Matroska codec state length');
    }
    return file.read(state.data, length);
  }
}

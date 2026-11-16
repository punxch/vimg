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

extension MatroskaCues on Matroska {
  /// Begin at the closest indexed keyframe strictly before the target.
  /// The caller scans forward from this point so sparse Cues still work.
  MatroskaCue? previewCue(int seconds) {
    if (seconds <= 0) return null;
    metadata();
    final cues = _cues;
    if (cues == null ||
        cues.unknownSize ||
        cues.end - cues.data > 4 * 1024 * 1024) {
      return null;
    }
    final track = firstVideoTrack;
    if (track == null) return null;
    final trackNumber = number(track[0xd7]);
    if (trackNumber == null || trackNumber <= 0) return null;
    final root = _segmentRoot;
    Map<int, EbmlElement>? anchor;
    var anchorTicks = -1;
    final secondsPerTick = _timestampScale / 1e9;
    for (final point in elements(cues.data, cues.end)) {
      if (point.id != 0xbb) continue;
      int? ticks;
      Map<int, EbmlElement>? position;
      for (final child in elements(point.data, point.end)) {
        if (child.id == 0xb3) {
          if (ticks != null) return null;
          final value = number(child)!;
          if (value < 0) return null;
          ticks = value;
        } else if (child.id == 0xb7) {
          final entry = fields(child);
          if (number(entry[0xf7]) != trackNumber) continue;
          if (position != null) return null;
          position = entry;
        }
      }
      if (ticks == null) return null;
      if (ticks * secondsPerTick >= seconds) break;
      if (position == null || ticks < anchorTicks) continue;
      if (ticks == anchorTicks) return null;
      anchorTicks = ticks;
      anchor = position;
    }
    if (anchor == null || anchor.containsKey(0xdb)) return null;
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
    if (element(clusterOffset, root.end).id != matroskaCluster) return null;
    EbmlElement? state;
    if (stateOffset != 0) {
      state = element(root.data + stateOffset, root.end);
      if (state.id != 0xa4) return null;
    }
    return (
      clusterOffset: clusterOffset,
      relativePosition: relative,
      blockNumber: block,
      ticks: anchorTicks,
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

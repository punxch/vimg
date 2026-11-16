part of 'video.dart';

typedef _CaptureRegion = ({
  int first,
  int end,
  MatroskaCue? cue,
  int endCluster,
});

extension MatroskaCapture on Video {
  /// Prepare just the portions of the AVC or HEVC timeline used for capture.
  /// An incomplete or inconsistent local index leaves normal selection available.
  List<List<CaptureFrame>>? indexedCaptures(CapturePlan plan) {
    final media = _matroska;
    if (media == null || (codec != 'h264' && codec != 'hevc')) return null;
    try {
      final index = media.captureIndex();
      if (index == null) return null;
      final clusters = index.clusters;
      final regions = _captureRegions(index, plan);
      if (regions.length == 1 &&
          regions.single.cue == null &&
          regions.single.endCluster == clusters.length) {
        return null; // This would read the whole timeline anyway.
      }

      final selections = <List<CaptureFrame>>[];
      final indexedPackets = <FramePacket, _IndexedVideo>{};
      for (final region in regions) {
        final eof = region.endCluster == clusters.length;
        final stop = eof ? null : clusters[region.endCluster];
        final local = _indexNalVideo(
          matroskaStart: region.cue,
          matroskaEnd: stop?.offset,
        );
        // Unread blocks cannot appear before this presentation timestamp.
        final packets = local.timeline.presentation;
        final ready = plan.selectIndexedWindows(
          stop == null
              ? packets
              : packets.takeWhile((packet) => packet.seconds < stop.earliest),
          region.first,
          region.end,
          eof: eof,
        );
        if (ready == null) return null;
        selections.addAll(ready);
        for (final captures in ready) {
          for (final capture in captures) {
            indexedPackets[capture.packet] = local;
          }
        }
      }
      _cueCaptureIndexes = indexedPackets;
      return selections;
    } on FormatException {
      return null;
    } on UnsupportedError {
      return null;
    }
  }
}

List<_CaptureRegion> _captureRegions(
  MatroskaCaptureIndex index,
  CapturePlan plan,
) {
  final (:cues, :clusters, :secondsPerTick) = index;
  final regions = <_CaptureRegion>[];
  var anchor = -1, endCluster = 0;
  for (final (window, start) in plan.starts.indexed) {
    // Leave room for the scheduler rounding the seek to the nearest source tick.
    while (anchor + 1 < cues.length &&
        cues[anchor + 1].latest < start - secondsPerTick) {
      anchor++;
    }
    while (endCluster < clusters.length &&
        clusters[endCluster].earliest <= start + plan.window) {
      endCluster++;
    }
    final cue = anchor < 0 ? null : cues[anchor].cue;
    final previous = regions.lastOrNull;
    if (previous != null &&
        (previous.endCluster == clusters.length ||
            (cue?.clusterOffset ?? 0) <=
                clusters[previous.endCluster].offset)) {
      // A shared timeline lets overlapping windows reuse the same decode runs.
      regions[regions.length - 1] = (
        first: previous.first,
        end: window + 1,
        cue: previous.cue,
        endCluster: endCluster,
      );
    } else {
      regions.add((
        first: window,
        end: window + 1,
        cue: cue,
        endCluster: endCluster,
      ));
    }
  }
  return regions;
}

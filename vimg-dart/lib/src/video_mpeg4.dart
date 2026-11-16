part of 'video.dart';

typedef _H263TimedReference = ({
  FramePacket packet,
  int temporal,
  int anchor,
  int position,
});

extension _Mpeg4Timeline on Video {
  _IndexedVideo _indexShortVideo(String codec, {_IsoSection? section}) {
    final headers = H263Headers(spark: codec == 'flv1');
    final decodeOrder = <FramePacket>[], anchors = <int>[];
    final positions = <FramePacket, int>{};
    final configurations = <int, _RunConfiguration>{};
    final sections = <int, int>{};
    final displayBySample = <FramePacket, List<FramePacket>>{};
    final bidirectional = <int>{};
    final layerNumbers = <int>[];
    final older = <int, _H263TimedReference>{};
    final previous = <int, _H263TimedReference>{};
    var anchor = -1;
    var hasEnhancements = false;
    var topLayer = 1;
    void record(FramePacket packet, int requiredAnchor, int layer) {
      positions[packet] = decodeOrder.length;
      decodeOrder.add(packet);
      anchors.add(requiredAnchor);
      layerNumbers.add(layer);
    }

    void inheritSampleProperties(FramePacket frame, FramePacket sample) {
      if (section != null) _isoSectionByPacket[frame] = section;
      if (_isoAspects[sample] case final aspect?) _isoAspects[frame] = aspect;
    }

    void remember(H263Header header, FramePacket frame, int requiredAnchor) {
      if (previous[header.layer] case final last?) older[header.layer] = last;
      previous[header.layer] = (
        packet: frame,
        temporal: header.temporalReference,
        anchor: requiredAnchor,
        position: decodeOrder.length - 1,
      );
    }

    var display =
        _containerPackets(
              false,
              section: section,
              onSample: (packet, _) {
                final header = headers.read(_readPrefix(packet, 1024));
                final position = decodeOrder.length;
                if (header.bidirectional) {
                  var frame = packet;
                  final before = older[header.referenceLayer];
                  final after = previous[header.referenceLayer];
                  var start = -1;
                  if (before != null && after != null) {
                    final timing = h263BTiming(
                      before.temporal,
                      after.temporal,
                      header,
                    );
                    frame = _h263StandalonePacket(
                      before.packet,
                      after.packet,
                      packet,
                      header,
                      timing.offset,
                      timing.distance,
                    );
                    if (frame != packet) {
                      inheritSampleProperties(frame, packet);
                      displayBySample[packet] = [frame];
                    }
                    start = before.anchor < after.anchor
                        ? before.anchor
                        : after.anchor;
                  }
                  bidirectional.add(position);
                  record(frame, start, header.layer);
                  return;
                }
                if (header.enhancement) {
                  hasEnhancements = true;
                  final lower = previous[header.referenceLayer];
                  final last = previous[header.layer];
                  var start = -1;
                  var frame = packet;
                  if (lower != null &&
                      lower.temporal == header.temporalReference &&
                      (header.enhancementIntra || last != null)) {
                    final forward = header.enhancementIntra
                        ? lower.anchor
                        : last!.anchor;
                    start = lower.anchor < forward ? lower.anchor : forward;
                    if (start >= 0 && header.layer >= topLayer) {
                      topLayer = header.layer;
                      _h263DisplayFormat = header.format;
                    }
                    frame = _h263Retime(
                      packet,
                      lower.packet.seconds,
                      lower.packet.timestamp,
                    );
                    if (frame != packet) {
                      inheritSampleProperties(frame, packet);
                      displayBySample[packet] = [frame];
                    }
                    final key = configurations[lower.position];
                    if (header.enhancementIntra && key != null) {
                      configurations[position] = key;
                    }
                  }
                  record(frame, start, header.layer);
                  remember(header, frame, start);
                  return;
                }
                if (header.intra) {
                  anchor = position;
                  configurations[anchor] = _RunConfiguration(
                    shortVideo: header.format,
                    h263Layers: headers.snapshotLayers(),
                  );
                  sections[anchor] = 0;
                }
                final last = previous[1];
                if (header.pb != null && last != null) {
                  final distance = h263PbDistance(last.temporal, header);
                  final frames = _h263PairedPackets(
                    last.packet,
                    packet,
                    header,
                    distance,
                  );
                  bidirectional.add(position);
                  for (final frame in frames) {
                    inheritSampleProperties(frame, packet);
                    record(frame, anchor, 1);
                  }
                  displayBySample[packet] = frames;
                } else {
                  record(packet, anchor, 1);
                }
                if (!header.disposable) {
                  remember(header, packet, anchor);
                }
              },
            )
            .expand((packet) => displayBySample[packet] ?? [packet])
            .where((packet) => anchors[positions[packet]!] >= 0)
            .toList()
          ..sort((a, b) {
            final byTime = a.seconds.compareTo(b.seconds);
            return byTime == 0
                ? positions[a]!.compareTo(positions[b]!)
                : byTime;
          });
    if (hasEnhancements) {
      final best = <FramePacket>[];
      for (final frame in display) {
        if (best.isEmpty || best.last.seconds != frame.seconds) {
          best.add(frame);
        } else if (layerNumbers[positions[frame]!] >
            layerNumbers[positions[best.last]!]) {
          best[best.length - 1] = frame;
        }
      }
      display = best;
      if (_shortElementary == null) _displayRateVaries = true;
    }
    if (bidirectional.isNotEmpty && _shortElementary == null) {
      for (var i = 0; i + 1 < display.length; i++) {
        final next = display[i + 1];
        final previous = display[i];
        if (!bidirectional.contains(positions[next]) &&
            !bidirectional.contains(positions[previous]))
          continue;
        final shortened = _h263BeforeBidirectional(previous, next);
        if (shortened == previous) continue;
        final position = positions.remove(previous)!;
        positions[shortened] = position;
        decodeOrder[position] = display[i] = shortened;
        inheritSampleProperties(shortened, previous);
      }
    }
    return (
      timeline: (
        presentation: display,
        decodeOrder: decodeOrder,
        index: positions,
        gopStart: anchors,
      ),
      sections: sections,
      configurations: configurations,
    );
  }

  FramePacket _h263Retime(
    FramePacket packet,
    double seconds,
    FrameTimestamp? timestamp,
  ) {
    if (seconds == packet.seconds && timestamp == packet.timestamp)
      return packet;
    return (
      offset: packet.offset,
      size: packet.size,
      seconds: seconds,
      timestamp: timestamp,
      subframe: (
        offset: 0,
        length: packet.size,
        displayIndex: null,
        sampleTimestamp: packet.timestamp,
      ),
    );
  }

  FramePacket _h263BeforeBidirectional(FramePacket previous, FramePacket next) {
    final before = previous.timestamp, after = next.timestamp;
    final duration = before?.duration;
    if (before == null || after == null || duration == null) return previous;
    final divisor = before.denominator.gcd(after.denominator);
    final startScale = after.denominator ~/ divisor * before.numerator;
    final endScale = before.denominator ~/ divisor * after.numerator;
    final start = before.pts * startScale;
    final interval = after.pts * endScale - start;
    if (interval <= 0 || interval >= duration * startScale) return previous;
    return (
      offset: previous.offset,
      size: previous.size,
      seconds: previous.seconds,
      subframe: previous.subframe,
      timestamp: frameTimestamp(
        start,
        1,
        before.denominator ~/ divisor * after.denominator,
        duration: interval,
      ),
    );
  }

  List<FramePacket> _h263PairedPackets(
    FramePacket previous,
    FramePacket packet,
    H263Header header,
    int distance,
  ) {
    final stamp = _shortElementary?.bidirectionalTimestamp(packet);
    final time = stamp == null
        ? _h263Between(previous, packet, header, header.pb!.offset, distance)
        : (
            seconds: stamp.pts * stamp.numerator / stamp.denominator,
            timestamp: stamp,
          );
    FramePacket subframe(
      int index,
      double seconds,
      FrameTimestamp? timestamp,
    ) => (
      offset: packet.offset,
      size: packet.size,
      seconds: seconds,
      timestamp: timestamp,
      subframe: (
        offset: 0,
        length: packet.size,
        displayIndex: index,
        sampleTimestamp: packet.timestamp,
      ),
    );
    return [
      subframe(0, time.seconds, time.timestamp),
      subframe(1, packet.seconds, packet.timestamp),
    ];
  }

  FramePacket _h263StandalonePacket(
    FramePacket before,
    FramePacket after,
    FramePacket packet,
    H263Header header,
    int offset,
    int distance,
  ) {
    if (_shortElementary != null) return packet;
    _displayRateVaries = true;
    if (packet.seconds > before.seconds && packet.seconds < after.seconds) {
      return packet;
    }
    // Some muxers timestamp chunks in coding order. Recover display
    // placement from the interval between the two reference pictures.
    final time = _h263Between(before, after, header, offset, distance);
    return _h263Retime(packet, time.seconds, time.timestamp);
  }

  ({double seconds, FrameTimestamp? timestamp}) _h263Between(
    FramePacket previous,
    FramePacket following,
    H263Header header,
    int offset,
    int distance,
  ) {
    final before = previous.timestamp, after = following.timestamp;
    final gap = following.seconds - previous.seconds;
    final seconds = gap > 0
        ? previous.seconds + gap * offset / distance
        : following.seconds -
              (distance - offset) *
                  header.format.tickNumerator /
                  header.format.tickDenominator;
    FrameTimestamp? stamp;
    if (before != null &&
        after != null &&
        before.numerator == after.numerator &&
        before.denominator == after.denominator &&
        after.pts > before.pts) {
      final delta = after.pts - before.pts;
      final divisor = (delta * offset).gcd(distance);
      final scale = distance ~/ divisor;
      final time = before.pts * scale + delta * offset ~/ divisor;
      stamp = frameTimestamp(
        time,
        after.numerator,
        after.denominator * scale,
        duration: after.pts * scale - time,
      );
    }
    if (_shortElementary == null) {
      _displayRateVaries = true;
      if (stamp != null) {
        _refinePresentationClock(stamp, _containerCaptureClock, 'H.263');
      }
    }
    return (seconds: seconds, timestamp: stamp);
  }

  _IndexedVideo _indexMpeg4({_IsoSection? section}) {
    final matroska = _matroska;
    var headers = Mpeg4Headers();
    void configure(Uint8List? bytes) {
      headers = Mpeg4Headers();
      if (bytes != null) headers.read(bytes).toList();
    }

    if (matroska != null) {
      configure(matroskaVideoConfiguration(matroska, 'mpeg4'));
    } else if (_avi case final avi?) {
      configure(avi.videoPrivateData());
    }
    final decodeOrder = <FramePacket>[], gopStart = <int>[];
    final index = <FramePacket, int>{};
    final configurations = <int, _RunConfiguration>{};
    final sections = <int, int>{};
    final displayedBySample = <FramePacket, List<FramePacket>>{};
    var first = -1, forward = -1, sectionStart = 0, packedExtras = 0;
    double? aviOrigin, aviStart;
    final aviClock = _avi != null;
    int record(
      FramePacket frame,
      Mpeg4PictureType type,
      bool coded,
      Uint8List? configuration,
      Mpeg4Clock clock,
    ) {
      final position = decodeOrder.length;
      if (coded && type == Mpeg4PictureType.intra) {
        // An open GOP can still have a leading B picture after its I-VOP.
        forward = first;
        first = position;
        configurations[first] = _RunConfiguration(
          bytes: configuration,
          mpeg4Clock: clock,
        );
        sections[first] = sectionStart;
      } else if (coded &&
          (type == Mpeg4PictureType.predictive ||
              type == Mpeg4PictureType.sprite)) {
        forward = first;
      }
      index[frame] = position;
      decodeOrder.add(frame);
      final anchor = type == Mpeg4PictureType.bidirectional ? forward : first;
      gopStart.add(anchor);
      return anchor;
    }

    final presented = _containerPackets(
      false,
      section: section,
      onDescription: (entry) {
        configure(
          _iso!.mpegVideoConfiguration(description: entry, visual: true),
        );
        first = forward = -1;
        sectionStart = decodeOrder.length;
      },
      onSample: (packet, _) {
        if (_systems case final systems?) {
          final picture = systems.visualPicture(packet);
          final anchor = record(
            packet,
            picture.type,
            picture.coded,
            picture.configuration,
            picture.clock,
          );
          if (anchor >= 0) displayedBySample[packet] = [packet];
          return;
        }
        final units = headers.read(_read(packet)).toList();
        if (units.isEmpty) {
          // Some AVI streams put a VOL or user data in its own chunk.
          return;
        }
        final codedCount = units.where((unit) => unit.header.coded).length;
        final packed = aviClock && codedCount > 1;
        if (packed) packedExtras += codedCount - 1;
        final dummy = aviClock && packedExtras > 0 && codedCount == 0;
        if (dummy) {
          // A packed AVI uses a non-coded VOP to reserve a display slot
          // for a picture that was already stored in an earlier chunk.
          packedExtras--;
        }
        final firstVop = units.first.header;
        final displays = <FramePacket>[];
        for (final unit in units) {
          final vop = unit.header, volume = vop.volume;
          final bitstreamTime = vop.pts / volume.resolution;
          final double seconds;
          if (aviClock) {
            aviOrigin ??= bitstreamTime;
            aviStart ??= packet.seconds;
            seconds = aviStart! + (bitstreamTime - aviOrigin!);
          } else {
            seconds =
                packet.seconds + (vop.pts - firstVop.pts) / volume.resolution;
          }
          final split = units.length > 1 || aviClock;
          final frame = split
              ? (
                  seconds: seconds,
                  offset: packet.offset,
                  size: packet.size,
                  timestamp: frameTimestamp(
                    vop.pts,
                    1,
                    volume.resolution,
                    duration: volume.fixedIncrement,
                  ),
                  subframe: (
                    offset: unit.offset,
                    length: unit.length,
                    displayIndex: displays.length,
                    sampleTimestamp: packet.timestamp,
                  ),
                )
              : packet;
          final anchor = record(
            frame,
            vop.type,
            vop.coded,
            unit.configuration,
            unit.clock,
          );
          if (anchor >= 0 && !dummy) {
            displays.add(frame);
            if (section != null) _isoSectionByPacket[frame] = section;
            if (_isoAspects[packet] case final aspect?)
              _isoAspects[frame] = aspect;
          }
        }
        if (displays.isNotEmpty) displayedBySample[packet] = displays;
      },
    );
    final presentation =
        [for (final packet in presented) ...?displayedBySample.remove(packet)]
          ..sort((a, b) {
            final byTime = a.seconds.compareTo(b.seconds);
            return byTime == 0 ? index[a]!.compareTo(index[b]!) : byTime;
          });
    return (
      timeline: (
        decodeOrder: decodeOrder,
        presentation: presentation,
        index: index,
        gopStart: gopStart,
      ),
      configurations: configurations,
      sections: sections,
    );
  }
}

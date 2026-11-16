part of 'video.dart';

extension _Mpeg4Timeline on Video {
  _IndexedVideo _indexShortVideo(String codec, {_IsoSection? section}) {
    final headers = H263Headers(spark: codec == 'flv1');
    final decodeOrder = <FramePacket>[], anchors = <int>[];
    final positions = <FramePacket, int>{};
    final configurations = <int, _RunConfiguration>{};
    final sections = <int, int>{};
    final paired = <FramePacket, List<FramePacket>>{};
    var anchor = -1;
    FramePacket? previousPacket;
    int? previousTime;
    void record(FramePacket packet) {
      positions[packet] = decodeOrder.length;
      decodeOrder.add(packet);
      anchors.add(anchor);
    }

    final display =
        _containerPackets(
              false,
              section: section,
              onSample: (packet, _) {
                final header = headers.read(_readPrefix(packet, 1024));
                final position = decodeOrder.length;
                if (header.intra) {
                  anchor = position;
                  configurations[anchor] = _RunConfiguration(
                    shortVideo: header.format,
                  );
                  sections[anchor] = 0;
                }
                if (header.pb != null && previousPacket != null) {
                  final distance = h263PbDistance(previousTime!, header);
                  final frames = _h263PairedPackets(
                    previousPacket!,
                    packet,
                    header,
                    distance,
                  );
                  for (final frame in frames) {
                    if (section != null) _isoSectionByPacket[frame] = section;
                    if (_isoAspects[packet] case final aspect?)
                      _isoAspects[frame] = aspect;
                    record(frame);
                  }
                  paired[packet] = frames;
                } else {
                  record(packet);
                }
                if (!header.disposable) {
                  previousPacket = packet;
                  previousTime = header.temporalReference;
                }
              },
            )
            .expand((packet) => paired[packet] ?? [packet])
            .where((packet) => anchors[positions[packet]!] >= 0)
            .toList()
          ..sort((a, b) {
            final byTime = a.seconds.compareTo(b.seconds);
            return byTime == 0
                ? positions[a]!.compareTo(positions[b]!)
                : byTime;
          });
    if (paired.isNotEmpty && _shortElementary == null) {
      for (var i = 0; i + 1 < display.length; i++) {
        final next = display[i + 1];
        if (next.subframe?.displayIndex != 0) continue;
        final previous = display[i];
        final shortened = _h263BeforeBidirectional(previous, next);
        if (shortened == previous) continue;
        final position = positions.remove(previous)!;
        positions[shortened] = position;
        decodeOrder[position] = display[i] = shortened;
        if (section != null) _isoSectionByPacket[shortened] = section;
        if (_isoAspects[previous] case final aspect?)
          _isoAspects[shortened] = aspect;
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
    final offset = header.pb!.offset;
    final before = previous.timestamp, after = packet.timestamp;
    final gap = packet.seconds - previous.seconds;
    var bTime = gap > 0
        ? previous.seconds + gap * offset / distance
        : packet.seconds -
              (distance - offset) *
                  header.format.tickNumerator /
                  header.format.tickDenominator;
    var stamp = _shortElementary?.bidirectionalTimestamp(packet);
    if (stamp != null) {
      bTime = stamp.pts * stamp.numerator / stamp.denominator;
    } else if (before != null &&
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
    return [subframe(0, bTime, stamp), subframe(1, packet.seconds, after)];
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

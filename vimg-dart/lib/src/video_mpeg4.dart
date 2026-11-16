part of 'video.dart';

extension _Mpeg4Timeline on Video {
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

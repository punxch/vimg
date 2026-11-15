part of 'video.dart';

typedef _Vp9Sample = ({
  FramePacket packet,
  List<Vp9CodedFrame> frames,
  int displayCount,
  int section,
});

extension _Vp9Timeline on Video {
  _IndexedVideo _indexVp9({_IsoSection? section}) {
    final alpha = _matroska == null ? null : _MatroskaAlphaIndex(file, 'vp9');
    final encoded = _matroska?.hasEncodedFrames == true;
    final samples = <_Vp9Sample>[];
    var description = 0;
    final presented = _containerPackets(
      false,
      section: section,
      onDescription: (_) => description++,
      onAlpha: alpha?.add,
      onSample: (packet, _) {
        final bytes = encoded ? _read(packet) : null;
        final frames = vp9CodedFrames(
          bytes?.length ?? packet.size,
          bytes == null
              ? (start, length) => file.read(packet.offset + start, length)
              : (start, length) =>
                    Uint8List.sublistView(bytes, start, start + length),
        );
        samples.add((
          packet: packet,
          frames: frames,
          displayCount: frames.where((frame) => frame.tag.shown).length,
          section: description,
        ));
      },
    ).toSet();

    final decodeOrder = <FramePacket>[];
    final presentation = <FramePacket>[];
    final index = <FramePacket, int>{};
    final gopStart = <int>[];
    final configurations = <int, _RunConfiguration>{};
    final sections = <int, int>{};
    final needsDurations = samples.any(
      (sample) =>
          sample.displayCount > 1 && sample.packet.timestamp?.duration == null,
    );
    final durations = needsDurations
        ? _vp9InferredDurations(samples, presented)
        : null;
    var anchor = -1, previousDescription = -1;
    for (final sample in samples) {
      if (sample.section != previousDescription) {
        anchor = -1;
        previousDescription = sample.section;
      }
      final parent = sample.packet;
      final visible = presented.contains(parent);
      final clocks = sample.displayCount > 1
          ? _Vp9SampleTiming(
              parent,
              sample.displayCount,
              durations?[parent.seconds],
            )
          : null;
      if (visible && clocks != null) {
        _vp9MultipleDisplayPictures = true;
        if (clocks.timestamp case final timestamp?) {
          _refineVp9Clock(timestamp, _containerCaptureClock);
        }
      }
      var display = 0;
      FramePacket? localKey;
      for (final frame in sample.frames) {
        final tag = frame.tag, extent = frame.extent;
        final ordinal = tag.shown ? display++ : null;
        final packet = sample.frames.length == 1
            ? parent
            : (
                seconds: ordinal == null || clocks == null
                    ? parent.seconds
                    : parent.seconds + clocks.interval * ordinal,
                offset: parent.offset,
                size: parent.size,
                timestamp: ordinal == null || clocks == null
                    ? parent.timestamp
                    : clocks.at(ordinal),
                subframe: (
                  offset: extent.offset,
                  length: extent.length,
                  displayIndex: ordinal,
                  sampleTimestamp: parent.timestamp,
                ),
              );
        final position = decodeOrder.length;
        if (tag.key) {
          anchor = position;
          configurations[position] = (bytes: null, nal: null);
          sections[position] = sample.section;
        }
        if (tag.existing == null) localKey = tag.key ? packet : null;
        index[packet] = position;
        decodeOrder.add(packet);
        gopStart.add(anchor);
        if (tag.shown && visible && anchor >= 0) {
          presentation.add(packet);
          if (section != null) _isoSectionByPacket[packet] = section;
          if (localKey != null) _vp9PreviewPictures[packet] = localKey;
        }
      }
    }
    presentation.sort((a, b) {
      final byTime = a.seconds.compareTo(b.seconds);
      return byTime == 0 ? index[a]!.compareTo(index[b]!) : byTime;
    });
    if (alpha != null) _matroskaAlpha = alpha;
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

  Map<double, double> _vp9InferredDurations(
    List<_Vp9Sample> samples,
    Set<FramePacket> presented,
  ) {
    final times = {
      for (final sample in samples)
        if (presented.contains(sample.packet) && sample.displayCount > 0)
          sample.packet.seconds,
    }.toList()..sort();
    final intervals = <double, double>{};
    for (var i = 0; i + 1 < times.length; i++) {
      intervals[times[i]] = times[i + 1] - times[i];
    }
    if (times.isNotEmpty) {
      final remaining = (metadata.duration ?? 0) - times.last;
      if (remaining > 0) {
        intervals[times.last] = remaining;
      } else if (times.length > 1) {
        intervals[times.last] = times.last - times[times.length - 2];
      }
    }
    return intervals;
  }

  void _refineVp9Clock(FrameTimestamp timestamp, CaptureRational native) {
    final sample =
        BigInt.from(timestamp.denominator) * BigInt.from(native.numerator);
    final container =
        BigInt.from(timestamp.numerator) * BigInt.from(native.denominator);
    final factor = sample ~/ sample.gcd(container);
    final current = BigInt.from(_vp9ClockDivisor);
    final finer = (current ~/ current.gcd(factor)) * factor;
    if ((finer * BigInt.from(native.denominator)).bitLength > 62) {
      throw const FormatException('VP9 presentation time base is out of range');
    }
    _vp9ClockDivisor = finer.toInt();
  }

  Iterable<FramePacket> _vp9Previews(List<FramePacket> displayed) {
    final keys = displayed.where(_vp9PreviewPictures.containsKey);
    return keys.isEmpty ? displayed : keys;
  }

  image.Image? _vp9Preview(FramePacket packet) {
    final key = _vp9PreviewPictures[packet];
    if (key == null) return null;
    final reader = _SamplePayloadReader(this);
    return Vp9Decoder()
        .decodeCodedFrame(reader.read(key))
        .picture
        .rgb(scaler: _previewScaler);
  }
}

final class _Vp9SampleTiming {
  _Vp9SampleTiming(FramePacket packet, int count, double? inferred) {
    final stamp = packet.timestamp;
    final duration = stamp?.duration;
    if (stamp == null) {
      interval = (inferred ?? 0) / count;
      timestamp = null;
      return;
    }
    final ticks =
        duration ??
        (inferred == null
            ? 0
            : checkedCaptureTick(
                inferred * stamp.denominator / stamp.numerator,
              ));
    if (ticks <= 0 || stamp.numerator <= 0 || stamp.denominator <= 0) {
      interval = (inferred ?? 0) / count;
      timestamp = stamp;
      return;
    }
    final common = ticks.gcd(count);
    final scale = count ~/ common;
    final base = BigInt.from(stamp.denominator) * BigInt.from(scale);
    final start = BigInt.from(stamp.pts) * BigInt.from(scale);
    final perPicture = ticks ~/ common;
    final end = start + BigInt.from(perPicture) * BigInt.from(count - 1);
    if (base.bitLength > 62 || start.bitLength > 62 || end.bitLength > 62) {
      throw const FormatException('VP9 subframe timestamp is out of range');
    }
    interval = perPicture * (stamp.numerator / base.toInt());
    timestamp = frameTimestamp(
      start.toInt(),
      stamp.numerator,
      base.toInt(),
      duration: perPicture,
    );
  }

  late final double interval;
  late final FrameTimestamp? timestamp;

  FrameTimestamp? at(int ordinal) {
    final stamp = timestamp;
    if (stamp == null || stamp.duration == null || ordinal == 0) return stamp;
    return (
      pts: stamp.pts + ordinal * stamp.duration!,
      numerator: stamp.numerator,
      denominator: stamp.denominator,
      duration: stamp.duration,
    );
  }
}

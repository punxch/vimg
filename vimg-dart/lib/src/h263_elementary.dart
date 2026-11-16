import 'dart:math' as math;

import 'binary_file.dart';
import 'frame_packet.dart';
import 'metadata.dart';
import 'mpeg4/short_header.dart';

const _clock = 1200000;

final class H263Elementary {
  H263Elementary._(this.file);

  static H263Elementary? detect(BinaryFile file) {
    if (file.length < 8 || file.unsigned(0, 3) & 0xfffffc != 0x80) return null;
    try {
      H263Headers().read(file.read(0, math.min(file.length, 1024)));
    } on FormatException {
      return null;
    }
    return H263Elementary._(file);
  }

  final BinaryFile file;
  late final _index = _scan();

  VideoMetadata metadata() => _index.metadata;

  FrameTimestamp? bidirectionalTimestamp(FramePacket packet) =>
      _index.pairedTimes[packet.offset];

  Iterable<FramePacket> packets(bool preview, {FrameVisitor? onSample}) sync* {
    for (final (packet, key) in _index.frames) {
      onSample?.call(packet, key);
      if (!preview || key) yield packet;
    }
  }

  ({
    VideoMetadata metadata,
    List<(FramePacket, bool)> frames,
    Map<int, FrameTimestamp> pairedTimes,
  })
  _scan() {
    final offsets = <int>[];
    const chunkSize = 256 * 1024;
    var zeroes = 0;
    for (var start = 0; start < file.length; start += chunkSize) {
      final bytes = file.read(start, math.min(file.length - start, chunkSize));
      for (final (i, byte) in bytes.indexed) {
        if (byte == 0) {
          zeroes++;
        } else {
          if (zeroes >= 2 && byte & 0xfc == 0x80) offsets.add(start + i - 2);
          zeroes = 0;
        }
      }
    }
    offsets.add(file.length);
    final headers = H263Headers();
    final pictures = <(int, int, bool, int)>[];
    final display = <(int, int, bool)>[];
    H263Format? format;
    H263Header? previous;
    int? older;
    // Accumulate at the common clock before rounding to output timestamps.
    const commonClock = 3 * _clock;
    var elapsed = 0, olderElapsed = 0;
    for (var i = 1; i < offsets.length; i++) {
      final offset = offsets[i - 1];
      final size = offsets[i] - offset;
      final header = headers.read(file.read(offset, math.min(size, 1024)));
      if (format == null && !header.intra) continue;
      format ??= header.format;
      if (header.temporalLayer != null) {
        var time = (elapsed + 1) ~/ 3;
        if (older != null && previous != null) {
          final timing = h263BTiming(older, previous.temporalReference, header);
          final between = (elapsed - olderElapsed) * timing.offset;
          time = (olderElapsed + between ~/ timing.distance + 1) ~/ 3;
          display.add((time, offset, false));
        }
        pictures.add((offset, size, false, time));
        continue;
      }
      if (previous != null) {
        final prior = previous.format;
        final unit =
            prior.tickNumerator * (commonClock ~/ prior.tickDenominator);
        older = previous.temporalReference;
        olderElapsed = elapsed;
        if (header.pb case final pb?) {
          final delta = h263PbDistance(previous.temporalReference, header);
          final time = (elapsed + unit * pb.offset + 1) ~/ 3;
          display.add((time, offset, true));
          elapsed += delta * unit;
        } else {
          elapsed +=
              h263TemporalDistance(previous.temporalReference, header) * unit;
        }
      }
      previous = header;
      final time = (elapsed + 1) ~/ 3;
      display.add((time, offset, false));
      pictures.add((offset, size, header.intra, time));
    }
    if (format == null)
      throw const FormatException('H.263 stream has no intra picture');
    display.sort((a, b) {
      final time = a.$1.compareTo(b.$1);
      return time == 0 ? a.$2.compareTo(b.$2) : time;
    });
    final cadence = <int, int>{};
    for (var i = 1; i < display.length; i++) {
      final delta = display[i].$1 - display[i - 1].$1;
      if (delta > 0)
        cadence.update(delta, (count) => count + 1, ifAbsent: () => 1);
    }
    final period =
        cadence.entries
            .fold<MapEntry<int, int>?>(
              null,
              (best, entry) =>
                  best == null || entry.value > best.value ? entry : best,
            )
            ?.key ??
        (_clock * format.tickNumerator / format.tickDenominator).round();
    final end = display.last.$1 + period;
    final timestamps = <int, FrameTimestamp>{};
    final pairedTimes = <int, FrameTimestamp>{};
    for (final (i, (pts, offset, paired)) in display.indexed) {
      final next = i + 1 < display.length ? display[i + 1].$1 : end;
      (paired ? pairedTimes : timestamps)[offset] = frameTimestamp(
        pts,
        1,
        _clock,
        duration: next - pts,
      );
    }
    final fixed = cadence.keys.every((delta) => (delta - period).abs() <= 1);
    return (
      pairedTimes: pairedTimes,
      metadata: VideoMetadata(end / _clock, [
        VideoStream(
          codec: 'h263',
          width: format.width,
          height: format.height,
          timeBase: '1/$_clock',
          nominalFrameRate: fixed ? _clock / period : null,
        ),
      ]),
      frames: [
        for (final (offset, size, key, pts) in pictures)
          (
            (
              offset: offset,
              size: size,
              seconds: pts / _clock,
              timestamp: timestamps[offset] ?? frameTimestamp(pts, 1, _clock),
              subframe: null,
            ),
            key,
          ),
      ],
    );
  }
}

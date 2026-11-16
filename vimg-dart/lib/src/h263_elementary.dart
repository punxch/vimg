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
    H263Format? largestLayer;
    var topLayer = 1;
    H263Header? previous;
    final latest = <int, (int, int)>{};
    final older = <int, (int, int)>{};
    final third = <int, (int, int)>{};
    // Accumulate at the common clock before rounding to output timestamps.
    const commonClock = 3 * _clock;
    var elapsed = 0;
    void remember(H263Header header, int time) {
      if (older[header.layer] case final second?) third[header.layer] = second;
      if (latest[header.layer] case final last?) older[header.layer] = last;
      latest[header.layer] = (header.temporalReference, time);
    }

    for (var i = 1; i < offsets.length; i++) {
      final offset = offsets[i - 1];
      final size = offsets[i] - offset;
      final header = headers.readPrefix(
        file.read(offset, math.min(size, 1024)),
        () => file.read(offset, size),
      );
      if (header.redundant) continue;
      if (format == null && !header.intra) continue;
      format ??= header.format;
      if (header.bidirectional) {
        var time = (elapsed + 1) ~/ 3;
        final layer = header.referenceLayer;
        var before = older[layer];
        var after = latest[layer];
        if (header.erps != null &&
            before != null &&
            after != null &&
            h263BInterval(before.$1, after.$1, header) == null) {
          // Annex U can transmit two future reference pictures before this B.
          after = before;
          before = third[layer];
        }
        if (before != null && after != null) {
          final timing = h263BTiming(before.$1, after.$1, header);
          final between = (after.$2 - before.$2) * timing.offset;
          time = (before.$2 + between ~/ timing.distance + 1) ~/ 3;
          display.add((time, offset, false));
        }
        pictures.add((offset, size, false, time));
        continue;
      }
      if (header.enhancement) {
        final lower = latest[header.referenceLayer];
        var time = (elapsed + 1) ~/ 3;
        if (lower != null &&
            lower.$1 == header.temporalReference &&
            (header.enhancementIntra || latest.containsKey(header.layer))) {
          remember(header, lower.$2);
          time = (lower.$2 + 1) ~/ 3;
          display.add((time, offset, false));
          if (header.layer >= topLayer) {
            topLayer = header.layer;
            largestLayer = header.format;
          }
        }
        pictures.add((offset, size, false, time));
        continue;
      }
      if (previous != null) {
        final prior = previous.format;
        final unit =
            prior.tickNumerator * (commonClock ~/ prior.tickDenominator);
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
      remember(header, elapsed);
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
    var later = end, time = end;
    for (var i = display.length - 1; i >= 0; i--) {
      final (pts, offset, paired) = display[i];
      if (pts != time || topLayer == 1) {
        later = time;
        time = pts;
      }
      (paired ? pairedTimes : timestamps)[offset] = frameTimestamp(
        pts,
        1,
        _clock,
        duration: later - pts,
      );
    }
    final fixed = cadence.keys.every((delta) => (delta - period).abs() <= 1);
    return (
      pairedTimes: pairedTimes,
      metadata: VideoMetadata(end / _clock, [
        VideoStream(
          codec: 'h263',
          width: (largestLayer ?? format).width,
          height: (largestLayer ?? format).height,
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

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

  Iterable<FramePacket> packets(bool preview, {FrameVisitor? onSample}) sync* {
    for (final (packet, key) in _index.frames) {
      onSample?.call(packet, key);
      if (!preview || key) yield packet;
    }
  }

  ({VideoMetadata metadata, List<(FramePacket, bool)> frames}) _scan() {
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
    final pictures = <(int, int, bool)>[];
    final ticks = <int>[];
    H263Format? format;
    int? previous;
    // Accumulate at the common clock before rounding to output timestamps.
    const commonClock = 3 * _clock;
    var elapsed = 0;
    for (var i = 1; i < offsets.length; i++) {
      final offset = offsets[i - 1];
      final size = offsets[i] - offset;
      final header = headers.read(file.read(offset, math.min(size, 1024)));
      if (format == null && !header.intra) continue;
      final current = header.format;
      format ??= current;
      final temporal = header.temporalReference;
      if (previous != null) {
        final wrap = current.customClock ? 1024 : 256;
        final delta = (temporal - previous) % wrap;
        elapsed +=
            delta *
            current.tickNumerator *
            (commonClock ~/ current.tickDenominator);
      }
      previous = temporal;
      ticks.add((elapsed + 1) ~/ 3);
      pictures.add((offset, size, header.intra));
    }
    if (format == null)
      throw const FormatException('H.263 stream has no intra picture');
    final cadence = <int, int>{};
    for (var i = 1; i < ticks.length; i++) {
      final delta = ticks[i] - ticks[i - 1];
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
    ticks.add(ticks.last + period);
    final fixed = cadence.keys.every((delta) => (delta - period).abs() <= 1);
    return (
      metadata: VideoMetadata(ticks.last / _clock, [
        VideoStream(
          codec: 'h263',
          width: format.width,
          height: format.height,
          timeBase: '1/$_clock',
          nominalFrameRate: fixed ? _clock / period : null,
        ),
      ]),
      frames: [
        for (final (i, (offset, size, key)) in pictures.indexed)
          (
            (
              offset: offset,
              size: size,
              seconds: ticks[i] / _clock,
              timestamp: frameTimestamp(
                ticks[i],
                1,
                _clock,
                duration: ticks[i + 1] - ticks[i],
              ),
              subframe: null,
            ),
            key,
          ),
      ],
    );
  }
}

import 'dart:math' as math;
import 'dart:typed_data';

import 'binary_file.dart';
import 'frame_packet.dart';
import 'h264/access_unit.dart';
import 'metadata.dart';
import 'mpeg4/short_header.dart';

final class Flv {
  Flv(this.file);

  final BinaryFile file;
  late final _index = _scan();
  VideoMetadata metadata() => _index.metadata;

  Uint8List avcConfiguration(FramePacket packet) =>
      _index.configurations[packet.offset] ??
      (throw const FormatException('FLV AVC picture has no configuration'));

  Iterable<FramePacket> packets(bool preview, {FrameVisitor? onSample}) sync* {
    for (final frame in _index.frames) {
      onSample?.call(frame.packet, frame.key);
      if (!preview || frame.key) yield frame.packet;
    }
  }

  ({
    VideoMetadata metadata,
    List<({FramePacket packet, bool key})> frames,
    Map<int, Uint8List> configurations,
  })
  _scan() {
    final header = file.read(0, 9);
    if (header[3] != 1 || header[4] & ~5 != 0)
      throw const FormatException('Invalid FLV file header');
    var offset = ByteData.sublistView(header).getUint32(5);
    if (offset < 9 || offset > file.length - 4 || file.unsigned(offset, 4) != 0)
      throw const FormatException('Invalid FLV data offset');
    offset += 4;
    final pictures =
        <({int offset, int size, int pts, bool key, Uint8List? config})>[];
    final spark = H263Headers(spark: true);
    String? codec;
    int? width, height, firstVideoDts, firstAudio, lastAudio, audioPeriod;
    Uint8List? avc;
    while (offset <= file.length - 11) {
      final tag = file.read(offset, 11);
      final type = tag[0] & 31;
      final size = _u24(tag, 1);
      final dts = tag[7] << 24 | _u24(tag, 4);
      final data = offset + 11, end = data + size;
      if (end > file.length) break;
      offset = end + 4;
      if (type == 8) {
        firstAudio ??= dts;
        if (lastAudio case final previous? when dts > previous)
          audioPeriod = dts - previous;
        lastAudio = dts;
      }
      if (type != 9 || size == 0) continue;
      if (tag[0] & 0x20 != 0) throw UnsupportedError('Filtered FLV video tags');
      final flags = file.unsigned(data, 1);
      final frameType = flags >> 4;
      if (frameType == 5) continue; // video info or command frame
      final name = switch (flags & 15) {
        2 => 'flv1',
        7 => 'h264',
        final id => throw UnsupportedError('FLV video codec $id'),
      };
      if (codec != null && codec != name)
        throw UnsupportedError('FLV video codec changes within a file');
      codec = name;
      if (name == 'flv1') {
        firstVideoDts ??= dts;
        if (width == null) {
          final format = spark
              .read(file.read(data + 1, math.min(size - 1, 1024)))
              .format;
          (width, height) = (format.width, format.height);
        }
        pictures.add((
          offset: data + 1,
          size: size - 1,
          pts: dts,
          key: frameType == 1,
          config: null,
        ));
      } else {
        if (size < 5) throw const FormatException('Truncated FLV AVC header');
        final avcHeader = file.read(data + 1, 4);
        final kind = avcHeader[0];
        if (kind == 0) {
          final record = file.read(data + 5, size - 5);
          if (avc != null && avc.length == record.length) {
            var different = false;
            for (var i = 0; i < record.length; i++) {
              if (record[i] != avc[i]) {
                different = true;
                break;
              }
            }
            if (!different) continue;
          }
          final sps = AvcConfiguration(record).sequences.values.firstOrNull;
          if (sps == null)
            throw const FormatException('Missing FLV AVC sequence header');
          width ??= sps.width;
          height ??= sps.height;
          avc = record;
        } else if (kind == 1) {
          if (avc == null || size == 5)
            throw const FormatException('Missing FLV AVC picture data');
          firstVideoDts ??= dts;
          final cts = _u24(avcHeader, 1);
          pictures.add((
            offset: data + 5,
            size: size - 5,
            pts: dts + (cts & 0x800000 == 0 ? cts : cts - 0x1000000),
            key: frameType == 1,
            config: avc,
          ));
        }
      }
    }
    if (pictures.isEmpty || width == null || height == null)
      throw const FormatException('No FLV video pictures');
    final sorted = [for (final picture in pictures) picture.pts]..sort();
    final intervals = <int, int>{};
    final durations = <int, int>{};
    for (var i = 1; i < sorted.length; i++) {
      final delta = sorted[i] - sorted[i - 1];
      if (delta <= 0) continue;
      intervals.update(delta, (value) => value + 1, ifAbsent: () => 1);
      durations[sorted[i - 1]] = delta;
    }
    final period =
        intervals.entries
            .fold<MapEntry<int, int>?>(
              null,
              (best, entry) =>
                  best == null || entry.value > best.value ? entry : best,
            )
            ?.key ??
        40;
    final start = math.min(firstAudio ?? sorted.first, sorted.first);
    final containerStart = math.min(start, firstVideoDts!);
    final end = math.max(
      sorted.last + period,
      (lastAudio ?? start) + (audioPeriod ?? 0),
    );
    final nominal = intervals.keys.every(
      (interval) => (interval - period).abs() <= 1,
    );
    return (
      metadata: VideoMetadata((end - containerStart) / 1000, [
        VideoStream(
          codec: codec!,
          width: width,
          height: height,
          timeBase: '1/1000',
          nominalFrameRate: nominal ? 1000 / period : null,
        ),
      ]),
      frames: [
        for (final picture in pictures)
          (
            packet: (
              offset: picture.offset,
              size: picture.size,
              seconds: (picture.pts - start) / 1000,
              timestamp: frameTimestamp(
                picture.pts,
                1,
                1000,
                duration: durations[picture.pts] ?? period,
              ),
              subframe: null,
            ),
            key: picture.key,
          ),
      ],
      configurations: {
        for (final picture in pictures)
          if (picture.config case final record?) picture.offset: record,
      },
    );
  }
}

int _u24(Uint8List bytes, int start) =>
    (bytes[start] << 16) | (bytes[start + 1] << 8) | bytes[start + 2];

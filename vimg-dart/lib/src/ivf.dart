import 'dart:typed_data';

import 'binary_file.dart';
import 'frame_packet.dart';
import 'metadata.dart';
import 'vp8/decoder.dart' show vp8FrameTag;
import 'vp9/bitstream.dart';

typedef _IvfFrame = ({
  int offset,
  int size,
  int pts,
  bool shown,
  bool keyframe,
});

final class Ivf {
  Ivf(this.file) {
    final bytes = file.read(0, 32);
    final header = ByteData.sublistView(bytes);
    if (header.getUint32(0) != 0x444b4946) {
      throw const FormatException('Missing IVF signature');
    }
    if (header.getUint16(4, Endian.little) != 0) {
      throw const FormatException('Unsupported IVF version');
    }
    _headerSize = header.getUint16(6, Endian.little);
    if (_headerSize < 32 || _headerSize > file.length) {
      throw const FormatException('Invalid IVF header size');
    }
    final fourcc = String.fromCharCodes(bytes, 8, 12);
    codec = switch (fourcc) {
      'AV01' => 'av1',
      'VP80' => 'vp8',
      'VP90' => 'vp9',
      _ => throw FormatException('Unsupported IVF codec $fourcc'),
    };
    _width = header.getUint16(12, Endian.little);
    _height = header.getUint16(14, Endian.little);
    final rate = header.getUint32(16, Endian.little);
    final scale = header.getUint32(20, Endian.little);
    if (_width == 0 || _height == 0 || rate == 0 || scale == 0) {
      throw const FormatException('Invalid IVF dimensions or time base');
    }
    final divisor = rate.gcd(scale);
    _num = scale ~/ divisor;
    _den = rate ~/ divisor;
  }

  final BinaryFile file;
  late final String codec;
  late final int _headerSize, _width, _height, _num, _den;
  late final _index = _readFrames();
  late final _timing = _readTiming();

  bool get outOfOrder => _index.outOfOrder;

  VideoMetadata metadata() {
    final timing = _timing;
    return VideoMetadata(
      timing == null
          ? null
          : ((timing.end - timing.start).toDouble() + timing.step) *
                _num /
                _den,
      [
        VideoStream(
          codec: codec,
          width: _width,
          height: _height,
          timeBase: '$_num/$_den',
          nominalFrameRate: _den / (_num * (timing?.step ?? 1).toDouble()),
        ),
      ],
    );
  }

  Iterable<FramePacket> packets(
    bool keyframes, {
    FrameVisitor? onSample,
  }) sync* {
    final timing = _timing;
    if (timing == null) return;
    final (:start, :durations, :step, end: _) = timing;
    for (final frame in _index.frames) {
      final packet = (
        seconds: (frame.pts - start) * _num.toDouble() / _den,
        offset: frame.offset,
        size: frame.size,
        timestamp: frameTimestamp(
          frame.pts,
          _num,
          _den,
          duration: durations[frame.pts] ?? step,
        ),
      );
      onSample?.call(packet, frame.keyframe);
      if (frame.shown && (!keyframes || frame.keyframe)) yield packet;
    }
  }

  ({List<_IvfFrame> frames, bool outOfOrder}) _readFrames() {
    final frames = <_IvfFrame>[];
    var outOfOrder = false;
    for (var at = _headerSize; at < file.length;) {
      if (file.length - at < 12) {
        throw const FormatException('Truncated IVF frame header');
      }
      final header = ByteData.sublistView(file.read(at, 12));
      final size = header.getUint32(0, Endian.little);
      final pts = header.getInt64(4, Endian.little);
      final offset = at + 12;
      if (size == 0 || size > file.length - offset) {
        throw const FormatException('Invalid IVF frame extent');
      }
      var shown = true, keyframe = false;
      if (codec == 'vp8') {
        final tag = vp8FrameTag(file.read(offset, size < 3 ? size : 3));
        shown = tag.shown;
        keyframe = tag.key;
        if (keyframe &&
            (size < 10 || file.unsigned(offset + 3, 3) != 0x9d012a)) {
          throw const FormatException('Invalid VP8 keyframe header');
        }
      } else if (codec == 'vp9') {
        final tag = vp9PacketTag(
          size,
          (start, length) => file.read(offset + start, length),
        );
        shown = tag.shown;
        keyframe = tag.key;
      }
      if (frames.isNotEmpty && pts < frames.last.pts) outOfOrder = true;
      frames.add((
        offset: offset,
        size: size,
        pts: pts,
        shown: shown,
        keyframe: keyframe,
      ));
      at = offset + size;
    }
    return (frames: frames, outOfOrder: outOfOrder);
  }

  ({int start, int end, int step, Map<int, int> durations})? _readTiming() {
    final timestamps =
        _index.frames
            .where((frame) => frame.shown)
            .map((frame) => frame.pts)
            .toSet()
            .toList()
          ..sort();
    if (timestamps.isEmpty) return null;
    final start = timestamps.first, end = timestamps.last;
    if (start < 0 && end > 0x7fffffffffffffff + start) {
      throw const FormatException('IVF timestamp range is too large');
    }
    final durations = <int, int>{}, counts = <int, int>{};
    var step = 1, frequency = 0;
    for (var i = 1; i < timestamps.length; i++) {
      final previous = timestamps[i - 1];
      final duration = timestamps[i] - previous;
      durations[previous] = duration;
      final count = counts.update(
        duration,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      if (count > frequency || count == frequency && duration < step) {
        step = duration;
        frequency = count;
      }
    }
    // IVF's header counts packets. Their spacing defines the playback length.
    return (start: start, end: end, step: step, durations: durations);
  }
}

import 'dart:math' as math;

import 'frame_packet.dart';

final class VideoOffset {
  const VideoOffset(this.value, {this.percent = false});

  factory VideoOffset.parse(String source) {
    final input = source.trim();
    if (!input.endsWith('%')) return VideoOffset(parseSeconds(input));
    final value = double.tryParse(input.substring(0, input.length - 1));
    if (value == null || !value.isFinite) {
      throw FormatException('Invalid percentage: $source');
    }
    return VideoOffset(value, percent: true);
  }

  final double value;
  final bool percent;

  double seconds(double duration) => percent ? duration * value / 100 : value;
}

double parseSeconds(String input) {
  final text = input.trim();
  const units = {
    'ns': 1e-9,
    'us': 1e-6,
    'µs': 1e-6,
    'ms': 0.001,
    's': 1.0,
    'sec': 1.0,
    'secs': 1.0,
    'second': 1.0,
    'seconds': 1.0,
    'm': 60.0,
    'min': 60.0,
    'mins': 60.0,
    'minute': 60.0,
    'minutes': 60.0,
    'h': 3600.0,
    'hr': 3600.0,
    'hours': 3600.0,
    'hour': 3600.0,
    'd': 86400.0,
    'days': 86400.0,
    'day': 86400.0,
  };
  final duration = RegExp(r'\s*(\d+(?:\.\d+)?)\s*([a-zµ]+)');
  var result = 0.0;
  var offset = 0;
  while (offset < text.length) {
    final match = duration.matchAsPrefix(text, offset);
    final unit = units[match?.group(2)];
    if (match == null || unit == null)
      throw FormatException('Invalid duration: $input');
    result += double.parse(match[1]!) * unit;
    offset = match.end;
  }
  if (text.isEmpty || !result.isFinite)
    throw FormatException('Invalid duration: $input');
  return result;
}

final class CaptureOptions {
  const CaptureOptions({
    required this.number,
    required this.frames,
    this.start = const VideoOffset(0),
    this.end = const VideoOffset(0),
    this.window = 1.5,
  });

  final int number;
  final int frames;
  final VideoOffset start;
  final VideoOffset end;
  final double window;
}

typedef CaptureSelection =
    void Function(
      int animationIndex,
      int captureIndex,
      FramePacket packet,
      int inputFrameIndex,
    );

final class CapturePlan {
  CapturePlan(double? videoDuration, CaptureOptions options)
    : frames = options.frames,
      window = options.window {
    if (videoDuration == null || videoDuration <= 0) {
      throw const FormatException('Missing positive video duration');
    }
    final first = options.start.seconds(videoDuration);
    usableDuration = videoDuration - first - options.end.seconds(videoDuration);
    if (first < 0 ||
        options.end.seconds(videoDuration) < 0 ||
        usableDuration <= 0) {
      throw const FormatException('Invalid video duration after offsets');
    }
    if (options.number <= 0 ||
        frames <= 0 ||
        options.number > 100000 ~/ frames ||
        window <= 0 ||
        !window.isFinite) {
      throw const FormatException('Invalid capture plan (limit 100000 frames)');
    }
    final step = usableDuration / options.number;
    final lastStart = math.max(0.0, videoDuration - window);
    starts = List.generate(
      options.number,
      (i) => math.min(first + step * (i + 0.5), lastStart),
      growable: false,
    );
  }

  late final double usableDuration;
  late final List<double> starts;
  final int frames;
  final double window;

  List<List<FramePacket>> select(
    Iterable<FramePacket> packets, {
    CaptureSelection? onSelect,
  }) {
    final targets = [
      for (var tile = 0; tile < starts.length; tile++)
        for (var frame = 0; frame < frames; frame++)
          (
            tile: tile,
            frame: frame,
            seconds: starts[tile] + window * frame / frames,
          ),
    ]..sort((a, b) => a.seconds.compareTo(b.seconds));
    final selected = List.generate(
      starts.length,
      (_) => List<FramePacket?>.filled(frames, null),
    );
    FramePacket? previous;
    var index = 0, inputIndex = -1;
    for (final packet in packets) {
      inputIndex++;
      if (previous != null && packet.seconds < previous.seconds) {
        throw const FormatException('Out-of-order presentation timestamps');
      }
      while (index < targets.length &&
          targets[index].seconds <= packet.seconds) {
        final target = targets[index++];
        final first = previous;
        final usePrevious =
            first != null &&
            target.seconds - first.seconds < packet.seconds - target.seconds &&
            first.seconds >= starts[target.tile];
        final frame = usePrevious ? first : packet;
        selected[target.tile][target.frame] = frame;
        onSelect?.call(
          target.frame,
          target.tile,
          frame,
          inputIndex - (usePrevious ? 1 : 0),
        );
      }
      if (index == targets.length) break;
      previous = packet;
    }
    if (index < targets.length && previous == null) {
      throw const FormatException('No video frames');
    }
    // Short streams can end before the requested window. Extend the final frame.
    for (; index < targets.length; index++) {
      final target = targets[index];
      selected[target.tile][target.frame] = previous;
      onSelect?.call(target.frame, target.tile, previous!, inputIndex);
    }
    return [for (final tile in selected) tile.cast<FramePacket>()];
  }
}

String timestampLabel(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return '${hours > 0 ? '$hours:' : ''}$minutes:$remainder';
}

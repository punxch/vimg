import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'capture_timeline.dart';
import 'frame_packet.dart';

part 'capture_filtered.dart';
part 'capture_timing.dart';

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
    if (videoDuration == null ||
        !videoDuration.isFinite ||
        videoDuration <= 0) {
      throw const FormatException('Missing positive video duration');
    }
    // CaptureWindow in the Rust CLI calculates the seek arguments as f32.
    final duration = _asFloat32(videoDuration);
    final startOffset = _offsetFloat32(options.start, duration);
    final endOffset = _offsetFloat32(options.end, duration);
    usableDuration = _asFloat32(_asFloat32(duration - startOffset) - endOffset);
    if (startOffset < 0 ||
        endOffset < 0 ||
        !usableDuration.isFinite ||
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
    final step = _asFloat32(usableDuration / options.number);
    final firstCenter = _asFloat32(startOffset + _asFloat32(step * 0.5));
    final lastStart = _asFloat32(duration - _asFloat32(window));
    starts = List.generate(
      options.number,
      (i) => _seekDecimal(
        math.min(_asFloat32(firstCenter + _asFloat32(step * i)), lastStart),
      ),
      growable: false,
    );
    _seekWindow = _seekDecimal(_asFloat32(window));
    _rate = captureRational(frames / _seekWindow);
  }

  late final double usableDuration;
  late final List<double> starts;
  final int frames;
  final double window;
  late final double _seekWindow;
  late final CaptureRational _rate;

  List<List<FramePacket>> select(
    Iterable<FramePacket> packets, {
    CaptureSelection? onSelect,
  }) => _packets(selectFrames(packets, onSelect: onSelect));

  List<List<CaptureFrame>> selectFrames(
    Iterable<FramePacket> packets, {
    CaptureSelection? onSelect,
  }) =>
      _selectFrames(packets, 0, starts.length, eof: true, onSelect: onSelect)!;

  /// A bounded index may end while a window still needs more source packets.
  /// Only a real end of file can fill slots by repeating the final packet.
  List<List<CaptureFrame>>? selectIndexedWindows(
    Iterable<FramePacket> packets,
    int first,
    int end, {
    required bool eof,
  }) => _selectFrames(packets, first, end, eof: eof);

  List<List<CaptureFrame>>? _selectFrames(
    Iterable<FramePacket> packets,
    int first,
    int end, {
    required bool eof,
    CaptureSelection? onSelect,
  }) {
    final schedules = [
      for (var index = first; index < end; index++)
        _CaptureSchedule(index, starts[index], frames, _rate, onSelect),
    ];
    final active = <_CaptureSchedule>[];
    var nextWindow = 0, inputIndex = -1;
    FramePacket? pending;
    double? lastDuration;

    void submit(FramePacket packet, double duration) {
      while (nextWindow < schedules.length &&
          schedules[nextWindow].containsStart(packet)) {
        active.add(schedules[nextWindow++]);
      }
      active.removeWhere((schedule) {
        schedule.push(packet, inputIndex, duration);
        return schedule.complete;
      });
    }

    for (final packet in packets) {
      if (pending != null) {
        final elapsed = packet.seconds - pending.seconds;
        if (elapsed < 0) {
          throw const FormatException('Out-of-order presentation timestamps');
        }
        final duration =
            _durationSeconds(pending) ??
            (elapsed > 0 ? elapsed : lastDuration ?? _rate.period);
        submit(pending, duration);
        lastDuration = duration;
        if (nextWindow == schedules.length && active.isEmpty) break;
      }
      pending = packet;
      inputIndex++;
    }
    if (nextWindow < schedules.length || active.isNotEmpty) {
      if (!eof) return null;
      if (pending == null) throw const FormatException('No video frames');
      submit(
        pending,
        _durationSeconds(pending) ?? lastDuration ?? _rate.period,
      );
      // Retain the final source frame if the requested window reaches EOF.
      for (final schedule in schedules) {
        schedule.finish(pending, inputIndex);
      }
    }
    return [for (final schedule in schedules) schedule.frames];
  }

  List<List<FramePacket>> selectFiltered(
    Iterable<FramePacket> packets,
    CaptureTimeline Function(CaptureTimeline) filter, {
    CaptureRational? timeBase,
    double? frameRate,
    CaptureSelection? onSelect,
  }) => _packets(
    selectFilteredFrames(
      packets,
      filter,
      timeBase: timeBase,
      frameRate: frameRate,
      onSelect: onSelect,
    ),
  );

  List<List<CaptureFrame>> selectFilteredFrames(
    Iterable<FramePacket> packets,
    CaptureTimeline Function(CaptureTimeline) filter, {
    CaptureRational? timeBase,
    double? frameRate,
    CaptureSelection? onSelect,
  }) => _selectFilteredCaptures(
    this,
    packets,
    filter,
    timeBase,
    frameRate,
    onSelect,
  );

  List<List<FramePacket>> _packets(List<List<CaptureFrame>> frames) => [
    for (final tile in frames) [for (final frame in tile) frame.packet],
  ];
}

String timestampLabel(int seconds) {
  seconds = math.max(0, seconds);
  final hours = seconds ~/ 3600;
  final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return '${hours > 0 ? '$hours:' : ''}$minutes:$remainder';
}

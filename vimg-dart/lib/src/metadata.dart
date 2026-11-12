final class VideoStream {
  const VideoStream({
    required this.codec,
    required this.width,
    required this.height,
    required this.timeBase,
    this.nominalFrameRate,
    this.attached = false,
  });

  final String codec;
  final int width;
  final int height;
  final String timeBase;
  final double? nominalFrameRate;
  final bool attached;

  Map<String, Object> toJson() => {
    'codec_type': 'video',
    'codec_name': codec,
    'width': width,
    'height': height,
    'time_base': timeBase,
    'disposition': {'attached_pic': attached ? 1 : 0},
  };
}

final class VideoMetadata {
  const VideoMetadata(this.duration, this.streams);

  final double? duration;
  final List<VideoStream> streams;

  Map<String, Object> toJson() => {
    'native_probe': true,
    'format': {
      if (duration case final seconds?) 'duration': seconds.toStringAsFixed(6),
    },
    'streams': streams.map((stream) => stream.toJson()).toList(),
  };
}

String timeBase(int numerator, int denominator) {
  final divisor = numerator.gcd(denominator);
  return '${numerator ~/ divisor}/${denominator ~/ divisor}';
}

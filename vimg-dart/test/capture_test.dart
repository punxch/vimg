import 'dart:convert';
import 'dart:io';

import 'package:vimg_dart/src/capture.dart';
import 'package:vimg_dart/src/frame_packet.dart';

import 'fixtures.dart';

void main() {
  _checkAuthorityTimeline();

  final plan = CapturePlan(1.25, const CaptureOptions(number: 1, frames: 3));
  final selected = plan.select([
    for (final pts in [0, 500, 1000]) _packet(pts, 1, 1000, duration: 500),
  ]).single;
  check(plan.starts.single == -0.25, 'CFR preserves a negative seek');
  check(
    selected.map((packet) => packet.timestamp!.pts).join(',') == '0,0,500',
    'CFR duplicates a late first source frame',
  );
  check(timestampLabel(-1) == '00:00', 'Short capture timestamp label');
}

void _checkAuthorityTimeline() {
  // The Rust schedule tests use the same FFmpeg authority PTS.
  final fixture =
      jsonDecode(
            File(
              '../tests/fixtures/frame-selection/representative.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final [numerator, denominator] = (fixture['source_time_base'] as List)
      .cast<int>();
  final duration = fixture['source_frame_duration'] as int;
  final count = fixture['frame_count'] as int;
  final captures = (fixture['captures'] as List).cast<Map<String, dynamic>>();
  final packets = [
    for (final capture in captures)
      for (final pts in (capture['source_pts'] as List).cast<int>())
        _packet(pts, numerator, denominator, duration: duration),
  ];
  final plan = CapturePlan(
    3295.446,
    CaptureOptions(number: captures.length, frames: count),
  );
  var reported = 0;
  final selected = plan.select(
    packets,
    onSelect: (frame, capture, packet, source) {
      check(packet == packets[source], 'CFR source index for $capture:$frame');
      check(
        packet.timestamp!.pts ==
            (captures[capture]['authority_pts'] as List)[frame],
        'CFR source PTS for $capture:$frame',
      );
      reported++;
    },
  );
  for (final (i, capture) in selected.indexed) {
    check(
      capture.length == count &&
          capture.map((packet) => packet.timestamp!.pts).join(',') ==
              (captures[i]['authority_pts'] as List).join(','),
      'CFR selection for capture $i',
    );
  }
  check(reported == 270, 'CFR authority selection count');
}

FramePacket _packet(int pts, int numerator, int denominator, {int? duration}) =>
    (
      seconds: pts * numerator / denominator,
      offset: pts,
      size: 1,
      subframe: null,
      timestamp: frameTimestamp(
        pts,
        numerator,
        denominator,
        duration: duration,
      ),
    );

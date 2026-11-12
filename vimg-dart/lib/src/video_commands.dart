import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as image;

import 'avif_encoder.dart';
import 'capture.dart';
import 'frame_packet.dart';
import 'grid.dart';
import 'output.dart';
import 'video.dart';
import 'yuv_image.dart';

String videoStem(String input) {
  final name = File(input).uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  return (dot > 0 ? name.substring(0, dot) : name).replaceAll('%', '');
}

String outputPath(String directory, String name) => File.fromUri(
  Directory(directory).absolute.uri.resolveUri(Uri(path: name)),
).path;

void _checkOutput(String input, String output) {
  final target = File(output);
  if (target.existsSync() && FileSystemEntity.identicalSync(input, output)) {
    throw const FormatException('Output must differ from input');
  }
}

Map<String, Object> writePreview(
  String input,
  String output, {
  required int skip,
  required int width,
  required int height,
  required int quality,
  void Function(String stage)? mark,
}) {
  final video = Video(input);
  mark?.call('open_header');
  try {
    final metadata = video.metadata;
    final response = {
      ...metadata.toJson(),
      'native_preview': true,
      'preview_written': false,
    };
    _checkOutput(input, output);
    final attached = metadata.streams.any((stream) => stream.attached);
    final upperBound = attached ? 95 : 90;
    if (skip > upperBound)
      return {...response, 'preview_upper_bound': upperBound};
    mark?.call('metadata');
    final seconds =
        ((metadata.duration ?? 0) * (skip + (attached ? 0 : 5)) / 100).floor();
    final image.Image frame;
    try {
      frame =
          (attached ? video.cover() : null) ?? _previewFrame(video, seconds);
    } on UnsupportedError catch (error) {
      return {
        ...response,
        'preview_fallback': error.message ?? error.toString(),
      };
    } on FormatException catch (error) {
      return {...response, 'preview_fallback': error.message};
    }
    mark?.call('decode');
    final scaled = resizeToFit(
      frame,
      width: width,
      height: height,
      enlarge: false,
    );
    mark?.call('scale');
    final jpeg = image.encodeJpg(scaled, quality: quality);
    mark?.call('encode');
    publishBytes(output, jpeg);
    mark?.call('publish');
    return {...response, 'preview_written': true};
  } finally {
    video.close();
    mark?.call('input_release');
  }
}

image.Image _previewFrame(Video video, int seconds) {
  FramePacket? last;
  for (final packet in video.packets(preview: true)) {
    last = packet;
    if (packet.seconds >= seconds) break;
  }
  if (last == null) throw const FormatException('No video frames');
  return video.decode(last, preview: true);
}

void extractFrames(String input, String directory, CaptureOptions options) {
  final video = Video(input);
  try {
    final plan = CapturePlan(video.metadata.duration, options);
    final selected = plan.select(video.packets());
    Directory(directory).createSync(recursive: true);
    _writeCaptures(video, input, directory, plan, selected);
  } finally {
    video.close();
  }
}

void _writeCaptures(
  Video video,
  String input,
  String directory,
  CapturePlan plan,
  List<List<FramePacket>> selected,
) {
  final paths = _capturePaths(input, directory, plan, selected);
  for (final decoded in video.decodeSelected(paths.keys)) {
    _publishCaptures(paths[decoded.packet]!, decoded.frame);
  }
}

Map<FramePacket, List<String>> _capturePaths(
  String input,
  String directory,
  CapturePlan plan,
  List<List<FramePacket>> selected,
) {
  final paths = <FramePacket, List<String>>{};
  final stem = videoStem(input);
  final secondsWidth = plan.usableDuration.floor().toString().length;
  final frameWidth = plan.frames.toString().length;
  final names = <String>{};
  for (var tile = 0; tile < selected.length; tile++) {
    final seconds = math
        .max(0, plan.starts[tile].floor())
        .toString()
        .padLeft(secondsWidth, '0');
    for (var frame = 0; frame < plan.frames; frame++) {
      final index = (frame + 1).toString().padLeft(frameWidth, '0');
      final base = '$stem-${seconds}s-$index';
      final name = names.add(base) ? base : '$base-${tile + 1}';
      paths
          .putIfAbsent(selected[tile][frame], () => [])
          .add(outputPath(directory, '$name.bmp'));
    }
  }
  return paths;
}

void _publishCaptures(List<String> paths, image.Image frame) {
  final bytes = image.encodeBmp(frame);
  for (final path in paths) {
    publishBytes(path, bytes);
  }
}

const _decodedFrameLimit = 256 * 1024 * 1024;

typedef GridFrameVisitor =
    void Function(int index, image.Image grid, int tileWidth, int tileHeight);

void writeContactSheet(
  String input,
  String output,
  CaptureOptions options, {
  required int columns,
  int? width,
  int? height,
  double fps = 20,
  int webp = 75,
  String? captureDirectory,
  void Function(String stage)? mark,
  CaptureSelection? onSelect,
  GridFrameVisitor? onGrid,
}) {
  final extension = output.split('.').last.toLowerCase();
  final image.Encoder? encoder;
  switch (extension) {
    case 'jpg' || 'jpeg':
      if (options.frames != 1)
        throw const FormatException('JPEG requires one frame per capture');
      encoder = image.JpegEncoder();
    case 'webp':
      encoder = image.WebPEncoder(lossless: false, quality: webp, method: 1);
    case 'avif':
      encoder = null;
    default:
      throw FormatException('Unsupported contact sheet output: $output');
  }
  _checkOutput(input, output);
  final video = Video(input);
  try {
    final plan = CapturePlan(video.metadata.duration, options);
    final selected = plan.select(video.packets(), onSelect: onSelect);
    mark?.call('schedule');
    final inter = video.usesReferencePictures;
    Map<FramePacket, List<String>>? paths;
    if (captureDirectory != null) {
      Directory(captureDirectory).createSync(recursive: true);
      if (inter) {
        paths = _capturePaths(input, captureDirectory, plan, selected);
      } else {
        _writeCaptures(video, input, captureDirectory, plan, selected);
      }
    }
    final cached = <FramePacket, image.Image>{};
    if (inter) {
      final scaler = width == null && height == null
          ? null
          : YuvImageScaler(width: width, height: height);
      var decodedBytes = 0;
      for (final result in video.decodeSelected(
        selected.expand((tile) => tile),
        scaler: scaler,
        includeOriginal: paths != null,
      )) {
        final frame = result.frame;
        decodedBytes += frame.width * frame.height * 3;
        if (decodedBytes > _decodedFrameLimit) {
          throw const FormatException(
            'Contact sheet exceeds 256 MiB of decoded tiles',
          );
        }
        cached[result.packet] = frame;
        if (paths != null) {
          _publishCaptures(paths[result.packet]!, result.original!);
        }
      }
    }
    final labels = plan.starts
        .map((start) => timestampLabel(start.floor()))
        .toList();
    final tiles = List<image.Image?>.filled(selected.length, null);
    final last = List<FramePacket?>.filled(selected.length, null);
    image.Image? animation, previousGrid;
    AvifEncoder? avif;
    for (var frame = 0; frame < options.frames; frame++) {
      var changed = false;
      for (var tile = 0; tile < tiles.length; tile++) {
        final packet = selected[tile][frame];
        if (last[tile] == packet) continue;
        tiles[tile] =
            cached[packet] ??
            resizeToFit(video.decode(packet), width: width, height: height);
        last[tile] = packet;
        changed = true;
      }
      final first = tiles.first!;
      if (!changed && avif != null) {
        avif.repeatFrame();
        onGrid?.call(frame, previousGrid!, first.width, first.height);
        continue;
      }
      final effectiveColumns = columns == 0
          ? tiles.length
          : math.min(columns, tiles.length);
      final rows = (tiles.length + effectiveColumns - 1) ~/ effectiveColumns;
      if (encoder != null &&
          frame == 0 &&
          first.width *
                  first.height *
                  effectiveColumns *
                  rows *
                  options.frames *
                  3 >
              _decodedFrameLimit) {
        throw const FormatException(
          'Contact sheet exceeds 256 MiB of decoded frames',
        );
      }
      final grid = composeGrid(tiles.cast<image.Image>(), columns, labels);
      if (onGrid != null) {
        onGrid(frame, grid, first.width, first.height);
        previousGrid = grid;
      }
      if (encoder == null) {
        avif ??= AvifEncoder(
          grid.width,
          grid.height,
          fps: options.frames > 1 ? fps : null,
        );
        avif.addFrame(grid);
        continue;
      }
      // Round absolute endpoints so non-integer frame durations do not drift.
      grid.frameDuration =
          ((frame + 1) * 1000 / fps).round() - (frame * 1000 / fps).round();
      if (animation == null) {
        animation = grid;
      } else {
        animation.addFrame(grid);
      }
    }
    mark?.call(
      avif == null ? 'decode_and_compose' : 'decode_compose_and_encode',
    );
    final bytes = avif?.finish() ?? encoder!.encode(animation!);
    mark?.call('encode');
    File(output).absolute.parent.createSync(recursive: true);
    publishBytes(output, bytes);
    mark?.call('publish');
  } finally {
    video.close();
  }
}

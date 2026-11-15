import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as image;
import 'package:path/path.dart' as paths;

import 'avif_encoder.dart';
import 'capture.dart';
import 'capture_timeline.dart';
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

const defaultCaptureThreads = 4;

List<List<CaptureFrame>> _selectCaptures(
  Video video,
  CapturePlan plan,
  VideoFilterChain? filters, {
  CaptureSelection? onSelect,
}) {
  final packets = video.packets();
  if (filters == null || !filters.usesTimeline) {
    return plan.selectFrames(packets, onSelect: onSelect);
  }
  final stream = video.metadata.streams.firstWhere(
    (stream) => !stream.attached,
  );
  final [numerator, denominator] = stream.timeBase
      .split('/')
      .map(int.parse)
      .toList();
  return plan.selectFilteredFrames(
    packets,
    filters.filterTiming,
    timeBase: (numerator: numerator, denominator: denominator),
    frameRate: stream.nominalFrameRate,
    onSelect: onSelect,
  );
}

Future<void> extractFrames(
  String input,
  String directory,
  CaptureOptions options, {
  int threads = defaultCaptureThreads,
  VideoFilterChain? filters,
}) async {
  final video = Video(input);
  VideoCaptureDecoder? decoder;
  try {
    final plan = CapturePlan(video.metadata.duration, options);
    final selected = _selectCaptures(video, plan, filters);
    Directory(directory).createSync(recursive: true);
    final paths = _capturePaths(input, directory, plan, selected);
    decoder = VideoCaptureDecoder(
      video,
      threads: threads,
      scaler: filters?.hasSpatialFilters == true
          ? YuvImageScaler(filters: filters)
          : null,
    );
    await for (final decoded in decoder.decodeCaptures(paths.keys)) {
      _publishCaptures(paths[decoded.capture]!, decoded.frame);
    }
  } finally {
    try {
      await decoder?.close();
    } finally {
      video.close();
    }
  }
}

Map<CaptureFrame, List<String>> _capturePaths(
  String input,
  String directory,
  CapturePlan plan,
  List<List<CaptureFrame>> selected,
) {
  final paths = <CaptureFrame, List<String>>{};
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
const defaultAvifCrf = 30;

int _avifQIndex(int crf, {required bool animated}) {
  if (crf < 0 || crf > 63) {
    throw const FormatException('AVIF CRF must be between 0 and 63');
  }
  // Keep fine steps around the Preview preset while covering coarse AV1
  // quantizers at the high end of the CLI scale.
  return math.max(1, (224 * math.pow(crf / 63, animated ? 3.25 : 3)).round());
}

typedef GridFrameVisitor =
    void Function(int index, image.Image grid, int tileWidth, int tileHeight);

enum ContactSheetFormat {
  avif,
  webp,
  jpeg;

  static ContactSheetFormat forPath(String output, {bool preferWebp = false}) =>
      switch (paths.extension(output).toLowerCase()) {
        '.jpg' || '.jpeg' => jpeg,
        '.webp' => webp,
        _ => preferWebp ? webp : avif,
      };
}

Future<void> writeContactSheet(
  String input,
  String output,
  CaptureOptions options, {
  required int columns,
  int? width,
  int? height,
  double fps = 20,
  int avifCrf = defaultAvifCrf,
  int? avifPreset,
  ContactSheetFormat? format,
  int webp = 75,
  int threads = defaultCaptureThreads,
  VideoFilterChain? filters,
  String? captureDirectory,
  void Function(String stage)? mark,
  CaptureSelection? onSelect,
  GridFrameVisitor? onGrid,
}) async {
  final image.Encoder? encoder;
  switch (format ?? ContactSheetFormat.forPath(output)) {
    case ContactSheetFormat.jpeg:
      if (options.frames != 1)
        throw const FormatException('JPEG requires one frame per capture');
      encoder = image.JpegEncoder();
    case ContactSheetFormat.webp:
      encoder = image.WebPEncoder(lossless: false, quality: webp, method: 1);
    case ContactSheetFormat.avif:
      encoder = null;
  }
  _checkOutput(input, output);
  final video = Video(input);
  VideoCaptureDecoder? decoder;
  try {
    final plan = CapturePlan(video.metadata.duration, options);
    final selected = _selectCaptures(video, plan, filters, onSelect: onSelect);
    mark?.call('schedule');
    final inter = video.usesReferencePictures;
    final spatial = filters?.hasSpatialFilters == true ? filters : null;
    final scaleInDecoder = spatial != null || video.scalesBeforeRgb;
    Map<CaptureFrame, List<String>>? paths;
    if (captureDirectory != null) {
      Directory(captureDirectory).createSync(recursive: true);
      paths = _capturePaths(input, captureDirectory, plan, selected);
    }
    decoder = VideoCaptureDecoder(
      video,
      threads: threads,
      scaler:
          scaleInDecoder && (spatial != null || width != null || height != null)
          ? YuvImageScaler(width: width, height: height, filters: spatial)
          : null,
      includeOriginal: paths != null && scaleInDecoder,
    );
    final cached = <CaptureFrame, image.Image>{};
    if (inter) {
      var decodedBytes = 0;
      await for (final result in decoder.decodeCaptures(
        selected.expand((tile) => tile),
      )) {
        final frame = result.frame;
        decodedBytes += frame.width * frame.height * 3;
        if (decodedBytes > _decodedFrameLimit) {
          throw const FormatException(
            'Contact sheet exceeds 256 MiB of decoded tiles',
          );
        }
        cached[result.capture] = frame;
        if (paths != null) {
          _publishCaptures(paths[result.capture]!, result.original!);
        }
      }
    }
    final labels = plan.starts
        .map((start) => timestampLabel(start.floor()))
        .toList();
    final tiles = List<image.Image?>.filled(selected.length, null);
    final last = List<CaptureFrame?>.filled(selected.length, null);
    image.Image? animation, previousGrid;
    AvifEncoder? avif;
    GridComposer? composer;
    for (var frame = 0; frame < options.frames; frame++) {
      final missing = <CaptureFrame, List<int>>{};
      var changed = false;
      for (var tile = 0; tile < tiles.length; tile++) {
        final packet = selected[tile][frame];
        if (last[tile] == packet) continue;
        last[tile] = packet;
        if (inter) {
          tiles[tile] = cached[packet]!;
        } else {
          missing.putIfAbsent(packet, () => []).add(tile);
        }
        changed = true;
      }
      if (missing.isNotEmpty) {
        await for (final result in decoder.decodeCaptures(missing.keys)) {
          final captures = paths?.remove(result.capture);
          if (captures != null) {
            _publishCaptures(captures, result.original ?? result.frame);
          }
          final tile = scaleInDecoder
              ? result.frame
              : resizeToFit(result.frame, width: width, height: height);
          for (final index in missing[result.capture]!) {
            tiles[index] = tile;
          }
        }
      }
      final first = tiles.first!;
      if (!changed && avif != null) {
        avif.repeatFrame();
        onGrid?.call(
          frame,
          previousGrid!,
          composer!.tileWidth,
          composer.tileHeight,
        );
        continue;
      }
      composer ??= GridComposer(
        first.width,
        first.height,
        tiles.length,
        columns,
        labels,
      );
      if (encoder != null &&
          frame == 0 &&
          composer.width * composer.height * options.frames * 3 >
              _decodedFrameLimit) {
        throw const FormatException(
          'Contact sheet exceeds 256 MiB of decoded frames',
        );
      }
      final grid = composer.compose(tiles.cast<image.Image>(), fitTiles: true);
      if (onGrid != null) {
        onGrid(frame, grid, composer.tileWidth, composer.tileHeight);
        previousGrid = grid;
      }
      if (encoder == null) {
        avif ??= AvifEncoder(
          grid.width,
          grid.height,
          fps: options.frames > 1 ? fps : null,
          qIndex: _avifQIndex(avifCrf, animated: options.frames > 1),
          preset: avifPreset ?? defaultAvifPreset,
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
    try {
      await decoder?.close();
    } finally {
      video.close();
    }
  }
}

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:path/path.dart' as paths;

import 'avif_encoder.dart';
import 'capture.dart';
import 'capture_timeline.dart';
import 'frame_packet.dart';
import 'grid.dart';
import 'output.dart';
import 'video.dart';
import 'webp_animation.dart';
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
      final cover = attached ? video.cover() : null;
      if (attached) mark?.call('cover');
      frame =
          cover ??
          _previewFrame(
            video,
            seconds,
            YuvImageScaler(width: width, height: height, enlarge: false),
            mark,
          );
    } catch (error) {
      final message = _previewError(error);
      if (message == null) rethrow;
      return {...response, 'preview_fallback': message};
    }
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

image.Image _previewFrame(
  Video video,
  int seconds,
  YuvImageScaler scaler,
  void Function(String stage)? mark,
) {
  try {
    if (video.indexedPreviewPackets(seconds) case final indexed?) {
      mark?.call('cue_index');
      return _decodePreview(
        video,
        indexed,
        seconds,
        scaler,
        mark,
        indexed: true,
      );
    }
  } catch (error) {
    if (_previewError(error) == null) rethrow;
    mark?.call('cue_fallback');
  }
  return _decodePreview(
    video,
    video.packets(preview: true),
    seconds,
    scaler,
    mark,
  );
}

image.Image _decodePreview(
  Video video,
  Iterable<FramePacket> packets,
  int seconds,
  YuvImageScaler scaler,
  void Function(String stage)? mark, {
  bool indexed = false,
}) {
  FramePacket? previous, next;
  try {
    for (final packet in packets) {
      if (packet.seconds >= seconds) {
        next = packet;
        break;
      }
      if (previous == null || packet.seconds >= previous.seconds) {
        previous = packet;
      }
    }
  } catch (error) {
    if (indexed || previous == null || _previewError(error) == null) rethrow;
  } finally {
    mark?.call('seek');
  }
  image.Image decode(FramePacket packet, String stage) {
    try {
      return video.decode(packet, preview: true, previewScaler: scaler);
    } finally {
      mark?.call(stage);
    }
  }

  final first = next ?? previous;
  if (first == null) throw const FormatException('No video frames');
  try {
    return decode(first, 'decode');
  } catch (error) {
    if (next == null || previous == null || _previewError(error) == null) {
      rethrow;
    }
    return decode(previous, 'decode_retry');
  }
}

String? _previewError(Object error) => switch (error) {
  final FormatException failure => failure.message,
  final UnsupportedError failure => failure.message ?? failure.toString(),
  final image.ImageException failure => failure.toString(),
  _ => null,
};

const defaultCaptureThreads = 4;

List<List<CaptureFrame>> _selectCaptures(
  Video video,
  CapturePlan plan,
  VideoFilterChain? filters, {
  CaptureSelection? onSelect,
}) {
  if (filters == null || !filters.usesTimeline) {
    if (onSelect == null) {
      final indexed = video.indexedCaptures(plan);
      if (indexed != null) return indexed;
    }
    return plan.selectFrames(video.packets(), onSelect: onSelect);
  }
  final (:timeBase, :frameRate) = video.filterTiming;
  return plan.selectFilteredFrames(
    video.packets(),
    filters.filterTiming,
    timeBase: timeBase,
    frameRate: frameRate,
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
    final bitmapFilters = filters?.forBitmap();
    final selected = _selectCaptures(video, plan, bitmapFilters);
    Directory(directory).createSync(recursive: true);
    final paths = _capturePaths(input, directory, plan, selected);
    decoder = VideoCaptureDecoder(
      video,
      threads: threads,
      scaler: bitmapFilters?.hasSpatialFilters == true
          ? YuvImageScaler(filters: bitmapFilters)
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
  final outputFormat = format ?? ContactSheetFormat.forPath(output);
  if (outputFormat == ContactSheetFormat.jpeg && options.frames != 1) {
    throw const FormatException('JPEG requires one frame per capture');
  }
  final stillEncoder = switch (outputFormat) {
    ContactSheetFormat.jpeg => image.JpegEncoder(),
    ContactSheetFormat.webp when options.frames == 1 => image.WebPEncoder(
      lossless: false,
      quality: webp,
      method: 1,
    ),
    _ => null,
  };
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
      threads: inter
          ? threads
          : math.min(
              threads == 0 ? Platform.numberOfProcessors : threads,
              selected.length,
            ),
      scaler:
          scaleInDecoder && (spatial != null || width != null || height != null)
          ? YuvImageScaler(
              width: width,
              height: height,
              filters: spatial,
              packedOutput: true,
            )
          : null,
      includeOriginal: paths != null && scaleInDecoder,
    );
    final labels = plan.starts
        .map((start) => timestampLabel(start.floor()))
        .toList();
    // Round absolute endpoints so non-integer WebP frame durations do not drift.
    int webpDuration(int frame) =>
        ((frame + 1) * 1000 / fps).round() - (frame * 1000 / fps).round();
    image.Image? still, previousGrid;
    AvifEncoder? avif;
    WebpAnimationEncoder? animation;
    GridComposer? composer;
    var index = 0;
    await for (final tiles in _contactSheetTiles(
      decoder,
      selected,
      paths,
      width: scaleInDecoder ? null : width,
      height: scaleInDecoder ? null : height,
    )) {
      final frame = index++;
      if ((avif != null || animation != null) &&
          selected.every((tile) => tile[frame] == tile[frame - 1])) {
        avif?.repeatFrame();
        animation?.repeatFrame(webpDuration(frame));
        onGrid?.call(
          frame,
          previousGrid!,
          composer!.tileWidth,
          composer.tileHeight,
        );
        continue;
      }
      final first = tiles.first;
      composer ??= GridComposer(
        first.width,
        first.height,
        tiles.length,
        columns,
        labels,
      );
      if (outputFormat != ContactSheetFormat.avif &&
          frame == 0 &&
          composer.width * composer.height * 3 > _decodedFrameLimit) {
        throw const FormatException('Contact sheet frame exceeds 256 MiB');
      }
      final grid = composer.compose(tiles, fitTiles: true);
      if (onGrid != null) {
        onGrid(frame, grid, composer.tileWidth, composer.tileHeight);
        previousGrid = grid;
      }
      if (stillEncoder != null) {
        still = grid;
      } else if (outputFormat == ContactSheetFormat.avif) {
        avif ??= AvifEncoder(
          grid.width,
          grid.height,
          fps: options.frames > 1 ? fps : null,
          qIndex: _avifQIndex(avifCrf, animated: options.frames > 1),
          preset: avifPreset ?? defaultAvifPreset,
        );
        avif.addFrame(grid);
      } else {
        animation ??= WebpAnimationEncoder(
          grid.width,
          grid.height,
          quality: webp,
        );
        animation.addFrame(grid, webpDuration(frame));
      }
    }
    mark?.call(
      stillEncoder != null ? 'decode_and_compose' : 'decode_compose_and_encode',
    );
    final bytes =
        avif?.finish() ?? animation?.finish() ?? stillEncoder!.encode(still!);
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

Stream<List<image.Image>> _contactSheetTiles(
  VideoCaptureDecoder decoder,
  List<List<CaptureFrame>> selected,
  Map<CaptureFrame, List<String>>? paths, {
  int? width,
  int? height,
}) async* {
  final frames = selected.first.length;
  final remaining = Int32List(frames);
  final uses = <CaptureFrame, List<int>>{};
  final firstUse = <FramePacket, int>{};
  for (var frame = 0; frame < frames; frame++) {
    remaining[frame] = selected.length;
    for (final tile in selected) {
      final capture = tile[frame];
      uses.putIfAbsent(capture, () => []).add(frame);
      firstUse.putIfAbsent(capture.packet, () => frame);
    }
  }
  final ready = <CaptureFrame, ({image.Image tile, int last})>{};
  var bytes = 0, next = 0;
  int pixelBytes(image.Image tile) =>
      tile.width * tile.height * tile.numChannels;
  await for (final result in decoder.decodeCaptures(
    uses.keys,
    firstUse: firstUse,
  )) {
    final occurrences = uses.remove(result.capture);
    if (occurrences == null)
      throw const FormatException('Unexpected captured tile');
    final output = paths?.remove(result.capture);
    if (output != null)
      _publishCaptures(output, result.original ?? result.frame);
    final tile = resizeToFit(result.frame, width: width, height: height);
    ready[result.capture] = (tile: tile, last: occurrences.last);
    bytes += pixelBytes(tile);
    for (final frame in occurrences) {
      remaining[frame]--;
    }
    while (next < frames && remaining[next] == 0) {
      final row = [for (final capture in selected) ready[capture[next]]!.tile];
      for (final capture in selected) {
        final key = capture[next];
        if (ready[key] case final frame? when frame.last == next) {
          ready.remove(key);
          bytes -= pixelBytes(frame.tile);
        }
      }
      next++;
      yield row;
    }
    if (bytes > _decodedFrameLimit) {
      throw const FormatException(
        'Contact sheet exceeds 256 MiB of queued tiles',
      );
    }
  }
  if (next != frames) throw const FormatException('Missing captured tiles');
}

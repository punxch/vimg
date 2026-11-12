import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:path/path.dart' as paths;

import 'avif_animation.dart';
import 'capture.dart';
import 'frame_packet.dart';
import 'ssim.dart';
import 'video_commands.dart';

const _marker = '.vimg-authority';
const _signature = 'vimg-authority-v1\n';

void recordAuthority(
  String input,
  String output,
  String manifest,
  CaptureOptions options, {
  required int columns,
  required int height,
  required double fps,
  String? captureDirectory,
  void Function(String stage)? mark,
}) {
  final outputFile = File(output).absolute;
  final manifestFile = File(manifest).absolute;
  final framePath = '${manifestFile.path}.frames';
  final locks = <RandomAccessFile>[];
  try {
    _validatePaths(input, outputFile, manifestFile, framePath);
    final destinations = [
      _identity(outputFile.path),
      _identity(manifestFile.path),
    ];
    final lockPaths = {
      for (final path in destinations)
        paths.join(
          paths.dirname(path),
          '.${paths.basename(path)}.vimg-authority.lock',
        ),
    }.toList()..sort();
    for (final path in lockPaths) {
      final file = File(path);
      file.parent.createSync(recursive: true);
      final lock = file.openSync(mode: FileMode.append);
      locks.add(lock);
      lock.lockSync(FileLock.blockingExclusive);
    }
    _validatePaths(input, outputFile, manifestFile, framePath);
    _record(
      input,
      output,
      manifest,
      options,
      columns,
      height,
      fps,
      outputFile,
      manifestFile,
      Directory(framePath),
      captureDirectory,
      mark,
    );
  } finally {
    for (final lock in locks.reversed) {
      lock.closeSync();
    }
  }
}

void _record(
  String input,
  String output,
  String manifest,
  CaptureOptions options,
  int columns,
  int height,
  double fps,
  File outputFile,
  File manifestFile,
  Directory container,
  String? captureDirectory,
  void Function(String stage)? mark,
) {
  if (_type(container.path) != FileSystemEntityType.notFound &&
      !_owned(container))
    throw FormatException(
      'Refusing to replace unowned authority frame path ${container.path}',
    );
  final stages = <Directory>[];
  Directory stage(Directory parent) {
    final directory = parent.createTempSync('.vimg-authority-');
    stages.add(directory);
    return directory;
  }

  Directory? generation;
  var createdContainer = false, createdGeneration = false, published = false;
  try {
    final outputStage = stage(outputFile.parent);
    final manifestStage = stage(manifestFile.parent);
    final stagedOutput = File(paths.join(outputStage.path, 'sheet.avif'));
    final stagedManifest = File(
      paths.join(manifestStage.path, 'manifest.json'),
    );
    final frames = Directory(paths.join(manifestStage.path, 'frames'))
      ..createSync();
    _markOwned(frames);
    final recorder = _Recorder(frames, options.number, options.frames);
    writeContactSheet(
      input,
      stagedOutput.path,
      options,
      columns: columns,
      height: height,
      fps: fps,
      captureDirectory: captureDirectory,
      mark: mark,
      onSelect: recorder.selection,
      onGrid: recorder.grid,
    );
    final animation = AvifAnimation.open(stagedOutput.path);
    final Map<String, Object> structure;
    try {
      if (animation.width != recorder.gridWidth ||
          animation.height != recorder.gridHeight ||
          animation.frameCount != options.frames ||
          (animation.framesPerSecond - fps).abs() >= 0.000001) {
        throw const FormatException(
          'Encoded AVIF does not match the authority profile',
        );
      }
      var index = 0;
      for (final frame in animation.decodeFrames()) {
        recorder.decoded(index++, frame);
      }
      structure = {
        'width': animation.width,
        'height': animation.height,
        'frame_rate': animation.frameRate,
        'duration_s': animation.durationSeconds,
        'frame_count': animation.frameCount,
        'stream_index': animation.streamIndex,
      };
    } finally {
      animation.close();
    }

    final digest = _FNV128()..file(stagedOutput);
    for (final kind in ['pre-encoder', 'decoded']) {
      for (var frame = 0; frame < options.frames; frame++) {
        digest.file(recorder.frame(kind, frame));
      }
    }
    generation = Directory(paths.join(container.path, digest.hex));
    if (_type(container.path) == FileSystemEntityType.notFound) {
      container.createSync();
      createdContainer = true;
      _markOwned(container);
    } else if (!_owned(container)) {
      throw FormatException(
        'Refusing to replace unowned authority frame path ${container.path}',
      );
    }
    if (_type(generation.path) == FileSystemEntityType.notFound) {
      frames.renameSync(generation.path);
      createdGeneration = true;
    } else if (!_matchingFrames(recorder, generation, options.frames)) {
      throw FormatException(
        'Immutable authority digest collision at ${generation.path}',
      );
    }

    List<String> visualPaths(String kind) => [
      for (var i = 0; i < options.frames; i++)
        paths.relative(
          paths.join(generation!.path, kind, _frameName(i)),
          from: manifestFile.parent.path,
        ),
    ];
    final selected = recorder.selections;
    final data = {
      'version': 1,
      'authority': 'production-dart-capture',
      'input': input,
      'output': output,
      'profile': {
        'columns': columns,
        'capture_count': options.number,
        'capture_frames': options.frames,
        'capture_time_s': options.window,
        'capture_width': recorder.tileWidth,
        'capture_height': recorder.tileHeight,
      },
      'selected_frames': selected,
      'animation': {
        ...structure,
        'pre_encoder_visual_frames': visualPaths('pre-encoder'),
        'decoded_visual_frames': visualPaths('decoded'),
      },
    };
    stagedManifest.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(data)}\n',
    );
    _publish(stagedOutput, outputFile, stagedManifest, manifestFile);
    published = true;
    _clean(() {
      for (final directory
          in container.listSync(followLinks: false).whereType<Directory>()) {
        if (directory.path != generation!.path && _owned(directory))
          directory.deleteSync(recursive: true);
      }
    });
    stdout.writeln(
      'authority recorded: ${selected.length} source PTS, ${options.frames} '
      'pre-encoder and ${options.frames} decoded visual frames, manifest $manifest',
    );
  } finally {
    if (!published) {
      if (createdGeneration)
        _clean(() => generation!.deleteSync(recursive: true));
      if (createdContainer) {
        _clean(() {
          final marker = _ownershipFile(container);
          if (marker.existsSync()) marker.deleteSync();
          container.deleteSync();
        });
      }
    }
    for (final directory in stages.reversed) {
      _clean(() => directory.deleteSync(recursive: true));
    }
  }
}

final class _Recorder {
  _Recorder(this.directory, this.captureCount, int frameCount)
    : _selections = List.filled(captureCount * frameCount, null) {
    for (final kind in ['pre-encoder', 'decoded']) {
      Directory(paths.join(directory.path, kind)).createSync();
    }
  }

  final Directory directory;
  final int captureCount;
  final List<Map<String, Object>?> _selections;
  late int gridWidth, gridHeight, tileWidth, tileHeight;
  image.Image? _previousGrid;
  Uint8List? _previousPng;

  void selection(int animation, int capture, FramePacket packet, int index) {
    final timestamp = packet.timestamp;
    if (timestamp == null)
      throw const FormatException(
        'Selected video frame has no source timestamp',
      );
    _selections[animation * captureCount + capture] = {
      'animation_index': animation,
      'capture_index': capture,
      'source_pts': timestamp.pts,
      'source_time_base': '${timestamp.numerator}/${timestamp.denominator}',
      'input_frame_index': index,
    };
  }

  List<Map<String, Object>> get selections {
    if (_selections.any((selection) => selection == null))
      throw const FormatException('Missing selected source frame');
    return _selections.cast<Map<String, Object>>();
  }

  File frame(String kind, int index) =>
      File(paths.join(directory.path, kind, _frameName(index)));

  void grid(int index, image.Image pixels, int width, int height) {
    if (index == 0) {
      gridWidth = pixels.width;
      gridHeight = pixels.height;
      tileWidth = width;
      tileHeight = height;
    }
    if (!identical(_previousGrid, pixels)) {
      _previousPng = image.encodePng(pixels);
      _previousGrid = pixels;
    }
    frame('pre-encoder', index).writeAsBytesSync(_previousPng!);
  }

  void decoded(int index, image.Image pixels) =>
      frame('decoded', index).writeAsBytesSync(image.encodePng(pixels));
}

String _frameName(int index) =>
    'frame-${(index + 1).toString().padLeft(3, '0')}.png';

FileSystemEntityType _type(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false);

String _identity(String path) {
  var current = paths.absolute(path);
  final suffix = <String>[];
  while (_type(current) == FileSystemEntityType.notFound) {
    final parent = paths.dirname(current);
    if (parent == current)
      throw FormatException('No existing ancestor for authority path $path');
    suffix.add(paths.basename(current));
    current = parent;
  }
  final resolved = File(current).resolveSymbolicLinksSync();
  final identity = paths.normalize(
    paths.joinAll([resolved, ...suffix.reversed]),
  );
  return Platform.isWindows ? identity.toLowerCase() : identity;
}

void _validatePaths(String input, File output, File manifest, String frames) {
  final source = _identity(input);
  final destination = _identity(output.path);
  final record = _identity(manifest.path);
  final directory = _identity(frames);
  bool overlaps(String first, String second) =>
      first == second ||
      paths.isWithin(first, second) ||
      paths.isWithin(second, first) ||
      (File(first).existsSync() &&
          File(second).existsSync() &&
          FileSystemEntity.identicalSync(first, second));
  final artifacts = [source, destination, record, directory];
  for (var i = 0; i < artifacts.length; i++) {
    for (var j = i + 1; j < artifacts.length; j++) {
      if (overlaps(artifacts[i], artifacts[j])) {
        throw const FormatException(
          'Input, output, manifest and authority frame directory must not overlap',
        );
      }
    }
  }
  if (Directory(output.path).existsSync() ||
      Directory(manifest.path).existsSync())
    throw const FormatException('Authority output and manifest must be files');
}

File _ownershipFile(Directory directory) =>
    File(paths.join(directory.path, _marker));
void _markOwned(Directory directory) =>
    _ownershipFile(directory).writeAsStringSync(_signature);
bool _owned(Directory directory) {
  final marker = _ownershipFile(directory);
  return _type(directory.path) == FileSystemEntityType.directory &&
      _type(marker.path) == FileSystemEntityType.file &&
      marker.lengthSync() == _signature.length &&
      marker.readAsStringSync() == _signature;
}

bool _matchingFrames(_Recorder expected, Directory actual, int count) {
  if (!_owned(actual)) return false;
  for (final kind in ['pre-encoder', 'decoded']) {
    final directory = paths.join(actual.path, kind);
    if (_type(directory) != FileSystemEntityType.directory) return false;
    for (var i = 0; i < count; i++) {
      final file = File(paths.join(directory, _frameName(i)));
      if (_type(file.path) != FileSystemEntityType.file ||
          !_equalFiles(expected.frame(kind, i), file))
        return false;
    }
  }
  return true;
}

bool _equalFiles(File left, File right) {
  if (left.lengthSync() != right.lengthSync()) return false;
  final a = left.openSync();
  try {
    final b = right.openSync();
    try {
      while (true) {
        final x = a.readSync(65536), y = b.readSync(65536);
        if (x.length != y.length) return false;
        if (x.isEmpty) return true;
        for (var i = 0; i < x.length; i++) {
          if (x[i] != y[i]) return false;
        }
      }
    } finally {
      b.closeSync();
    }
  } finally {
    a.closeSync();
  }
}

void _publish(File output, File target, File manifest, File record) {
  final image = _Publication(target);
  final json = _Publication(record);
  try {
    image.install(output);
    json.install(manifest);
  } catch (_) {
    _clean(json.rollback);
    _clean(image.rollback);
    rethrow;
  }
  _clean(json.finish);
  _clean(image.finish);
}

final class _Publication {
  _Publication(this.target);

  final File target;
  Directory? _workspace;
  FileSystemEntity? _backup;
  var _installed = false;

  void install(File staged) {
    final existing = switch (_type(target.path)) {
      FileSystemEntityType.notFound => null,
      FileSystemEntityType.file => target,
      FileSystemEntityType.link => Link(target.path),
      _ => throw FormatException(
        'Authority publication target is not a file ${target.path}',
      ),
    };
    if (existing != null) {
      _workspace = target.parent.createTempSync('.vimg-authority-backup-');
      _backup = existing.renameSync(paths.join(_workspace!.path, 'previous'));
    }
    staged.renameSync(target.path);
    _installed = true;
  }

  void rollback() {
    if (_installed) target.deleteSync();
    _backup?.renameSync(target.path);
    finish();
  }

  void finish() => _workspace?.deleteSync(recursive: true);
}

void _clean(void Function() operation) {
  try {
    operation();
  } on FileSystemException catch (error) {
    stderr.writeln('warning: authority cleanup failed: $error');
  }
}

/// FNV-1a-128 over the AVIF and the ordered PNG sequence, using two 64-bit limbs.
final class _FNV128 {
  var _hi = 0x6c62272e07bb0142, _lo = 0x62b821756295c58d;

  void _byte(int byte) {
    final low = _lo ^ byte;
    final a = (low & 0xffffffff) * 315;
    final b = (low >>> 32) * 315 + (a >>> 32);
    _lo = (b << 32) | (a & 0xffffffff);
    _hi = _hi * 315 + (low << 24) + (b >>> 32);
  }

  void file(File file) {
    final input = file.openSync();
    try {
      while (true) {
        final bytes = input.readSync(65536);
        if (bytes.isEmpty) break;
        for (final byte in bytes) {
          _byte(byte);
        }
      }
      _byte(255);
    } finally {
      input.closeSync();
    }
  }

  String get hex => [
    _hi >>> 32,
    _hi & 0xffffffff,
    _lo >>> 32,
    _lo & 0xffffffff,
  ].map((word) => word.toRadixString(16).padLeft(8, '0')).join();
}

void verifyAuthority(String reference, String candidate, double minimum) {
  if (!minimum.isFinite || minimum < 0 || minimum > 1)
    throw const FormatException(
      'Visual comparison failed. --min-ssim must be between 0 and 1',
    );
  final original = AvifAnimation.open(reference);
  try {
    final comparison = AvifAnimation.open(candidate);
    try {
      if (original.width != comparison.width ||
          original.height != comparison.height ||
          original.frameCount != comparison.frameCount ||
          (original.framesPerSecond - comparison.framesPerSecond).abs() >=
              0.000001 ||
          (original.durationSeconds - comparison.durationSeconds).abs() >=
              0.000001) {
        throw const FormatException(
          'Structural inspection failed. AVIF animations differ in size, frame count, frame rate or duration',
        );
      }
      final left = original.decodeFrames().iterator;
      final right = comparison.decodeFrames().iterator;
      var lowest = 1.0;
      for (var i = 0; i < original.frameCount; i++) {
        if (!left.moveNext() || !right.moveNext())
          throw const FormatException(
            'Decoding failed. Incomplete AVIF animation',
          );
        final score = double.parse(
          frameSsim(left.current, right.current).toStringAsFixed(6),
        );
        if (score < minimum)
          throw FormatException(
            'Visual comparison failed. Frame ${i + 1} SSIM ${score.toStringAsFixed(6)} '
            'is below required ${minimum.toStringAsFixed(6)}',
          );
        if (score < lowest) lowest = score;
      }
      stdout.writeln(
        'authority verified: ${original.frameCount} frames, minimum SSIM ${lowest.toStringAsFixed(6)}',
      );
    } finally {
      comparison.close();
    }
  } finally {
    original.close();
  }
}

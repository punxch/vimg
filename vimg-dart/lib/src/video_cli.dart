import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'capture.dart';
import 'video_commands.dart';

abstract class VimgCommand extends Command<void> {
  int? integer(String option, {int min = 0, int? max}) {
    final value = argResults!.option(option);
    if (value == null) return null;
    final number = int.tryParse(value);
    if (number == null || number < min || (max != null && number > max)) {
      final range = max == null ? 'at least $min' : 'from $min to $max';
      usageException('--$option must be an integer $range.');
    }
    return number;
  }

  String get video {
    final args = argResults!.rest;
    if (args.length != 1) usageException('Provide exactly one video path.');
    return args.single;
  }
}

final class PreviewCommand extends VimgCommand {
  PreviewCommand() {
    argParser
      ..addOption('output', mandatory: true, help: 'Destination JPEG.')
      ..addOption('skip', defaultsTo: '0', help: 'Preview position offset.')
      ..addOption('max-width', defaultsTo: '600')
      ..addOption('max-height', defaultsTo: '900')
      ..addOption('quality', defaultsTo: '75')
      ..addFlag('timings', negatable: false);
  }

  @override
  String get name => 'preview';
  @override
  String get description => 'Write a static JPEG preview and print metadata.';

  @override
  void run() {
    final args = argResults!;
    final timings = args.flag('timings') ? _Timings() : null;
    final response = writePreview(
      video,
      args.option('output')!,
      skip: integer('skip')!,
      width: integer('max-width', min: 1, max: 16384)!,
      height: integer('max-height', min: 1, max: 16384)!,
      quality: integer('quality', max: 100)!,
      mark: timings?.mark,
    );
    timings?.report('vimg-preview-timing');
    stdout.writeln(jsonEncode(response));
  }
}

abstract class _CaptureCommand extends VimgCommand {
  _CaptureCommand() {
    argParser
      ..addOption(
        'number',
        abbr: 'n',
        mandatory: true,
        help: 'Number of capture points.',
      )
      ..addOption(
        'ignore-start',
        defaultsTo: '0s',
        help: 'Duration or percentage to skip.',
      )
      ..addOption(
        'ignore-end',
        defaultsTo: '0s',
        help: 'Duration or percentage to skip.',
      )
      ..addOption(
        'capture-frames',
        abbr: 'f',
        help: 'Frames per capture point.',
      )
      ..addOption(
        'capture-time',
        abbr: 't',
        defaultsTo: '1500ms',
        help: 'Duration per capture.',
      )
      ..addOption(
        'output-dir',
        defaultsTo: '.',
        help: 'Directory for generated files.',
      );
  }

  CaptureOptions options(int defaultFrames) {
    final args = argResults!;
    return CaptureOptions(
      number: integer('number', min: 1)!,
      frames: integer('capture-frames', min: 1) ?? defaultFrames,
      start: VideoOffset.parse(args.option('ignore-start')!),
      end: VideoOffset.parse(args.option('ignore-end')!),
      window: parseSeconds(args.option('capture-time')!),
    );
  }
}

final class ExtractCommand extends _CaptureCommand {
  @override
  String get name => 'extract';
  @override
  String get description => 'Extract video frames as BMP images.';

  @override
  void run() =>
      extractFrames(video, argResults!.option('output-dir')!, options(1));
}

final class VcsCommand extends _CaptureCommand {
  VcsCommand() {
    argParser
      ..addOption(
        'columns',
        abbr: 'c',
        mandatory: true,
        help: 'Number of grid columns.',
      )
      ..addOption('capture-width', abbr: 'W', help: 'Tile width in pixels.')
      ..addOption('capture-height', abbr: 'H', help: 'Tile height in pixels.')
      ..addOption('output', abbr: 'o', help: 'Destination image.')
      ..addOption(
        'webp',
        defaultsTo: '0',
        help: 'Use WebP when set to a nonzero value.',
      )
      ..addOption('avif-fps', defaultsTo: '20', help: 'Playback frame rate.')
      ..addOption(
        'capture-backend',
        defaultsTo: 'auto',
        allowed: ['auto', 'dart'],
      )
      ..addFlag(
        'keep',
        negatable: false,
        help: 'Also write the captured BMP images.',
      )
      ..addFlag(
        'profile',
        negatable: false,
        help: 'Print phase timings to stderr.',
      );
  }

  @override
  String get name => 'vcs';
  @override
  String get description => 'Create a video contact sheet.';

  @override
  void run() {
    final args = argResults!;
    final input = video;
    final width = integer('capture-width', min: 1, max: 16384);
    final height = integer('capture-height', min: 1, max: 16384);
    if ((width == null) == (height == null)) {
      usageException('Provide one of --capture-width or --capture-height.');
    }
    final fps = double.tryParse(args.option('avif-fps')!);
    if (fps == null || !fps.isFinite || fps < 0.001 || fps > 1000) {
      usageException('--avif-fps must be between 0.001 and 1000.');
    }
    final directory = args.option('output-dir')!;
    final suffix = integer('webp', max: 255)! == 0 ? 'avif' : 'webp';
    final output =
        args.option('output') ??
        outputPath(directory, '${videoStem(input)}.$suffix');
    final lower = output.toLowerCase();
    final jpeg = lower.endsWith('.jpg') || lower.endsWith('.jpeg');
    final timings = args.flag('profile') ? _Timings() : null;
    writeContactSheet(
      input,
      output,
      options(jpeg ? 1 : 30),
      columns: integer('columns')!,
      width: width,
      height: height,
      fps: fps,
      captureDirectory: args.flag('keep') ? directory : null,
      mark: timings?.mark,
    );
    timings?.report('vimg-vcs-timing');
  }
}

final class _Timings {
  final _clock = Stopwatch()..start();
  final _stages = <List<Object>>[];
  var _last = 0;

  void mark(String stage) {
    final current = _clock.elapsedMicroseconds;
    _stages.add([stage, (current - _last) / 1000]);
    _last = current;
  }

  void report(String tag) => stderr.writeln(
    '$tag ${jsonEncode({'total_ms': _clock.elapsedMicroseconds / 1000, 'stages_ms': _stages})}',
  );
}

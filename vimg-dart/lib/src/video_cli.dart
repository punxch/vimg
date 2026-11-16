import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'authority.dart';
import 'avif_encoder.dart';
import 'capture.dart';
import 'video_commands.dart';
import 'yuv_image.dart';

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
        'vfilter',
        help:
            'Video filters include crop, scale, pad, drawbox, negate, hflip, '
            'vflip, transpose, setsar, setdar, trim, setpts, settb, fps, '
            'split, hstack, vstack, xstack, overlay and format.',
      )
      ..addOption(
        'threads',
        abbr: 'T',
        defaultsTo: '$defaultCaptureThreads',
        help: 'Maximum parallel capture decoders. 0 uses available CPUs.',
      )
      ..addOption(
        'output-dir',
        defaultsTo: '.',
        help: 'Directory for generated files.',
      );
  }

  VideoFilterChain? get filters {
    final source = argResults!.option('vfilter');
    return source == null ? null : VideoFilterChain.parse(source);
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
  Future<void> run() => extractFrames(
    video,
    argResults!.option('output-dir')!,
    options(1),
    threads: integer('threads')!,
    filters: filters,
  );
}

final class VcsCommand extends _CaptureCommand {
  VcsCommand({bool authority = false}) : _authority = authority {
    if (authority) {
      argParser.addOption(
        'manifest',
        mandatory: true,
        help: 'Destination JSON authority manifest.',
      );
    }
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
        help: 'Use WebP when nonzero, except for JPEG outputs.',
      )
      ..addOption('avif-fps', defaultsTo: '20', help: 'Playback frame rate.')
      ..addOption(
        'avif-crf',
        defaultsTo: '$defaultAvifCrf',
        help: 'AVIF quality from 0 (finest quantization) to 63.',
      )
      ..addOption(
        'avif-codec',
        defaultsTo: 'dart',
        allowed: ['dart', 'libsvtav1', 'libaom-av1'],
        help: 'AVIF encoder. The legacy names select the Dart encoder.',
      )
      ..addOption(
        'avif-preset',
        help:
            'AVIF search effort from 0 (most) to $maxAvifPreset (least). '
            'Defaults to $defaultAvifPreset.',
      )
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

  final bool _authority;

  @override
  String get name => _authority ? 'record' : 'vcs';
  @override
  String get description => _authority
      ? 'Write the Preview AVIF, source timestamps and visual reference frames.'
      : 'Create a video contact sheet.';

  @override
  Future<void> run() async {
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
    final webp = integer('webp', max: 255)!;
    final avifCrf = integer('avif-crf', max: 63)!;
    final avifPreset = integer('avif-preset', max: maxAvifPreset);
    final avifCodec = args.option('avif-codec');
    final threads = integer('threads')!;
    final suffix = webp == 0 ? 'avif' : 'webp';
    final output =
        args.option('output') ??
        outputPath(directory, '${videoStem(input)}.$suffix');
    final format = ContactSheetFormat.forPath(output, preferWebp: webp != 0);
    final timings = args.flag('profile') ? _Timings() : null;
    final capture = options(format == ContactSheetFormat.jpeg ? 1 : 30);
    final columns = integer('columns')!;
    final captures = args.flag('keep') ? directory : null;
    if (_authority) {
      if (args.option('output') == null || !output.endsWith('.avif')) {
        usageException(
          'Authority recording requires --output with an .avif extension.',
        );
      }
      if (columns != 3 ||
          height != 160 ||
          width != null ||
          capture.number != 9 ||
          capture.frames != 30 ||
          capture.window != 1.5 ||
          capture.start.value != 0 ||
          capture.end.value != 0 ||
          args.option('vfilter') != null ||
          fps != 20 ||
          avifCrf != defaultAvifCrf ||
          avifPreset != null ||
          avifCodec == 'libaom-av1' ||
          webp != 0) {
        usageException(
          'Authority recording requires the fixed Preview profile '
          '(-c3 -H160 -n9, 30 frames/1.5s, 20fps, no offsets or filters).',
        );
      }
      await recordAuthority(
        input,
        output,
        args.option('manifest')!,
        capture,
        columns: columns,
        height: height!,
        fps: fps,
        threads: threads,
        captureDirectory: captures,
        mark: timings?.mark,
      );
    } else {
      await writeContactSheet(
        input,
        output,
        capture,
        columns: columns,
        width: width,
        height: height,
        fps: fps,
        avifCrf: avifCrf,
        avifPreset: avifPreset,
        format: format,
        threads: threads,
        filters: filters,
        captureDirectory: captures,
        mark: timings?.mark,
      );
    }
    timings?.report('vimg-vcs-timing');
  }
}

final class AuthorityCommand extends Command<void> {
  AuthorityCommand() {
    addSubcommand(VcsCommand(authority: true));
    addSubcommand(_VerifyAuthority());
  }

  @override
  String get name => 'authority';
  @override
  String get description => 'Record or verify a video preview authority.';
}

final class _VerifyAuthority extends Command<void> {
  _VerifyAuthority() {
    argParser.addOption(
      'min-ssim',
      defaultsTo: '0.999',
      help: 'Minimum SSIM for every frame.',
    );
  }

  @override
  String get name => 'verify';
  @override
  String get description => 'Compare two AVIF animations frame by frame.';

  @override
  void run() {
    final args = argResults!;
    final paths = args.rest;
    if (paths.length != 2)
      usageException('Provide a reference and a candidate AVIF.');
    final minimum = double.tryParse(args.option('min-ssim')!);
    if (minimum == null) usageException('--min-ssim must be a number.');
    verifyAuthority(paths[0], paths[1], minimum);
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

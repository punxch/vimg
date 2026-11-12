import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:image/image.dart' as image;

import 'grid.dart';
import 'output.dart';
import 'probe.dart';

CommandRunner<void> createRunner() =>
    CommandRunner<void>('vimg', 'Generate contact sheets and video previews.')
      ..argParser.addFlag('version', negatable: false)
      ..addCommand(_Probe())
      ..addCommand(_Join());

Future<void> runCli(List<String> arguments) async {
  final runner = createRunner();
  try {
    final result = runner.parse(arguments);
    if (result.flag('version')) {
      stdout.writeln('vimg-dart 0.1.0');
      return;
    }
    await runner.runCommand(result);
  } on UsageException catch (error) {
    stderr.writeln(error);
    exitCode = 64;
  } on FormatException catch (error) {
    stderr.writeln('vimg: ${error.message}');
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln('vimg: $error');
    exitCode = 1;
  }
}

final class _Probe extends Command<void> {
  @override
  String get name => 'probe';
  @override
  String get description => 'Print video metadata as JSON.';

  @override
  void run() {
    final paths = argResults!.rest;
    if (paths.length != 1) usageException('Provide exactly one video path.');
    stdout.writeln(jsonEncode(probe(paths.single).toJson()));
  }
}

final class _Join extends Command<void> {
  _Join() {
    argParser
      ..addOption(
        'columns',
        abbr: 'c',
        mandatory: true,
        help: 'Number of columns. 0 uses one row.',
      )
      ..addOption('capture-width', abbr: 'W', help: 'Maximum tile width.')
      ..addOption('capture-height', abbr: 'H', help: 'Maximum tile height.')
      ..addOption('output', abbr: 'o', mandatory: true, help: 'Output image.')
      ..addMultiOption(
        'label',
        splitCommas: false,
        help: 'Label for the next tile.',
      );
  }

  @override
  String get name => 'join';
  @override
  String get description => 'Join images into a grid.';

  int? dimension(String name, int minimum) {
    final value = argResults!.option(name);
    if (value == null) return null;
    final number = int.tryParse(value);
    if (number == null || number < minimum) {
      usageException('--$name must be an integer >= $minimum.');
    }
    return number;
  }

  @override
  void run() {
    final arguments = argResults!;
    if (arguments.rest.isEmpty) usageException('Provide at least one image.');
    final columns = dimension('columns', 0)!;
    final width = dimension('capture-width', 1);
    final height = dimension('capture-height', 1);
    final output = arguments.option('output')!;
    final encoder = image.findEncoderForNamedImage(output);
    if (encoder == null) {
      throw FormatException('Unsupported output image format: $output');
    }
    final frames = <image.Image>[];
    for (final path in arguments.rest) {
      final decoded = image.decodeImage(File(path).readAsBytesSync());
      if (decoded == null)
        throw FormatException('Unsupported input image: $path');
      frames.add(
        resizeToFit(
          decoded.convert(format: image.Format.uint8, numChannels: 3),
          width: width,
          height: height,
        ),
      );
    }
    publishBytes(
      output,
      encoder.encode(
        composeGrid(frames, columns, arguments.multiOption('label')),
      ),
    );
  }
}

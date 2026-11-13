import 'dart:convert';
import 'dart:io';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  final executable = arguments.firstOrNull ?? Platform.resolvedExecutable;
  Future<String> run(List<String> args) async {
    final result = await Process.run(executable, [
      if (arguments.isEmpty) 'bin/vimg.dart',
      ...args,
    ]);
    check(result.exitCode == 0, '$args: ${result.stderr}');
    return result.stdout as String;
  }

  for (final (input, expected) in <(List<String>, List<String>)>[
    (['.au'], ['words', 'authority']),
    (['.', '--version', 'authority'], ['words', 'record', 'verify']),
    (['.--m', 'authority', 'record'], ['words', '--manifest']),
    (['.--min', 'authority', 'verify', 'record'], ['words', '--min-ssim']),
    (['.re', 'help', 'authority'], ['words', 'record']),
    (['.--ver', 'authority', 'verify'], ['words', '--version']),
    (['.lib', 'vcs', '--avif-codec'], ['words', 'libsvtav1', 'libaom-av1']),
    (['.--avif-codec=liba', 'vcs'], ['words', '--avif-codec=libaom-av1']),
    (
      ['.d', 'vcs', '--capture-backend=auto', '--avif-codec'],
      ['words', 'dart'],
    ),
    (['.c', 'serve', '--cpu-policy'], ['words']),
    (['.--p', 'vcs', '-c3', 'input file.mkv'], ['words', '--profile']),
    (['.', 'vcs', '-o', 'authority', '--avif-crf'], ['words']),
    (['.--pr', 'vcs', '--'], ['files:']),
    (['.a', 'probe'], ['files:']),
    (['.a', 'vcs', '--output'], ['files:']),
    (['.--manifest=dir/a', 'authority', 'record'], ['files:--manifest=']),
    (['.-odir/a', 'vcs'], ['files:-o']),
    (['.p', 'print-completions'], ['words', 'powershell']),
    (['.', 'print-completions', 'bash'], ['words']),
    (['.', 'serve'], ['words']),
  ]) {
    final output = const LineSplitter().convert(
      await run(['__complete', ...input]),
    );
    check(
      output.join('\n') == expected.join('\n'),
      'Completion for $input was $output',
    );
  }

  for (final shell in ['bash', 'zsh', 'fish', 'powershell', 'elvish']) {
    final script = await run(['print-completions', shell]);
    check(script.contains('__complete'), '$shell uses the command grammar');
  }
  check(
    await run(['print-completions']) ==
        await run(['print-completions', 'bash']),
    'Bash is the default completion script',
  );

  if (arguments.isNotEmpty &&
      !Platform.isWindows &&
      File('/bin/bash').existsSync()) {
    final temp = Directory.systemTemp.createTempSync('vimg-completions-');
    try {
      File(
        '${temp.path}/completion.bash',
      ).writeAsStringSync(await run(['print-completions', 'bash']));
      File('${temp.path}/cache example.avif').createSync();
      final result = await Process.run('/bin/bash', [
        '--noprofile',
        '--norc',
        '-c',
        _bashCheck,
        'completion-test',
        '${temp.path}/completion.bash',
        File(executable).absolute.path,
      ], workingDirectory: temp.path);
      check(
        result.exitCode == 0,
        'Bash completion: ${result.stdout}${result.stderr}',
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
  }
}

const _bashCheck = r'''
set -e
source "$1"
check() {
  local expected="$1" seed="$2"
  shift 2
  COMP_WORDS=("$exe" "$@")
  COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
  _vimg_complete "$exe" "$seed"
  local actual
  actual=$(printf '%s\n' "${COMPREPLY[@]}")
  if [[ $actual != "$expected" ]]; then
    printf 'expected <%s>, received <%s> for %s\n' "$expected" "$actual" "$*"
    exit 1
  fi
}
exe="$2"
check record rec authority rec
check libsvtav1 libsv vcs --avif-codec = libsv
check libsvtav1 libsv vcs --avif-codec=libsv
check '--avif-codec=dart' '--avif-codec=da' vcs --avif-codec=da
check 'cache example.avif' 'cache e' vcs --output = 'cache e'
check '--manifest' --m authority record --m
check '' '' vcs --avif-crf ''
''';

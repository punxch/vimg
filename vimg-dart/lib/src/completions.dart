import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

final class PrintCompletionsCommand extends Command<void> {
  @override
  String get name => 'print-completions';
  @override
  String get description => 'Print shell completions for vimg.';

  @override
  void run() {
    final arguments = argResults!.rest;
    if (arguments.length > 1) usageException('Provide at most one shell name.');
    final shell = arguments.firstOrNull ?? 'bash';
    final commands = {
      for (final command in runner!.commands.entries)
        command.key: _options(command.value.argParser),
    };
    final root = [...commands.keys, ..._options(runner!.argParser)].join(' ');
    final script = switch (shell) {
      'bash' => _bash(root, commands),
      'zsh' => _zsh(root, commands),
      'fish' => _fish(commands.keys, runner!.argParser),
      'powershell' => _powershell(root, commands),
      'elvish' => _elvish(root, commands),
      _ => usageException('Choose bash, zsh, fish, powershell or elvish.'),
    };
    stdout.write(script);
  }
}

List<String> _options(ArgParser parser) => [
  for (final option in parser.options.values.where(
    (option) => !option.hide,
  )) ...['--${option.name}', if (option.abbr case final abbr?) '-$abbr'],
];

String _bash(String root, Map<String, List<String>> commands) {
  final cases = commands.entries
      .map(
        (entry) =>
            "      ${entry.key}) choices='${entry.value.join(' ')}'; break ;;",
      )
      .join('\n');
  return '''
_vimg_complete() {
  local choices='$root' word
  local index
  for ((index=1; index<COMP_CWORD; index++)); do
    word="${r'${COMP_WORDS[index]}'}"
    case "\$word" in
      --) return ;;
$cases
    esac
  done
  local suggestion
  COMPREPLY=()
  while IFS= read -r suggestion; do
    COMPREPLY+=("\$suggestion")
  done < <(compgen -W "\$choices" -- "${r'${COMP_WORDS[COMP_CWORD]}'}")
}
complete -o default -F _vimg_complete vimg
''';
}

String _zsh(String root, Map<String, List<String>> commands) {
  final cases = commands.entries
      .map(
        (entry) =>
            '      ${entry.key}) choices=(${entry.value.join(' ')}); break ;;',
      )
      .join('\n');
  return '''
#compdef vimg

local -a choices
local index
choices=($root)
for ((index=2; index<CURRENT; index++)); do
  case "${r'${words[index]}'}" in
    --) _files; return ;;
$cases
  esac
done
compadd -a choices || _files
''';
}

String _fish(Iterable<String> commands, ArgParser parser) {
  const root = '__fish_use_subcommand';
  final out = StringBuffer()
    ..writeln("complete -c vimg -n '$root' -a '${commands.join(' ')}'");
  void flags(ArgParser context, String condition) {
    for (final option in context.options.values.where(
      (option) => !option.hide,
    )) {
      out.write("complete -c vimg -n '$condition' -l ${option.name}");
      if (option.abbr case final abbr?) out.write(' -s $abbr');
      if (!option.isFlag) out.write(' -r');
      if (option.allowed case final values?)
        out.write(" -a '${values.join(' ')}'");
      out.writeln();
    }
  }

  flags(parser, root);
  for (final command in commands) {
    flags(parser.commands[command]!, '__fish_seen_subcommand_from $command');
  }
  return out.toString();
}

String _powershell(String root, Map<String, List<String>> commands) {
  final cases = commands.entries
      .map((entry) => "        '${entry.key}' { '${entry.value.join(' ')}' }")
      .join('\n');
  return '''
Register-ArgumentCompleter -Native -CommandName 'vimg', 'vimg.exe' -ScriptBlock {
    param(\$wordToComplete, \$commandAst, \$cursorPosition)
    \$command = \$commandAst.CommandElements[1]
    \$words = if (\$command -and \$command.Extent.EndOffset -lt \$cursorPosition) {
        switch (\$command.Value) {
$cases
            default { '$root' }
        }
    } else { '$root' }
    foreach (\$word in \$words.Split(' ')) {
        if (\$word.StartsWith(\$wordToComplete, [StringComparison]::OrdinalIgnoreCase)) {
            [System.Management.Automation.CompletionResult]::new(\$word, \$word, 'ParameterValue', \$word)
        }
    }
}
''';
}

String _elvish(String root, Map<String, List<String>> commands) {
  final rows = commands.entries
      .map(
        (entry) =>
            "    &${entry.key}=[${entry.value.map((option) => "'$option'").join(' ')}]",
      )
      .join('\n');
  final initial = root.split(' ').map((word) => "'\$word'").join(' ');
  return '''
set edit:completion:arg-completer[vimg] = {|@words|
  var commands = [
$rows
  ]
  if (and (> (count \$words) 2) (has-key \$commands \$words[1])) {
    var candidates = \$commands[\$words[1]]
    put \$@candidates
  } else {
    put $initial
  }
}
''';
}

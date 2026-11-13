import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

const completionQuery = '__complete';
const _shells = ['bash', 'zsh', 'fish', 'powershell', 'elvish'];

final class PrintCompletionsCommand extends Command<void> {
  @override
  String get name => 'print-completions';
  @override
  String get description => 'Print shell completions for vimg.';

  @override
  void run() {
    final arguments = argResults!.rest;
    if (arguments.length > 1) usageException('Provide at most one shell name.');
    final script = switch (arguments.firstOrNull ?? 'bash') {
      'bash' => _bash,
      'zsh' => _zsh,
      'fish' => _fish,
      'powershell' => _powershell,
      'elvish' => _elvish,
      _ => usageException('Choose bash, zsh, fish, powershell or elvish.'),
    };
    stdout.write(script);
  }
}

/// Query the same argument grammar that runs commands. The first line is
/// "words" for literal candidates or "files:<prefix>" for shell path completion.
/// The first argument is the current word, which is encoded with a leading
/// dot so a shell can pass an empty word even with legacy argument passing.
void completeArguments(ArgParser root, List<String> words) {
  if (words.isEmpty || !words.first.startsWith('.')) return;
  final context = _Completion(root);
  for (final word in words.skip(1)) {
    context.accept(word);
  }
  final result = context.suggest(words.first.substring(1));
  stdout.writeln(result);
}

const _pathOptions = {'output', 'output-dir', 'manifest', 'ya'};

final class _Completion {
  _Completion(this.root) : _parsers = [root];

  final ArgParser root;
  final List<ArgParser> _parsers;
  Option? _pending;
  String? _command;
  ArgParser? _helpTarget;
  var _endOfOptions = false, _hasPositional = false;

  ArgParser get _current => _parsers.last;

  Option? _option(String name) {
    for (final parser in _parsers.reversed) {
      for (final option in parser.options.values) {
        if ((option.abbr != null && name == '-${option.abbr}') ||
            name == '--${option.name}' ||
            (option.negatable == true && name == '--no-${option.name}') ||
            option.aliases.any((alias) => name == '--$alias')) {
          return option;
        }
      }
    }
    return null;
  }

  ({String name, String value})? _attached(String word) {
    if (word.startsWith('--')) {
      final equal = word.indexOf('=');
      if (equal < 0) return null;
      return (name: word.substring(0, equal), value: word.substring(equal + 1));
    }
    if (word.startsWith('-') && word.length > 2) {
      return (name: word.substring(0, 2), value: word.substring(2));
    }
    return null;
  }

  void accept(String word) {
    if (_pending != null) {
      _pending = null;
      return;
    }
    if (!_endOfOptions && word == '--') {
      _endOfOptions = true;
      return;
    }
    if (!_endOfOptions && word.startsWith('-') && word.length > 1) {
      final option = _option(word);
      if (option != null && !option.isFlag) _pending = option;
      return;
    }
    if (!_endOfOptions && _command == 'help') {
      _helpTarget = _helpTarget?.commands[word];
      return;
    }
    final child = _hasPositional || _endOfOptions
        ? null
        : _current.commands[word];
    if (child == null) {
      _hasPositional = true;
    } else {
      _command = word;
      _parsers.add(child);
      if (word == 'help') _helpTarget = root;
    }
  }

  String suggest(String current) {
    if (_pending case final option?) return _value(option, current);
    if (!_endOfOptions && current.startsWith('-')) {
      final attached = _attached(current);
      final option = attached == null ? null : _option(attached.name);
      if (attached != null && option != null && !option.isFlag) {
        final prefix = current.substring(
          0,
          current.length - attached.value.length,
        );
        return _value(option, attached.value, prefix: prefix);
      }
      return _words(current, {
        for (final parser in _parsers)
          for (final option in parser.options.values)
            if (!option.hide) ...[
              '--${option.name}',
              if (option.abbr case final abbr?) '-$abbr',
              if (option.negatable == true && option.hideNegatedUsage != true)
                '--no-${option.name}',
            ],
      });
    }

    if (_command == 'help') {
      return _words(current, _helpTarget?.commands.keys ?? const []);
    }
    if (_command == 'print-completions') {
      return _words(current, _hasPositional ? const [] : _shells);
    }
    if (_current.commands.isNotEmpty) {
      return _words(
        current,
        _hasPositional || _endOfOptions ? const [] : _current.commands.keys,
      );
    }
    return _command == 'serve' || _command == 'help' ? 'words' : 'files:';
  }

  String _value(Option option, String current, {String prefix = ''}) =>
      switch (option.allowed) {
        final values? => _words(current, values, prefix: prefix),
        _ when _pathOptions.contains(option.name) => 'files:$prefix',
        _ => 'words',
      };

  String _words(
    String current,
    Iterable<String> candidates, {
    String prefix = '',
  }) => [
    'words',
    for (final candidate in candidates)
      if (candidate.startsWith(current)) '$prefix$candidate',
  ].join('\n');
}

const _bash = r'''
_vimg_complete() {
  local -a args
  local index word last current left='' mode candidate prefix
  COMPREPLY=()
  for ((index=1; index<=COMP_CWORD; index++)); do
    word="${COMP_WORDS[index]}"
    # Readline may split --option=value at the equals sign.
    last=$((${#args[@]} - 1))
    if [[ $word == = && $last -ge 0 && ${args[last]} == --* &&
          ${args[last]} != *=* ]]; then
      args[last]+='='
      if (( index < COMP_CWORD )); then
        ((index++))
        args[last]+="${COMP_WORDS[index]}"
      fi
    else
      args+=("$word")
    fi
  done
  last=$((${#args[@]} - 1))
  current="${args[last]}"
  unset 'args[last]'
  # Bash 3 can keep --option=value in COMP_WORDS while replacing only $2.
  if [[ $current == --*=* && $current == *"$2" ]]; then
    left="${current%"$2"}"
  fi
  {
    IFS= read -r mode || return
    if [[ $mode == files:* ]]; then
      prefix="${mode#files:}"
      while IFS= read -r candidate; do
        candidate="$prefix$candidate"
        COMPREPLY+=("${candidate#"$left"}")
      done < <(compgen -f -- "${current#"$prefix"}")
    else
      while IFS= read -r candidate; do
        COMPREPLY+=("${candidate#"$left"}")
      done
    fi
  } < <(command "${COMP_WORDS[0]}" __complete ".$current" "${args[@]}")
}
complete -o filenames -F _vimg_complete vimg vimg.exe
''';

const _zsh = r'''
#compdef vimg vimg.exe

local -a result
local mode prefix
result=("${(@f)$(command "$words[1]" __complete ".$words[CURRENT]" "${(@)words[2,CURRENT-1]}")}")
mode=$result[1]
if [[ $mode == files:* ]]; then
  prefix=${mode#files:}
  if [[ -n $prefix ]]; then
    compset -p ${#prefix} || return
  fi
  _files
elif (( ${#result} > 1 )); then
  compadd -Q -- "${(@)result[2,-1]}"
fi
''';

const _fish = r'''
function __vimg_complete
    set -l words (commandline -opc)
    set -l current (commandline -ct)
    if not set -q current[1]
        set current ''
    end
    set -l result (command $words[1] __complete ".$current" $words[2..-1])
    if not set -q result[1]
        return
    end
    switch $result[1]
        case 'files:*'
            set -l prefix (string replace 'files:' '' -- $result[1])
            if test -z "$prefix"
                __fish_complete_path "$current"
            else
                set -l tail (string sub -s (math (string length -- "$prefix") + 1) -- "$current")
                for path in (__fish_complete_path "$tail")
                    printf '%s%s\n' "$prefix" "$path"
                end
            end
        case words
            printf '%s\n' $result[2..-1]
    end
end
complete -c vimg -c vimg.exe -f -a '(__vimg_complete)'
''';

const _powershell = r'''
Register-ArgumentCompleter -Native -CommandName 'vimg', 'vimg.exe' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    $elements = $commandAst.CommandElements
    $arguments = @(
        foreach ($element in $elements | Select-Object -Skip 1) {
            if ($element.Extent.EndOffset -ge $cursorPosition) { break }
            if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $element.Value
            } else {
                $element.Extent.Text
            }
        }
    )
    $current = $wordToComplete
    $last = $elements[$elements.Count - 1]
    if ($elements.Count -gt 1 -and $last.Extent.EndOffset -eq $cursorPosition -and
        $last -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $current = $last.Value
    } elseif ($current.StartsWith("'") -or $current.StartsWith('"')) {
        $current = $current.Substring(1)
    }
    $result = @(& $elements[0].Value __complete ('.' + $current) @arguments)
    if ($result.Count -eq 0) { return }
    if ($result[0].StartsWith('files:')) {
        $prefix = $result[0].Substring(6)
        $tail = $current.Substring($prefix.Length)
        foreach ($match in [System.Management.Automation.CompletionCompleters]::CompleteFilename($tail)) {
            $text = $prefix + $match.CompletionText
            [System.Management.Automation.CompletionResult]::new(
                $text, $match.ListItemText, $match.ResultType, $match.ToolTip)
        }
    } else {
        foreach ($word in $result | Select-Object -Skip 1) {
            [System.Management.Automation.CompletionResult]::new(
                $word, $word, 'ParameterValue', $word)
        }
    }
}
''';

const _elvish = r'''
use str
set edit:completion:arg-completer[vimg] = {|@words|
  var command = (external $words[0])
  var previous = $words[1..-1]
  var result = [($command __complete .$words[-1] $@previous | from-lines)]
  if (> (count $result) 0) {
    if (str:has-prefix $result[0] files:) {
      var prefix = (str:trim-prefix $result[0] files:)
      if (eq $prefix '') {
        edit:complete-filename $words[-1]
      } else {
        var tail = (str:trim-prefix $words[-1] $prefix)
        edit:complete-filename $tail | each {|candidate|
          put (edit:complex-candidate $prefix$candidate[stem] &code-suffix=$candidate[code-suffix])
        }
      }
    } else {
      var candidates = $result[1..]
      put $@candidates
    }
  }
}
set edit:completion:arg-completer[vimg.exe] = $edit:completion:arg-completer[vimg]
''';

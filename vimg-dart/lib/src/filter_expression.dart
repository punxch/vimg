import 'dart:math' as math;

typedef FilterExpression = double Function(Map<String, double> variables);

FilterExpression parseFilterExpression(
  String source,
  Set<String> variables, {
  void Function(String)? onVariable,
}) => _Parser(source, variables, onVariable).parse();

final class _Parser {
  _Parser(this.source, this.variables, this.onVariable);

  final String source;
  final Set<String> variables;
  final void Function(String)? onVariable;
  var _offset = 0;
  static final _number = RegExp(r'(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?');
  static final _name = RegExp(r'[a-zA-Z_][a-zA-Z_0-9]*');
  static final _whitespace = RegExp(r'\s+');

  FilterExpression parse() {
    final value = _sum(0);
    _skipSpace();
    if (_offset != source.length) _fail();
    return value;
  }

  FilterExpression _sum(int depth) {
    var value = _product(depth);
    while (true) {
      final left = value;
      if (_take('+')) {
        final right = _product(depth);
        value = (v) => left(v) + right(v);
      } else if (_take('-')) {
        final right = _product(depth);
        value = (v) => left(v) - right(v);
      } else {
        return value;
      }
    }
  }

  FilterExpression _product(int depth) {
    var value = _factor(depth);
    while (true) {
      final left = value;
      if (_take('*')) {
        final right = _factor(depth);
        value = (v) => left(v) * right(v);
      } else if (_take('/')) {
        final right = _factor(depth);
        value = (v) => left(v) / right(v);
      } else {
        return value;
      }
    }
  }

  FilterExpression _factor(int depth) {
    if (depth > 64) _fail();
    final negative = _take('-');
    if (!negative) _take('+');
    var value = _primary(depth);
    while (_take('^')) {
      final base = value;
      final minus = _take('-');
      if (!minus) _take('+');
      final exponent = _primary(depth);
      value = (v) =>
          math.pow(base(v), minus ? -exponent(v) : exponent(v)).toDouble();
    }
    final unsigned = value;
    return negative ? (v) => -unsigned(v) : value;
  }

  FilterExpression _primary(int depth) {
    if (_take('(')) {
      final value = _sum(depth + 1);
      if (!_take(')')) _fail();
      return value;
    }
    final number = _match(_number);
    if (number != null) {
      final value = double.parse(number);
      return (_) => value;
    }
    final name = _match(_name);
    if (name == null) _fail();
    if (!_take('(')) {
      if (variables.contains(name)) {
        onVariable?.call(name);
        return (v) => v[name] ?? double.nan;
      }
      return switch (name) {
        'PI' => (_) => math.pi,
        'E' => (_) => math.e,
        'PHI' => (_) => (1 + math.sqrt(5)) / 2,
        'NAN' => (_) => double.nan,
        'INF' => (_) => double.infinity,
        _ => throw FormatException('Unsupported video filter variable: $name'),
      };
    }
    final first = _sum(depth + 1);
    final second = _take(',') ? _sum(depth + 1) : null;
    final third = second != null && _take(',') ? _sum(depth + 1) : null;
    if (!_take(')')) _fail();
    if (third != null) {
      final middle = second!;
      return switch (name) {
        'if' => (v) => first(v) != 0 ? middle(v) : third(v),
        'ifnot' => (v) => first(v) == 0 ? middle(v) : third(v),
        'between' => (v) => _boolean(
          first(v) >= middle(v) && first(v) <= third(v),
        ),
        'clip' => (v) {
          final low = middle(v), high = third(v), value = first(v);
          return low.isNaN || high.isNaN || value.isNaN || low > high
              ? double.nan
              : value.clamp(low, high);
        },
        _ => throw FormatException('Unsupported video filter function: $name'),
      };
    }
    if (second != null) {
      return switch (name) {
        'min' => (v) => math.min(first(v), second(v)),
        'max' => (v) => math.max(first(v), second(v)),
        'mod' =>
          (v) =>
              first(v) -
              second(v) * _integer(first(v) / second(v), (x) => x.floor()),
        'pow' => (v) => math.pow(first(v), second(v)).toDouble(),
        'if' => (v) => first(v) != 0 ? second(v) : 0,
        'ifnot' => (v) => first(v) == 0 ? second(v) : 0,
        'eq' => (v) => _boolean(first(v) == second(v)),
        'lt' => (v) => _boolean(first(v) < second(v)),
        'lte' => (v) => _boolean(first(v) <= second(v)),
        'gt' => (v) => _boolean(first(v) > second(v)),
        'gte' => (v) => _boolean(first(v) >= second(v)),
        _ => throw FormatException('Unsupported video filter function: $name'),
      };
    }
    return switch (name) {
      'abs' => (v) => first(v).abs(),
      'ceil' => (v) => _integer(first(v), (x) => x.ceil()),
      'floor' => (v) => _integer(first(v), (x) => x.floor()),
      'round' => (v) => _integer(first(v), (x) => x.round()),
      'trunc' => (v) => _integer(first(v), (x) => x.truncate()),
      'sqrt' => (v) => math.sqrt(first(v)),
      'sin' => (v) => math.sin(first(v)),
      'cos' => (v) => math.cos(first(v)),
      'tan' => (v) => math.tan(first(v)),
      'log' => (v) => math.log(first(v)),
      'exp' => (v) => math.exp(first(v)),
      'isnan' => (v) => _boolean(first(v).isNaN),
      'isinf' => (v) => _boolean(first(v).isInfinite),
      'not' => (v) => _boolean(first(v) == 0),
      _ => throw FormatException('Unsupported video filter function: $name'),
    };
  }

  double _integer(double value, int Function(double) round) =>
      value.isFinite ? round(value).toDouble() : value;

  double _boolean(bool value) => value ? 1 : 0;

  String? _match(RegExp pattern) {
    _skipSpace();
    final match = pattern.matchAsPrefix(source, _offset);
    if (match == null) return null;
    _offset = match.end;
    return match[0];
  }

  bool _take(String token) {
    _skipSpace();
    if (!source.startsWith(token, _offset)) return false;
    _offset += token.length;
    return true;
  }

  void _skipSpace() {
    _offset = _whitespace.matchAsPrefix(source, _offset)?.end ?? _offset;
  }

  Never _fail() =>
      throw FormatException('Invalid video filter expression', source, _offset);
}

import 'coefficients.dart';
import 'range_decoder.dart';

/// Probability state shared by the syntax readers of a single tile.
/// Loading a reference keeps the probabilities and resets symbol counts.
final class Av1EntropyContext {
  Av1EntropyContext(int baseQ)
    : coefficients = Av1CoefficientCdfs(baseQ),
      _syntax = {};

  Av1EntropyContext._(this.coefficients, this._syntax);

  final Av1CoefficientCdfs coefficients;
  final Map<Object, Av1Cdf> _syntax;

  Av1Cdf cdf(Object key, List<int> initial) =>
      _syntax.putIfAbsent(key, () => Av1Cdf(initial));

  Av1EntropyContext copy({bool resetCount = false}) =>
      Av1EntropyContext._(coefficients.copy(resetCount: resetCount), {
        for (final entry in _syntax.entries)
          entry.key: entry.value.copy(resetCount: resetCount),
      });
}

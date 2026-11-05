/// User-selectable app-wide text size. The [scale] multiplies every font
/// size via a `MediaQuery.textScaler` override at the app root, so it
/// affects all text (including the hardcoded `fontSize:` values and the
/// mono styles) uniformly. `medium` (1.0) is the design baseline.
enum TextSize {
  small(0.85),
  medium(1.0),
  large(1.20);

  const TextSize(this.scale);

  /// Multiplier applied to every font size.
  final double scale;

  String get label {
    switch (this) {
      case TextSize.small:
        return 'Small';
      case TextSize.medium:
        return 'Medium';
      case TextSize.large:
        return 'Large';
    }
  }

  static TextSize fromName(String? name) {
    return TextSize.values.firstWhere(
      (s) => s.name == name,
      orElse: () => TextSize.medium,
    );
  }
}

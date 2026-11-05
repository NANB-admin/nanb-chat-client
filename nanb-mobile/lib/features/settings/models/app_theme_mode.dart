/// User-selectable theme mode. `system` follows the OS setting.
enum AppThemeMode {
  system,
  light,
  dark;

  static AppThemeMode fromName(String? name) {
    return AppThemeMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => AppThemeMode.system,
    );
  }
}

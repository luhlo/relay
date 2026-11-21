import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device appearance is separate from household timer records and widget colors.
class RelayThemeController extends ChangeNotifier {
  RelayThemeController();

  static final instance = RelayThemeController();
  static const preferenceKey = 'relay.appearance.theme.v1';

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;
  SharedPreferences? _preferences;
  Future<void>? _loading;

  Future<void> load() async {
    try {
      await (_loading ??= _read());
    } catch (_) {
      // A temporary browser/device storage failure can be retried in Settings.
      _loading = null;
      rethrow;
    }
  }

  Future<void> _read() async {
    _preferences = await SharedPreferences.getInstance();
    final saved = _preferences!.get(preferenceKey);
    final next = ThemeMode.values.firstWhere(
      (mode) => mode.name == saved,
      orElse: () => ThemeMode.system,
    );
    if (_mode != next) {
      _mode = next;
      notifyListeners();
    }
  }

  Future<void> setMode(ThemeMode next) async {
    await load();
    if (_mode == next) return;
    if (!await _preferences!.setString(preferenceKey, next.name)) {
      throw StateError('Could not save the appearance setting.');
    }
    _mode = next;
    notifyListeners();
  }
}

ThemeData relayTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF6450CA),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xFFC4B6FF) : const Color(0xFF6450CA),
        onPrimary: dark ? const Color(0xFF251A46) : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF3A3154)
            : const Color(0xFFEEEBFC),
        onPrimaryContainer: dark
            ? const Color(0xFFE9DFFF)
            : const Color(0xFF49359F),
        surface: dark ? const Color(0xFF17171D) : const Color(0xFFF7F7F2),
        onSurface: dark ? const Color(0xFFF1EEF6) : const Color(0xFF24232C),
        onSurfaceVariant: dark
            ? const Color(0xFFC5BFCE)
            : const Color(0xFF6D6B76),
        surfaceContainerLowest: dark ? const Color(0xFF141419) : Colors.white,
        surfaceContainerLow: dark ? const Color(0xFF212128) : Colors.white,
        surfaceContainer: dark
            ? const Color(0xFF292830)
            : const Color(0xFFEEEFE6),
        surfaceContainerHigh: dark
            ? const Color(0xFF32313B)
            : const Color(0xFFECEBF1),
        outline: dark ? const Color(0xFF9A93A5) : const Color(0xFF7C7789),
        outlineVariant: dark
            ? const Color(0xFF48434F)
            : const Color(0xFFE3E0E9),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Manrope',
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    dividerColor: scheme.outlineVariant,
    textTheme: TextTheme(
      bodyMedium: TextStyle(color: scheme.onSurface, fontSize: 14),
      bodyLarge: TextStyle(color: scheme.onSurface),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primaryContainer,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

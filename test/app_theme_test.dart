import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/app_theme.dart';
import 'package:relay/main.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ThemeStore extends RelayStore {
  _ThemeStore(this.state);
  final RelayState state;

  @override
  Future<RelayState> load() async => state;
}

double _contrast(Color first, Color second) {
  final a = first.computeLuminance(), b = second.computeLuminance();
  return (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('appearance defaults to system and restores a saved choice', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = RelayThemeController();
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.mode, ThemeMode.system);

    var notifications = 0;
    controller.addListener(() => notifications++);
    await controller.setMode(ThemeMode.dark);
    expect(controller.mode, ThemeMode.dark);
    expect(notifications, 1);

    final restored = RelayThemeController();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.mode, ThemeMode.dark);
    await restored.setMode(ThemeMode.light);
    expect(restored.mode, ThemeMode.light);
    await restored.setMode(ThemeMode.system);
    expect(restored.mode, ThemeMode.system);

    final finalRead = RelayThemeController();
    addTearDown(finalRead.dispose);
    await finalRead.load();
    expect(finalRead.mode, ThemeMode.system);
  });

  test('unknown saved appearance safely follows the system', () async {
    SharedPreferences.setMockInitialValues({
      RelayThemeController.preferenceKey: 'future-theme',
    });
    final controller = RelayThemeController();
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.mode, ThemeMode.system);
  });

  for (final brightness in Brightness.values) {
    test('${brightness.name} text stays readable on app surfaces', () {
      final colors = relayTheme(brightness).colorScheme;
      for (final surface in [colors.surface, colors.surfaceContainerLow]) {
        expect(_contrast(colors.onSurface, surface), greaterThanOrEqualTo(7));
        expect(
          _contrast(colors.onSurfaceVariant, surface),
          greaterThanOrEqualTo(4.5),
        );
      }
      expect(
        _contrast(colors.primary, colors.primaryContainer),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets(
      '${brightness.name} Baby Time keeps dark text on the green timer',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = RelayState()
          ..start(ShiftKind.point, DateTime.now(), baby: Baby.chloe);
        await tester.pumpWidget(
          MaterialApp(
            theme: relayTheme(brightness),
            home: RelayHome(store: _ThemeStore(state)),
          ),
        );
        await tester.pumpAndSettle();

        final description = tester.widget<Text>(
          find.text('Taking care of Baby 1. Be here, fully.'),
        );
        final text = description.style!.color!;
        expect(
          _contrast(text, const Color(0xFFDDEAAD)),
          greaterThanOrEqualTo(4.5),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

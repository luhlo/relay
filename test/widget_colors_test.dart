import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/model.dart';

void main() {
  const legacyDefaults = {
    'work': 0xFF6450CA,
    'baby': 0xFFDDEAAD,
    'interruption': 0xFFF3C879,
    'resume': 0xFF2762B2,
    'end': 0xFF6450CA,
  };

  test('widget defaults use the app palette with separate timer and end', () {
    const colors = WidgetColors();
    expect(colors.work, 0xFF6450CA);
    expect(colors.resume, colors.work);
    expect(colors.baby, 0xFFDDEAAD);
    expect(colors.end, colors.baby);
    expect(colors.changeBaby, colors.work);
    expect(colors.changeBaby, isNot(colors.end));
    expect(colors.interruption, 0xFFFFCC33);
    expect(colors.timer, 0xFFEEEBFC);
    expect(colors.timer, isNot(colors.work));
    expect(colors.foregroundFor('work'), 0xFFFFFFFF);
    expect(colors.foregroundFor('baby'), 0xFF24232C);
    expect(colors.foregroundFor('interruption'), 0xFF24232C);
  });

  test('all part backgrounds and text overrides survive saved-state JSON', () {
    var colors = const WidgetColors();
    for (var i = 0; i < WidgetColors.backgroundRoles.length; i++) {
      final role = WidgetColors.backgroundRoles[i];
      colors = colors.withBackground(role, 0xFF123400 + i);
      if (i.isEven) colors = colors.withText(role, 0xFFEDCB00 + i);
    }
    final original = RelayState(widgetColors: colors);
    final decoded = jsonDecode(jsonEncode(original.toJson()));
    final restored = RelayState.fromJson(Map<String, dynamic>.from(decoded));
    for (var i = 0; i < WidgetColors.backgroundRoles.length; i++) {
      final role = WidgetColors.backgroundRoles[i];
      expect(restored.widgetColors.backgroundFor(role), 0xFF123400 + i);
      expect(restored.widgetColors.usesAutomaticText(role), i.isOdd);
      if (i.isEven) {
        expect(restored.widgetColors.foregroundFor(role), 0xFFEDCB00 + i);
      }
    }
    expect(restored.widgetColors.toJson(), colors.toJson());
  });

  test(
    'automatic contrast follows background after clearing a text override',
    () {
      var colors = const WidgetColors().withBackground('timer', 0xFF000000);
      expect(colors.foregroundFor('timer'), 0xFFFFFFFF);
      colors = colors.withText('timer', 0xFFABCDEF);
      colors = colors.withBackground('timer', 0xFFFFFFFF);
      expect(colors.foregroundFor('timer'), 0xFFABCDEF);
      colors = colors.withText('timer', null);
      expect(colors.usesAutomaticText('timer'), isTrue);
      expect(colors.foregroundFor('timer'), 0xFF24232C);
    },
  );

  test('only complete untouched legacy palettes migrate to new defaults', () {
    expect(
      WidgetColors.fromJson(legacyDefaults).toJson(),
      const WidgetColors().toJson(),
    );
    final custom = WidgetColors.fromJson({
      ...legacyDefaults,
      'baby': 0xFF123456,
    });
    expect(custom.baby, 0xFF123456);
    expect(custom.resume, legacyDefaults['resume']);
    expect(custom.end, legacyDefaults['end']);
    expect(custom.timer, const WidgetColors().timer);

    // Partial maps and versioned/new maps may represent deliberate choices.
    for (final saved in [
      {'resume': legacyDefaults['resume'], 'end': legacyDefaults['end']},
      {...legacyDefaults, 'version': 2},
      {...legacyDefaults, 'text': <String, int>{}},
      {...legacyDefaults, 'timer': 0xFFABCDEF},
    ]) {
      final restored = WidgetColors.fromJson(saved);
      expect(restored.resume, legacyDefaults['resume']);
      expect(restored.end, legacyDefaults['end']);
    }
  });

  test('version 2 upgrades soft yellow while preserving customized parts', () {
    final old = const WidgetColors().toJson()
      ..['version'] = 2
      ..['interruption'] = 0xFFF3C879
      ..['work'] = 0xFF123456
      ..remove('changeBaby');
    final migrated = WidgetColors.fromJson(old);
    expect(migrated.interruption, 0xFFFFCC33);
    expect(migrated.work, 0xFF123456);
    expect(migrated.changeBaby, 0xFF6450CA);
    old['interruption'] = 0xFF987654;
    expect(WidgetColors.fromJson(old).interruption, 0xFF987654);

    // Selecting the softer amber in the current editor remains a saved choice.
    final custom = const WidgetColors().withBackground(
      'interruption',
      0xFFF3C879,
    );
    expect(WidgetColors.fromJson(custom.toJson()).interruption, 0xFFF3C879);
  });

  test('invalid saved colors fall back and valid colors become opaque', () {
    final colors = WidgetColors.fromJson({
      'work': -1,
      'baby': 0x100000000,
      'interruption': 'yellow',
      'timer': 0x00123456,
      'child0': 0x00445566,
      'child7': 0xFF112233,
      'child8': 0xFFABCDEF,
      'text': {'timer': 0x00654321, 'end': -1, 'unknown': 0xFFFFFFFF},
    });
    expect(colors.work, const WidgetColors().work);
    expect(colors.baby, const WidgetColors().baby);
    expect(colors.interruption, const WidgetColors().interruption);
    expect(colors.timer, 0xFF123456);
    expect(colors.backgroundFor('child0'), 0xFF445566);
    expect(colors.backgroundFor('child7'), 0xFF112233);
    expect(colors.foregroundFor('timer'), 0xFF654321);
    expect(colors.textColors.keys, ['timer']);
    expect(() => colors.withBackground('child8', 0), throwsArgumentError);
    expect(() => colors.withText('unknown', 0), throwsArgumentError);
    expect(WidgetColors.fromJson(null).toJson(), const WidgetColors().toJson());
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/timer_guard_settings.dart';

Future<Map<String, dynamic>> availableSettings() async => {
  'enabled': true,
  'notificationsAllowed': true,
  'channelEnabled': true,
};

Future<void> mount(WidgetTester tester, TimerGuardSettings settings) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: settings)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapButton(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('check-ins explain response window and stop limits', (
    tester,
  ) async {
    await mount(
      tester,
      const TimerGuardSettings(responseMinutes: 15, androidSupported: false),
    );
    expect(find.text('Timer check-ins'), findsOneWidget);
    expect(find.textContaining('every 3 hours'), findsOneWidget);
    expect(find.textContaining('within 15 minutes'), findsOneWidget);
    expect(
      find.textContaining('12 hours without confirmation'),
      findsOneWidget,
    );
    expect(find.textContaining('20 hours'), findsOneWidget);
    expect(
      find.text('Check-in notifications are available in the Android app.'),
      findsOneWidget,
    );
    expect(find.text('Enable timer notifications'), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('notification permission stays independent of exact alarms', (
    tester,
  ) async {
    var requests = 0, exactRequests = 0;
    await mount(
      tester,
      TimerGuardSettings(
        responseMinutes: 15,
        androidSupported: true,
        loadTimerSettings: availableSettings,
        requestPermission: () async {
          requests++;
          return true;
        },
        requestPreciseAlerts: () async {
          exactRequests++;
          return true;
        },
      ),
    );
    await tapButton(tester, 'Enable timer notifications');
    expect(requests, 1);
    expect(exactRequests, 0);
    expect(find.text('Timer notifications enabled.'), findsOneWidget);
  });

  testWidgets('denied notifications explain where to enable them', (
    tester,
  ) async {
    await mount(
      tester,
      TimerGuardSettings(
        responseMinutes: 15,
        androidSupported: true,
        loadTimerSettings: availableSettings,
        requestPermission: () async => false,
      ),
    );
    await tapButton(tester, 'Enable timer notifications');
    expect(
      find.textContaining('Allow Relay notifications in Android settings'),
      findsOneWidget,
    );
  });

  testWidgets('non-Android never requests OS permissions', (tester) async {
    var requested = false;
    await mount(
      tester,
      TimerGuardSettings(
        responseMinutes: 15,
        androidSupported: false,
        requestPermission: () async {
          requested = true;
          return true;
        },
      ),
    );
    expect(requested, isFalse);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('precise alerts have a separate permission request', (
    tester,
  ) async {
    var requests = 0, exactRequests = 0;
    await mount(
      tester,
      TimerGuardSettings(
        responseMinutes: 15,
        androidSupported: true,
        loadTimerSettings: availableSettings,
        requestPermission: () async {
          requests++;
          return true;
        },
        requestPreciseAlerts: () async {
          exactRequests++;
          return true;
        },
      ),
    );
    await tapButton(tester, 'Allow precise timer alerts');
    expect(requests, 0);
    expect(exactRequests, 1);
    expect(find.text('Precise timer alerts enabled.'), findsOneWidget);
  });

  testWidgets('denied precise alerts explain Alarms and reminders', (
    tester,
  ) async {
    await mount(
      tester,
      TimerGuardSettings(
        responseMinutes: 15,
        androidSupported: true,
        loadTimerSettings: availableSettings,
        requestPreciseAlerts: () async => false,
      ),
    );
    await tapButton(tester, 'Allow precise timer alerts');
    expect(
      find.textContaining('Allow Alarms & reminders for Relay'),
      findsOneWidget,
    );
  });

  testWidgets('saved lock-screen preference loads and enables controls', (
    tester,
  ) async {
    var enabled = false, requests = 0;
    Future<Map<String, dynamic>> settings() async => {
      'enabled': enabled,
      'notificationsAllowed': true,
      'channelEnabled': true,
    };
    await mount(
      tester,
      TimerGuardSettings(
        responseMinutes: 15,
        androidSupported: true,
        loadTimerSettings: settings,
        setTimerEnabled: (value) async {
          enabled = value;
          return settings();
        },
        requestPermission: () async {
          requests++;
          return true;
        },
      ),
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
    expect(requests, 1);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('hiding lock-screen card does not request permissions', (
    tester,
  ) async {
    var enabled = true, requests = 0;
    Future<Map<String, dynamic>> settings() async => {'enabled': enabled};
    await mount(
      tester,
      TimerGuardSettings(
        responseMinutes: 15,
        androidSupported: true,
        loadTimerSettings: settings,
        setTimerEnabled: (value) async {
          enabled = value;
          return settings();
        },
        requestPermission: () async {
          requests++;
          return true;
        },
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    expect(requests, 0);
    expect(
      find.text('Lock-screen timer hidden. Your timer keeps running.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'disabled timer category is explained without changing preference',
    (tester) async {
      await mount(
        tester,
        TimerGuardSettings(
          responseMinutes: 15,
          androidSupported: true,
          loadTimerSettings: () async => {
            'enabled': true,
            'notificationsAllowed': true,
            'channelEnabled': false,
          },
        ),
      );
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(
        find.textContaining('Active timers notification category'),
        findsOneWidget,
      );
    },
  );

  testWidgets('failed preference write preserves the existing switch', (
    tester,
  ) async {
    await mount(
      tester,
      TimerGuardSettings(
        responseMinutes: 15,
        androidSupported: true,
        loadTimerSettings: availableSettings,
        setTimerEnabled: (_) async => throw StateError('unavailable'),
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(
      find.textContaining('Could not change the lock-screen timer setting'),
      findsOneWidget,
    );
  });
}

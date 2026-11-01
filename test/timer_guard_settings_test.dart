import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/timer_guard_settings.dart';

void main() {
  testWidgets('check-in settings explain the response window and stop limits', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TimerGuardSettings(
            responseMinutes: 15,
            androidSupported: false,
          ),
        ),
      ),
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
    expect(find.text('Enable check-in notifications'), findsNothing);
  });

  testWidgets(
    'notification permission success does not change timer or shift settings',
    (tester) async {
      var requests = 0;
      var exactRequests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimerGuardSettings(
              responseMinutes: 15,
              androidSupported: true,
              requestPermission: () async {
                requests++;
                return true;
              },
              requestPreciseAlerts: () async {
                exactRequests++;
                return true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Enable check-in notifications'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(exactRequests, 0);
      expect(find.text('Check-in notifications enabled.'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
    },
  );

  testWidgets('denied notification permission explains the next step', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimerGuardSettings(
            responseMinutes: 15,
            androidSupported: true,
            requestPermission: () async => false,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Enable check-in notifications'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Allow Relay notifications in Android settings'),
      findsOneWidget,
    );
  });

  testWidgets('non-Android settings never call the OS permission handler', (
    tester,
  ) async {
    var requested = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimerGuardSettings(
            responseMinutes: 15,
            androidSupported: false,
            requestPermission: () async {
              requested = true;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requested, isFalse);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('precise timer alerts have a separate permission request', (
    tester,
  ) async {
    var notificationRequests = 0, exactRequests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimerGuardSettings(
            responseMinutes: 15,
            androidSupported: true,
            requestPermission: () async {
              notificationRequests++;
              return true;
            },
            requestPreciseAlerts: () async {
              exactRequests++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Allow precise timer alerts'));
    await tester.pumpAndSettle();
    expect(notificationRequests, 0);
    expect(exactRequests, 1);
    expect(find.text('Precise timer alerts enabled.'), findsOneWidget);
  });

  testWidgets('denied precise alerts keep their permission status visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimerGuardSettings(
            responseMinutes: 15,
            androidSupported: true,
            requestPreciseAlerts: () async => false,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Allow precise timer alerts'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Allow Alarms & reminders for Relay'),
      findsOneWidget,
    );
  });
}

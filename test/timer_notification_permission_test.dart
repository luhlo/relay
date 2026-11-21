import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/alerts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  var allowed = false;
  final calls = <String>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    allowed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'areNotificationsEnabled') return allowed;
          if (call.method == 'requestNotificationsPermission') return allowed;
          throw StateError('Unexpected permission request: ${call.method}');
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'denied first-start notification prompt is not repeated for each timer',
    () async {
      final alerts = ShiftAlerts();
      await alerts.requestTimerNotifications();
      await alerts.requestTimerNotifications();
      expect(
        calls.where((name) => name == 'requestNotificationsPermission').length,
        1,
      );
      expect(calls.any((name) => name.contains('Exact')), isFalse);
    },
  );

  test(
    'an existing notification grant needs no prompt or exact alarm access',
    () async {
      allowed = true;
      await ShiftAlerts().requestTimerNotifications();
      expect(calls, ['areNotificationsEnabled']);
    },
  );

  test('non-Android first start does not request notifications', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await ShiftAlerts().requestTimerNotifications();
    expect(calls, isEmpty);
  });
}

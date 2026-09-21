import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'model.dart';

class ShiftAlerts {
  final plugin = FlutterLocalNotificationsPlugin();
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Future<void> initialize() async {
    if (!supported) return;
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
    );
  }

  Future<bool> enable() async {
    if (!supported) return false;
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()!;
    if (await android.requestNotificationsPermission() != true) return false;
    if (await android.canScheduleExactNotifications() != true) {
      await android.requestExactAlarmsPermission();
    }
    return await android.canScheduleExactNotifications() == true;
  }

  Future<void> sync(RelayState state) async {
    if (!supported) return;
    await plugin.cancelAllPendingNotifications();
    if (!state.alerts) return;
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()!;
    if (await android.areNotificationsEnabled() != true ||
        await android.canScheduleExactNotifications() != true) {
      throw StateError(
        'Enable notifications and alarms in Android settings, then enable alerts again.',
      );
    }
    final now = DateTime.now();
    for (final shift in state.shifts.where((s) => s.end.isAfter(now))) {
      for (final before in [true, false]) {
        final at = before
            ? shift.end.subtract(const Duration(minutes: 10))
            : shift.end;
        if (!at.isAfter(now)) continue;
        await plugin.zonedSchedule(
          id: shift.id * 2 + (before ? 0 : 1),
          title: before ? 'Handoff in 10 minutes' : 'Time to hand off',
          body: before
              ? 'Your ${shift.kind == ShiftKind.focus ? 'focus' : 'Baby Time'} block is almost over. Wrap up when you can.'
              : 'Your ${shift.kind == ShiftKind.focus ? 'focus' : 'Baby Time'} block has ended. Open Relay to start your next shift.',
          scheduledDate: tz.TZDateTime.from(at, tz.UTC),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'shift_handoffs',
              'Shift handoffs',
              channelDescription: 'Ten-minute reminders and shift transitions',
              importance: Importance.max,
              priority: Priority.high,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      }
    }
  }
}

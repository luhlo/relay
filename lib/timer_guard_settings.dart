import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'alerts.dart';

/// Notification permission is independent of shift reminders and exact alarms.
/// The timer's stop rules stay enabled even if notifications are denied.
class TimerGuardSettings extends StatefulWidget {
  const TimerGuardSettings({
    super.key,
    required this.responseMinutes,
    this.requestPermission,
    this.requestPreciseAlerts,
    this.androidSupported,
  });

  final int responseMinutes;
  final Future<bool> Function()? requestPermission;
  final Future<bool> Function()? requestPreciseAlerts;
  final bool? androidSupported;

  @override
  State<TimerGuardSettings> createState() => _TimerGuardSettingsState();
}

class _TimerGuardSettingsState extends State<TimerGuardSettings> {
  bool busy = false;
  bool requestingPreciseAlerts = false;
  String? message;
  bool get supported =>
      widget.androidSupported ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  Future<void> enableNotifications() async {
    if (!supported || busy) return;
    setState(() {
      busy = true;
      requestingPreciseAlerts = false;
      message = null;
    });
    try {
      final enabled = await (widget.requestPermission ?? _requestPermission)();
      if (!mounted) return;
      setState(() {
        message = enabled ? 'Check-in notifications enabled.' : 'Notifications are off. Allow Relay notifications in Android settings to receive check-ins.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Could not enable notifications. Check Relay notification permissions in Android settings.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _requestPermission() async {
    final alerts = ShiftAlerts();
    await alerts.initialize();
    final android = alerts.plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.requestNotificationsPermission() == true;
  }

  Future<void> enablePreciseAlerts() async {
    if (!supported || busy) return;
    setState(() {
      busy = true;
      requestingPreciseAlerts = true;
      message = null;
    });
    try {
      final enabled =
          await (widget.requestPreciseAlerts ?? _requestPreciseAlerts)();
      if (!mounted) return;
      setState(() {
        message = enabled ? 'Precise timer alerts enabled.' : 'Precise timer alerts are off. Allow Alarms & reminders for Relay in Android settings.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Could not enable precise timer alerts. Check Alarms & reminders for Relay in Android settings.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _requestPreciseAlerts() async {
    final alerts = ShiftAlerts();
    await alerts.initialize();
    final android = alerts.plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return false;
    if (await android.canScheduleExactNotifications() == true) return true;
    await android.requestExactAlarmsPermission();
    return await android.canScheduleExactNotifications() == true;
  }

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Timer check-ins',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          const SizedBox(height: 8),
          const Text(
            'Relay asks every 3 hours while Work Time, an interruption, or Baby Time is running.',
          ),
          const SizedBox(height: 8),
          Text(
            'If you do not respond within ${widget.responseMinutes} minutes, Relay stops the timer.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Timers also stop after 12 hours without confirmation and never run longer than 20 hours.',
          ),
          const SizedBox(height: 12),
          if (supported) ...[
            OutlinedButton.icon(
              onPressed: busy ? null : enableNotifications,
              icon: const Icon(Icons.notifications_active_outlined),
              label: Text(
                busy && !requestingPreciseAlerts
                    ? 'Enabling…'
                    : 'Enable check-in notifications',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Lets Android deliver timer check-ins on time while Relay is closed.',
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : enablePreciseAlerts,
              icon: const Icon(Icons.alarm_outlined),
              label: Text(
                busy && requestingPreciseAlerts
                    ? 'Enabling…'
                    : 'Allow precise timer alerts',
              ),
            ),
          ] else
            const Text(
              'Check-in notifications are available in the Android app.',
            ),
          if (message != null) ...[const SizedBox(height: 8), Text(message!)],
        ],
      ),
    ),
  );
}

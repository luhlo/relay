import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'alerts.dart';
import 'home_widget.dart';

/// Notification permission is independent of shift reminders and exact alarms.
/// The timer's stop rules stay enabled even if notifications are denied.
class TimerGuardSettings extends StatefulWidget {
  const TimerGuardSettings({
    super.key,
    required this.responseMinutes,
    this.requestPermission,
    this.requestPreciseAlerts,
    this.androidSupported,
    this.loadTimerSettings,
    this.setTimerEnabled,
  });

  final int responseMinutes;
  final Future<bool> Function()? requestPermission;
  final Future<bool> Function()? requestPreciseAlerts;
  final bool? androidSupported;
  final Future<Map<String, dynamic>> Function()? loadTimerSettings;
  final Future<Map<String, dynamic>> Function(bool)? setTimerEnabled;

  @override
  State<TimerGuardSettings> createState() => _TimerGuardSettingsState();
}

class _TimerGuardSettingsState extends State<TimerGuardSettings>
    with WidgetsBindingObserver {
  bool busy = false;
  bool requestingPreciseAlerts = false;
  bool lockScreenTimerEnabled = true;
  bool? notificationPermissionAllowed;
  bool? timerChannelEnabled;
  String? message;
  bool get supported =>
      widget.androidSupported ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  @override
  void initState() {
    super.initState();
    if (supported) {
      WidgetsBinding.instance.addObserver(this);
      refreshTimerSettings();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && supported && !busy) {
      refreshTimerSettings();
    }
  }

  Future<void> refreshTimerSettings() async {
    try {
      final settings =
          await (widget.loadTimerSettings ??
              RelayHomeWidget.instance.timerNotificationSettings)();
      if (!mounted) return;
      setState(() {
        lockScreenTimerEnabled = settings['enabled'] != false;
        notificationPermissionAllowed =
            settings['notificationsAllowed'] as bool?;
        timerChannelEnabled = settings['channelEnabled'] as bool?;
      });
    } catch (_) {
      // Notification settings must not block tracking or the settings page.
    }
  }

  Future<void> setLockScreenTimer(bool enabled) async {
    if (!supported || busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final settings =
          await (widget.setTimerEnabled ??
              RelayHomeWidget.instance.setTimerNotificationEnabled)(enabled);
      if (enabled) await (widget.requestPermission ?? _requestPermission)();
      if (!mounted) return;
      setState(() => lockScreenTimerEnabled = settings['enabled'] != false);
      await refreshTimerSettings();
      if (mounted) {
        setState(
          () => message = enabled
              ? 'Lock-screen timer enabled. Android notification settings control its visibility.'
              : 'Lock-screen timer hidden. Your timer keeps running.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Could not change the lock-screen timer setting. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> enableNotifications() async {
    if (!supported || busy) return;
    setState(() {
      busy = true;
      requestingPreciseAlerts = false;
      message = null;
    });
    try {
      final enabled = await (widget.requestPermission ?? _requestPermission)();
      await refreshTimerSettings();
      if (!mounted) return;
      setState(() {
        message = enabled ? 'Timer notifications enabled.' : 'Notifications are off. Allow Relay notifications in Android settings to see the lock-screen timer and receive check-ins.';
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
          if (supported) ...[
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Lock-screen timer'),
              subtitle: const Text(
                'Show Work Time or your child’s name, the timer, and Interruption, Resume and End controls.',
              ),
              value: lockScreenTimerEnabled,
              onChanged: busy ? null : setLockScreenTimer,
            ),
            const Text(
              'Your phone controls placement. On supported Samsung phones, live timers can appear in the Now bar.',
            ),
            if (lockScreenTimerEnabled &&
                notificationPermissionAllowed == false)
              const Text(
                'Allow Relay notifications in Android settings to show the lock-screen timer.',
              )
            else if (lockScreenTimerEnabled && timerChannelEnabled == false)
              const Text(
                'Allow the Active timers notification category in Android settings to show this timer.',
              ),
            const Divider(height: 24),
          ],
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
                    : 'Enable timer notifications',
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

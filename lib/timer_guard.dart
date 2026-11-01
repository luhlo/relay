import 'model.dart';

const timerGuardResponseMinutes = 15;
const timerCheckInterval = Duration(hours: 3);
const timerNoResponseLimit = Duration(hours: 12);
const timerAbsoluteLimit = Duration(hours: 20);

class TimerGuardResult {
  const TimerGuardResult({this.changed = false});
  final bool changed;
}

/// Stored UTC deadlines make late alarms/restarts close records at the actual
/// limit, rather than counting extra hours while Android deferred a job.
TimerGuardResult updateTimerGuard(
  RelayState state,
  DateTime now, {
  String action = 'guard',
  String? expectedSessionStart,
}) {
  final session = state.active;
  if (session == null) return const TimerGuardResult();
  if (expectedSessionStart != null &&
      expectedSessionStart != session.start.toUtc().toIso8601String()) {
    return const TimerGuardResult();
  }
  final lastConfirmed = session.lastConfirmedAt ?? session.start;
  final limits = <(DateTime, String)>[
    (
      session.start.add(timerAbsoluteLimit),
      'Timer stopped after the 20-hour time limit.',
    ),
    (
      lastConfirmed.add(timerNoResponseLimit),
      'Timer stopped after 12 hours without a response.',
    ),
    if (session.firstUnansweredCheckIn != null)
      (
        session.firstUnansweredCheckIn!.add(
          const Duration(minutes: timerGuardResponseMinutes),
        ),
        'Timer stopped because there was no response within 15 minutes of the check-in.',
      ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final cutoff = limits.first;
  if (!now.isBefore(cutoff.$1)) {
    // Older app versions could have recorded an interruption past the cap.
    session.interruptions.removeWhere((i) => !i.start.isBefore(cutoff.$1));
    state.finish(cutoff.$1, reason: cutoff.$2);
    return const TimerGuardResult(changed: true);
  }
  if (action == 'confirmTimer') {
    session.lastConfirmedAt = now;
    session.firstUnansweredCheckIn = null;
    session.lastReminderAt = null;
    return const TimerGuardResult(changed: true);
  }
  if (action == 'stopTimer') {
    state.finish(now);
    return const TimerGuardResult(changed: true);
  }
  final nextCheck = (session.lastReminderAt ?? lastConfirmed).add(
    timerCheckInterval,
  );
  if (!now.isBefore(nextCheck)) {
    session.firstUnansweredCheckIn ??= now;
    session.lastReminderAt = now;
    return const TimerGuardResult(changed: true);
  }
  return const TimerGuardResult();
}

Map<String, dynamic>? timerGuardSnapshot(RelayState state, DateTime now) {
  final session = state.active;
  if (session == null) {
    if (state.sessions.isEmpty || state.sessions.last.autoStopReason == null) {
      return null;
    }
    final last = state.sessions.last;
    return {
      'sessionStart': last.start.toUtc().toIso8601String(),
      'stoppedReason': last.autoStopReason,
      'stoppedAtMillis': last.end?.millisecondsSinceEpoch,
    };
  }
  final confirmed = session.lastConfirmedAt ?? session.start;
  final deadlines = [
    session.start.add(timerAbsoluteLimit),
    confirmed.add(timerNoResponseLimit),
    (session.lastReminderAt ?? confirmed).add(timerCheckInterval),
    if (session.firstUnansweredCheckIn != null)
      session.firstUnansweredCheckIn!.add(
        const Duration(minutes: timerGuardResponseMinutes),
      ),
  ]..sort();
  return {
    'sessionStart': session.start.toUtc().toIso8601String(),
    'nextEventAtMillis': deadlines.first.millisecondsSinceEpoch,
    'lastReminderAtMillis': session.lastReminderAt?.millisecondsSinceEpoch,
    'status': session.kind == ShiftKind.point
        ? 'baby'
        : session.interruption != null
        ? 'interrupted'
        : 'work',
  };
}

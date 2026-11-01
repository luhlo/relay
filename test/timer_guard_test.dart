import 'package:flutter_test/flutter_test.dart';
import 'package:relay/model.dart';
import 'package:relay/timer_guard.dart';

final start = DateTime.utc(2026, 11, 1, 5, 30);

RelayState running(String mode, {DateTime? at}) {
  final now = at ?? start;
  final state = RelayState();
  state.start(
    mode == 'baby' || mode == 'all babies' ? ShiftKind.point : ShiftKind.focus,
    now,
    baby: mode == 'all babies'
        ? Baby.both
        : mode == 'baby'
        ? Baby.chloe
        : null,
  );
  if (mode == 'interrupted') state.toggleInterruption(now);
  return state;
}

void main() {
  for (final mode in ['work', 'baby', 'all babies', 'interrupted']) {
    group('$mode timer guard', () {
      test(
        'asks at exactly three hours and schedules a 15-minute response',
        () {
          final state = running(mode);
          final due = start.add(timerCheckInterval);
          expect(
            timerGuardSnapshot(state, start)!['nextEventAtMillis'],
            due.millisecondsSinceEpoch,
          );
          expect(
            updateTimerGuard(
              state,
              due.subtract(const Duration(microseconds: 1)),
            ).changed,
            isFalse,
          );
          expect(state.active!.firstUnansweredCheckIn, isNull);

          expect(updateTimerGuard(state, due).changed, isTrue);
          expect(state.active!.firstUnansweredCheckIn, due);
          expect(state.active!.lastReminderAt, due);
          final responseDeadline = due.add(const Duration(minutes: 15));
          expect(
            timerGuardSnapshot(state, due)!['nextEventAtMillis'],
            responseDeadline.millisecondsSinceEpoch,
          );
          expect(
            updateTimerGuard(
              state,
              responseDeadline.subtract(const Duration(microseconds: 1)),
            ).changed,
            isFalse,
          );
          expect(state.active, isNotNull);
        },
      );

      test('Yes resets the check-in interval from the response time', () {
        final state = running(mode);
        final due = start.add(timerCheckInterval);
        updateTimerGuard(state, due);
        final response = due.add(const Duration(minutes: 5));
        expect(
          updateTimerGuard(
            state,
            response,
            action: 'confirmTimer',
            expectedSessionStart: start.toIso8601String(),
          ).changed,
          isTrue,
        );
        expect(state.active!.lastConfirmedAt, response);
        expect(state.active!.firstUnansweredCheckIn, isNull);
        expect(state.active!.lastReminderAt, isNull);
        final next = response.add(timerCheckInterval);
        expect(
          timerGuardSnapshot(state, response)!['nextEventAtMillis'],
          next.millisecondsSinceEpoch,
        );
        expect(
          updateTimerGuard(
            state,
            next.subtract(const Duration(microseconds: 1)),
          ).changed,
          isFalse,
        );
        expect(updateTimerGuard(state, next).changed, isTrue);
        expect(state.active!.firstUnansweredCheckIn, next);
      });

      test('a delayed alarm closes at the original unanswered deadline', () {
        final state = running(mode);
        final due = start.add(timerCheckInterval);
        updateTimerGuard(state, due);
        final cutoff = due.add(const Duration(minutes: 15));
        expect(
          updateTimerGuard(state, start.add(const Duration(hours: 8))).changed,
          isTrue,
        );
        expect(state.active, isNull);
        expect(state.sessions.single.end, cutoff);
        expect(state.sessions.single.autoStopReason, contains('15 minutes'));
        if (mode == 'interrupted') {
          expect(state.sessions.single.interruptions.single.end, cutoff);
        }
        final stopped = timerGuardSnapshot(
          state,
          start.add(const Duration(hours: 8)),
        )!;
        expect(stopped['stoppedAtMillis'], cutoff.millisecondsSinceEpoch);
        expect(stopped['stoppedReason'], contains('15 minutes'));
      });

      test('twelve-hour fallback works when the first alarm never ran', () {
        final state = running(mode);
        expect(state.active!.firstUnansweredCheckIn, isNull);
        expect(
          updateTimerGuard(state, start.add(const Duration(hours: 13))).changed,
          isTrue,
        );
        expect(state.active, isNull);
        expect(state.sessions.single.end, start.add(const Duration(hours: 12)));
        expect(state.sessions.single.autoStopReason, contains('12 hours'));
        if (mode == 'interrupted') {
          expect(
            state.sessions.single.interruptions.single.end,
            state.sessions.single.end,
          );
        }
      });

      test('recent confirmation never extends the 20-hour absolute cap', () {
        final state = running(mode);
        state.active!.lastConfirmedAt = start.add(const Duration(hours: 18));
        final cap = start.add(timerAbsoluteLimit);
        expect(
          timerGuardSnapshot(
            state,
            start.add(const Duration(hours: 18)),
          )!['nextEventAtMillis'],
          cap.millisecondsSinceEpoch,
        );
        expect(
          updateTimerGuard(
            state,
            cap.subtract(const Duration(microseconds: 1)),
          ).changed,
          isFalse,
        );
        expect(
          updateTimerGuard(state, cap, action: 'confirmTimer').changed,
          isTrue,
        );
        expect(state.active, isNull);
        expect(state.sessions.single.end, cap);
        expect(state.sessions.single.autoStopReason, contains('20-hour'));
        if (mode == 'interrupted') {
          expect(state.sessions.single.interruptions.single.end, cap);
        }
        expect(
          updateTimerGuard(
            state,
            cap.add(const Duration(minutes: 1)),
            action: 'confirmTimer',
          ).changed,
          isFalse,
        );
        expect(state.active, isNull);
      });
    });
  }

  test('a late Yes cannot revive an already expired response window', () {
    final state = running('work');
    final due = start.add(timerCheckInterval);
    updateTimerGuard(state, due);
    final deadline = due.add(const Duration(minutes: 15));
    updateTimerGuard(state, deadline, action: 'confirmTimer');
    expect(state.active, isNull);
    expect(state.sessions.single.end, deadline);
    expect(state.sessions.single.autoStopReason, contains('15 minutes'));
  });

  test('serialized sessions retain confirmation and response deadlines', () {
    final state = running('interrupted');
    final response = start.add(const Duration(hours: 1));
    updateTimerGuard(state, response, action: 'confirmTimer');
    final due = response.add(timerCheckInterval);
    updateTimerGuard(state, due);
    final copy = RelayState.fromJson(state.toJson());
    expect(copy.active!.lastConfirmedAt!.isAtSameMomentAs(response), isTrue);
    expect(copy.active!.firstUnansweredCheckIn!.isAtSameMomentAs(due), isTrue);
    expect(copy.active!.lastReminderAt!.isAtSameMomentAs(due), isTrue);
    expect(
      timerGuardSnapshot(copy, due)!['nextEventAtMillis'],
      due.add(const Duration(minutes: 15)).millisecondsSinceEpoch,
    );
    updateTimerGuard(copy, due.add(const Duration(minutes: 16)));
    expect(
      copy.sessions.single.end!.isAtSameMomentAs(
        due.add(const Duration(minutes: 15)),
      ),
      isTrue,
    );
    final stoppedCopy = RelayState.fromJson(copy.toJson());
    expect(stoppedCopy.sessions.single.autoStopReason, contains('15 minutes'));
    expect(
      stoppedCopy.sessions.single.interruptions.single.end,
      stoppedCopy.sessions.single.end,
    );
  });

  test('confirmation for an old session cannot alter the current session', () {
    final state = running('baby');
    final before = state.toJson();
    expect(
      updateTimerGuard(
        state,
        start.add(const Duration(hours: 1)),
        action: 'confirmTimer',
        expectedSessionStart: start
            .subtract(const Duration(days: 1))
            .toIso8601String(),
      ).changed,
      isFalse,
    );
    expect(state.toJson(), before);
  });

  test(
    'interruption and resume taps count as activity and reset pending checks',
    () {
      final state = running('work');
      final due = start.add(timerCheckInterval);
      updateTimerGuard(state, due);
      final pause = due.add(const Duration(minutes: 2));
      state.toggleInterruption(pause);
      expect(state.active!.lastConfirmedAt, pause);
      expect(state.active!.firstUnansweredCheckIn, isNull);
      expect(state.active!.lastReminderAt, isNull);
      expect(
        timerGuardSnapshot(state, pause)!['nextEventAtMillis'],
        pause.add(timerCheckInterval).millisecondsSinceEpoch,
      );
      final resume = pause.add(const Duration(minutes: 1));
      state.toggleInterruption(resume);
      expect(state.active!.lastConfirmedAt, resume);
      expect(state.active!.interruption, isNull);
      expect(
        timerGuardSnapshot(state, resume)!['nextEventAtMillis'],
        resume.add(timerCheckInterval).millisecondsSinceEpoch,
      );
    },
  );

  test(
    'check-in intervals use elapsed time across the Chicago DST fallback',
    () {
      final beforeFallback = DateTime.parse('2026-11-01T00:30:00-05:00');
      final exactlyThreeHours = DateTime.parse('2026-11-01T02:30:00-06:00');
      final state = running('work', at: beforeFallback);
      expect(
        exactlyThreeHours.difference(beforeFallback),
        const Duration(hours: 3),
      );
      expect(
        updateTimerGuard(
          state,
          DateTime.parse('2026-11-01T02:29:59-06:00'),
        ).changed,
        isFalse,
      );
      expect(updateTimerGuard(state, exactlyThreeHours).changed, isTrue);
      expect(
        timerGuardSnapshot(state, exactlyThreeHours)!['nextEventAtMillis'],
        DateTime.parse('2026-11-01T02:45:00-06:00').millisecondsSinceEpoch,
      );
    },
  );

  test(
    'stopping manually closes an open interruption without an auto-stop reason',
    () {
      final state = running('interrupted');
      final stop = start.add(const Duration(minutes: 20));
      updateTimerGuard(
        state,
        stop,
        action: 'stopTimer',
        expectedSessionStart: start.toIso8601String(),
      );
      expect(state.active, isNull);
      expect(state.sessions.single.end, stop);
      expect(state.sessions.single.interruptions.single.end, stop);
      expect(state.sessions.single.autoStopReason, isNull);
    },
  );

  test(
    'a historical interruption beyond the cap cannot create negative lost time',
    () {
      final state = running('work');
      final cap = start.add(timerAbsoluteLimit);
      state.active!.lastConfirmedAt = start.add(const Duration(hours: 18));
      state.active!.interruptions.add(
        Interruption(cap.add(const Duration(minutes: 1))),
      );
      updateTimerGuard(state, cap.add(const Duration(hours: 1)));
      expect(state.sessions.single.end, cap);
      expect(state.sessions.single.interruptions, isEmpty);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/home_widget.dart';
import 'package:relay/model.dart';

void main() {
  final start = DateTime(2026, 10, 31, 9);

  Map<String, dynamic> action(RelayState state, String kind, DateTime now) => {
    'action': kind,
    'context': 'local',
    'expectedStatus': widgetSnapshot(state, 'local', now)['status'],
    'sessionStart': state.active?.start.toUtc().toIso8601String(),
  };

  test('widget Work Time, interruption, resume and end preserve lost time', () {
    final state = RelayState();
    applyWidgetAction(state, action(state, 'work', start), 'local', start);
    final interruptedAt = start.add(const Duration(minutes: 10));
    applyWidgetAction(
      state,
      action(state, 'interruption', interruptedAt),
      'local',
      interruptedAt,
    );
    final snapshot = widgetSnapshot(
      state,
      'local',
      start.add(const Duration(minutes: 15)),
    );
    expect(snapshot['status'], 'interrupted');
    expect(snapshot['running'], isFalse);
    expect(snapshot['elapsedSeconds'], 600);
    final resumedAt = start.add(const Duration(minutes: 20));
    applyWidgetAction(
      state,
      action(state, 'interruption', resumedAt),
      'local',
      resumedAt,
    );
    final end = start.add(const Duration(minutes: 30));
    applyWidgetAction(state, action(state, 'end', end), 'local', end);
    expect(state.actualSeconds(start, end), 1200);
    expect(state.lostSeconds(start, end), 600);
    expect(widgetSnapshot(state, 'local', end)['status'], 'idle');
  });

  test('baby choices use configured children and all babies', () {
    final state = RelayState(childNames: ['Ava', 'Noah', 'Mia']);
    applyWidgetAction(
      state,
      {...action(state, 'baby', start), 'babyIndex': 2},
      'local',
      start,
    );
    expect(state.active!.baby, Baby.child3);
    expect(widgetSnapshot(state, 'local', start)['subtitle'], 'Mia');
    applyWidgetAction(
      state,
      {...action(state, 'baby', start), 'babyIndex': -1},
      'local',
      start,
    );
    expect(state.active!.baby, Baby.both);
    expect(widgetSnapshot(state, 'local', start)['subtitle'], 'All babies');
    expect(
      () => applyWidgetAction(
        state,
        {...action(state, 'baby', start), 'babyIndex': 8},
        'local',
        start,
      ),
      throwsArgumentError,
    );
  });

  test(
    'stale toggles, ended sessions and other accounts cannot be changed',
    () {
      final state = RelayState()..start(ShiftKind.focus, start);
      final stale = action(state, 'interruption', start);
      applyWidgetAction(state, stale, 'local', start);
      expect(
        () => applyWidgetAction(state, stale, 'local', start),
        throwsArgumentError,
      );
      final staleEnd = action(state, 'end', start);
      state.finish(start.add(const Duration(minutes: 1)));
      state.start(ShiftKind.focus, start.add(const Duration(minutes: 2)));
      expect(
        () => applyWidgetAction(state, staleEnd, 'local', start),
        throwsArgumentError,
      );
      expect(
        () => applyWidgetAction(
          state,
          action(state, 'work', start),
          'cloud:other',
          start,
        ),
        throwsArgumentError,
      );
      expect(state.active!.start, start.add(const Duration(minutes: 2)));
    },
  );
}

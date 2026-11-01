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
    expect(snapshot['timerLabel'], 'Interruption time');
    expect(snapshot['running'], isTrue);
    expect(snapshot['elapsedSeconds'], 300);
    expect(snapshot['workSeconds'], 600);
    final later = widgetSnapshot(
      state,
      'local',
      start.add(const Duration(minutes: 16)),
    );
    expect(later['elapsedSeconds'], 360);
    expect(later['workSeconds'], 600);
    final resumedAt = start.add(const Duration(minutes: 20));
    applyWidgetAction(
      state,
      action(state, 'interruption', resumedAt),
      'local',
      resumedAt,
    );
    final resumed = widgetSnapshot(
      state,
      'local',
      resumedAt.add(const Duration(minutes: 1)),
    );
    expect(resumed['status'], 'work');
    expect(resumed['timerLabel'], 'Work time');
    expect(resumed['elapsedSeconds'], 660);
    final end = start.add(const Duration(minutes: 30));
    applyWidgetAction(state, action(state, 'end', end), 'local', end);
    expect(state.actualSeconds(start, end), 1200);
    expect(state.lostSeconds(start, end), 600);
    expect(widgetSnapshot(state, 'local', end)['status'], 'idle');
  });

  test('widget snapshots carry saved colors and app-matching defaults', () {
    final state = RelayState();
    final defaults = widgetSnapshot(state, 'local', start)['colors'] as Map;
    expect(defaults['baby'], 0xFFDDEAAD);
    expect(defaults['interruption'], 0xFFFFCC33);
    expect(defaults['changeBaby'], isNot(defaults['end']));
    expect(defaults['resume'], isNot(defaults['interruption']));
    state.widgetColors = state.widgetColors.copyWith(baby: 0xFF336655);
    expect(
      (widgetSnapshot(state, 'local', start)['colors'] as Map)['baby'],
      0xFF336655,
    );
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
    expect(widgetSnapshot(state, 'local', start)['timerLabel'], 'Mia time');
    applyWidgetAction(
      state,
      {...action(state, 'baby', start), 'babyIndex': -1},
      'local',
      start,
    );
    expect(state.active!.baby, Baby.both);
    expect(widgetSnapshot(state, 'local', start)['subtitle'], 'All babies');
    expect(
      widgetSnapshot(state, 'local', start)['timerLabel'],
      'All babies time',
    );
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

  test('timer labels identify idle, default children and legacy childcare', () {
    final state = RelayState();
    expect(
      widgetSnapshot(state, 'local', start)['timerLabel'],
      'Choose your time',
    );
    state.start(ShiftKind.point, start, baby: Baby.chloe);
    expect(widgetSnapshot(state, 'local', start)['timerLabel'], 'Baby 1 time');
    state.finish(start.add(const Duration(minutes: 1)));
    state.start(ShiftKind.point, start.add(const Duration(minutes: 2)));
    expect(widgetSnapshot(state, 'local', start)['timerLabel'], 'Baby time');
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

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/model.dart';
import 'package:relay/trends.dart';

void main() {
  final day = DateTime(2026, 11, 24, 9);

  test('adding a child does not give them past All children time', () {
    final state = RelayState(childNames: ['One', 'Two']);
    state.start(ShiftKind.point, day, baby: Baby.both);
    state.finish(day.add(const Duration(minutes: 30)));
    state.childNames = ['One', 'Two', 'Three'];
    final now = day.add(const Duration(hours: 1));
    expect(state.babySeconds(day, now), 1800);
    expect(state.babySeconds(day, now, baby: Baby.chloe), 1800);
    expect(state.babySeconds(day, now, baby: Baby.luca), 1800);
    expect(state.babySeconds(day, now, baby: Baby.child3), 0);
    final point = dailyTrends(state, now, 1, now).single;
    expect(point.care[Baby.child3], 0);
    expect(point.care, TrendDay(dayStart(day), state, now).care);
  });

  test('an active All children session keeps its original children', () {
    final state = RelayState(childNames: ['One', 'Two']);
    state.start(ShiftKind.point, day, baby: Baby.both);
    state.childNames = ['One', 'Two', 'Three'];
    state.finish(day.add(const Duration(hours: 1)));
    state.start(
      ShiftKind.point,
      day.add(const Duration(hours: 1)),
      baby: Baby.both,
    );
    state.finish(day.add(const Duration(hours: 1, minutes: 20)));
    final now = day.add(const Duration(hours: 2));
    expect(state.babySeconds(day, now, baby: Baby.child3), 1200);
    expect(state.babySeconds(day, now), 4800);
  });

  test('legacy history is frozen before household metadata changes', () {
    final old = RelayState(childNames: ['One', 'Two']);
    old.start(ShiftKind.point, day, baby: Baby.both);
    old.finish(day.add(const Duration(minutes: 30)));
    final json = old.toJson();
    for (final session in json['sessions'] as List) {
      (session as Map).remove('careChildren');
    }
    final loaded = RelayState.fromJson(json);
    loaded.childNames = ['One', 'Two', 'Three'];
    final restored = RelayState.fromJson(loaded.toJson());
    expect(restored.sessions.single.careChildren, [Baby.chloe, Baby.luca]);
    expect(
      restored.babySeconds(
        day,
        day.add(const Duration(hours: 1)),
        baby: Baby.child3,
      ),
      0,
    );
  });

  test('hiding and restoring a child keeps their recorded time', () {
    final state = RelayState(childNames: ['One', 'Two', 'Three']);
    state.start(ShiftKind.point, day, baby: Baby.both);
    state.finish(day.add(const Duration(minutes: 30)));
    state.childNames = ['One', 'Two'];
    state.start(
      ShiftKind.point,
      day.add(const Duration(minutes: 30)),
      baby: Baby.both,
    );
    state.finish(day.add(const Duration(hours: 1)));
    state.childNames = ['One', 'Two', 'Three'];
    final now = day.add(const Duration(hours: 2));
    expect(state.babySeconds(day, now, baby: Baby.child3), 1800);
    expect(state.babySeconds(day, now), 3600);
  });
}

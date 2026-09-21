import 'package:flutter_test/flutter_test.dart';
import 'package:relay/model.dart';

void main() {
  test('inclusive range clips boundaries and preserves childcare totals', () {
    final data = RelayState();
    final from = DateTime(2026, 1, 1), end = DateTime(2026, 3, 1);
    data.start(ShiftKind.focus, DateTime(2025, 12, 31, 23));
    data.toggleInterruption(DateTime(2026, 1, 1));
    data.toggleInterruption(DateTime(2026, 1, 1, 0, 15));
    data.finish(DateTime(2026, 1, 1, 1));
    data.start(ShiftKind.point, DateTime(2026, 3, 1, 23), baby: Baby.both);
    data.finish(DateTime(2026, 3, 2, 1));
    final now = DateTime(2026, 3, 3);
    expect(data.totalWorkSeconds(from, now, endDay: end), 3600);
    expect(data.actualSeconds(from, now, endDay: end), 2700);
    expect(data.lostSeconds(from, now, endDay: end), 900);
    expect(data.babySeconds(from, now, endDay: end), 3600);
    expect(data.babySeconds(from, now, endDay: end, baby: Baby.chloe), 3600);
    expect(data.babySeconds(from, now, endDay: end, baby: Baby.luca), 3600);
  });
  final day = DateTime(2026, 9, 19, 9);
  test('focus subtracts both completed and ongoing interruptions', () {
    final data = RelayState();
    data.start(ShiftKind.focus, day);
    data.toggleInterruption(day.add(const Duration(minutes: 10)));
    expect(data.actualSeconds(day, day.add(const Duration(minutes: 15))), 600);
    data.toggleInterruption(day.add(const Duration(minutes: 20)));
    expect(data.actualSeconds(day, day.add(const Duration(minutes: 30))), 1200);
    expect(data.lostSeconds(day, day.add(const Duration(minutes: 30))), 600);
  });
  test('handoff closes an interruption and cannot double count focus', () {
    final data = RelayState();
    data.start(ShiftKind.focus, day);
    data.toggleInterruption(day.add(const Duration(minutes: 10)));
    data.start(ShiftKind.point, day.add(const Duration(minutes: 20)));
    expect(data.sessions.first.interruption, isNull);
    expect(data.actualSeconds(day, day.add(const Duration(minutes: 40))), 600);
    data.start(ShiftKind.point, day.add(const Duration(minutes: 30)));
    expect(data.sessions.length, 2);
  });
  test('restart preserves active interruption timestamps', () {
    final data = RelayState();
    data.start(ShiftKind.focus, day);
    data.toggleInterruption(day.add(const Duration(minutes: 5)));
    final restored = RelayState.fromJson(data.toJson());
    expect(
      restored.active!.interruption!.start,
      day.add(const Duration(minutes: 5)),
    );
    expect(
      restored.actualSeconds(day, day.add(const Duration(minutes: 20))),
      300,
    );
  });
  test(
    'push extends current block and ripples only conflicting later blocks',
    () {
      final data = RelayState(
        shifts: [
          Shift(
            id: 1,
            kind: ShiftKind.focus,
            start: day,
            end: day.add(const Duration(hours: 1)),
          ),
          Shift(
            id: 2,
            kind: ShiftKind.point,
            start: day.add(const Duration(hours: 1)),
            end: day.add(const Duration(hours: 2)),
          ),
          Shift(
            id: 3,
            kind: ShiftKind.focus,
            start: day.add(const Duration(hours: 3)),
            end: day.add(const Duration(hours: 4)),
          ),
        ],
      );
      data.start(ShiftKind.focus, day);
      data.push();
      expect(data.shifts[0].start, day);
      expect(data.shifts[0].end, day.add(const Duration(minutes: 75)));
      expect(data.shifts[1].start, day.add(const Duration(minutes: 75)));
      expect(data.shifts[1].end, day.add(const Duration(minutes: 135)));
      expect(data.shifts[2].start, day.add(const Duration(hours: 3)));
    },
  );
  test('overlaps rejected but adjacent blocks allowed', () {
    final data = RelayState();
    data.putShift(
      Shift(
        id: 1,
        kind: ShiftKind.focus,
        start: day,
        end: day.add(const Duration(hours: 1)),
      ),
    );
    expect(
      () => data.putShift(
        Shift(
          id: 2,
          kind: ShiftKind.point,
          start: day.add(const Duration(minutes: 45)),
          end: day.add(const Duration(hours: 2)),
        ),
      ),
      throwsArgumentError,
    );
    data.putShift(
      Shift(
        id: 2,
        kind: ShiftKind.point,
        start: day.add(const Duration(hours: 1)),
        end: day.add(const Duration(hours: 2)),
      ),
    );
    expect(data.shifts.length, 2);
  });
  test('midnight sessions are attributed to each local day', () {
    final start = DateTime(2026, 9, 19, 23, 30);
    final data = RelayState();
    data.start(ShiftKind.focus, start);
    data.toggleInterruption(start.add(const Duration(minutes: 20)));
    data.toggleInterruption(start.add(const Duration(minutes: 40)));
    data.finish(start.add(const Duration(hours: 1)));
    expect(
      data.actualSeconds(start, start.add(const Duration(hours: 1))),
      1200,
    );
    expect(
      data.actualSeconds(
        DateTime(2026, 9, 20),
        start.add(const Duration(hours: 1)),
      ),
      1200,
    );
    expect(data.scheduledSeconds(start), 1800);
    expect(data.scheduledSeconds(DateTime(2026, 9, 20)), 1800);
  });
  test('quick-start ends at the next planned block', () {
    final data = RelayState(
      shifts: [
        Shift(
          id: 1,
          kind: ShiftKind.point,
          start: day.add(const Duration(minutes: 20)),
          end: day.add(const Duration(hours: 1)),
        ),
      ],
    );
    data.start(ShiftKind.focus, day);
    expect(data.activeShift!.end, day.add(const Duration(minutes: 20)));
  });
  test('deleting schedule does not erase actual focus history', () {
    final data = RelayState();
    data.start(ShiftKind.focus, day);
    data.finish(day.add(const Duration(minutes: 20)));
    data.shifts.clear();
    expect(data.actualSeconds(day, day.add(const Duration(hours: 1))), 1200);
    expect(data.scheduledSeconds(day), 0);
  });
  test('baby handoff splits time by child and survives restart', () {
    final data = RelayState();
    data.start(ShiftKind.point, day, baby: Baby.chloe);
    data.start(
      ShiftKind.point,
      day.add(const Duration(minutes: 20)),
      baby: Baby.luca,
    );
    final restored = RelayState.fromJson(data.toJson());
    final now = day.add(const Duration(minutes: 35));
    expect(restored.active!.baby, Baby.luca);
    expect(restored.babySeconds(day, now, baby: Baby.chloe), 1200);
    expect(restored.babySeconds(day, now, baby: Baby.luca), 900);
    expect(restored.babySeconds(day, now), 2100);
    expect(restored.totalWorkSeconds(day, now), 0);
    restored.start(ShiftKind.point, now, baby: Baby.luca);
    expect(restored.sessions.length, 2);
  });
  test('old childcare records remain unassigned without losing history', () {
    final data = RelayState();
    data.start(ShiftKind.point, day);
    final json = data.toJson();
    json['version'] = 1;
    for (final session in json['sessions']) {
      session.remove('baby');
    }
    final restored = RelayState.fromJson(json);
    final now = day.add(const Duration(minutes: 20));
    expect(restored.babySeconds(day, now, unassignedOnly: true), 1200);
    expect(restored.babySeconds(day, now, baby: Baby.chloe), 0);
  });
  test('total work includes interruptions, but excludes baby time', () {
    final data = RelayState();
    data.start(ShiftKind.focus, day);
    data.toggleInterruption(day.add(const Duration(minutes: 10)));
    final during = day.add(const Duration(minutes: 15));
    expect(data.totalWorkSeconds(day, during), 900);
    expect(data.actualSeconds(day, during), 600);
    expect(data.lostSeconds(day, during), 300);
    data.start(
      ShiftKind.point,
      day.add(const Duration(minutes: 20)),
      baby: Baby.luca,
    );
    final now = day.add(const Duration(minutes: 40));
    expect(data.totalWorkSeconds(day, now), 1200);
    expect(data.babySeconds(day, now, baby: Baby.luca), 1200);
  });
  test('baby time spanning midnight is split across local days', () {
    final start = DateTime(2026, 9, 19, 23, 45);
    final data = RelayState();
    data.start(ShiftKind.point, start, baby: Baby.chloe);
    final now = start.add(const Duration(minutes: 30));
    expect(data.babySeconds(start, now, baby: Baby.chloe), 900);
    expect(data.babySeconds(now, now, baby: Baby.chloe), 900);
  });
  test('both records shared time and includes it for each child', () {
    final data = RelayState();
    data.start(ShiftKind.point, day, baby: Baby.both);
    final now = day.add(const Duration(minutes: 30));
    expect(data.babySeconds(day, now), 1800);
    expect(data.babySeconds(day, now, baby: Baby.both), 1800);
    expect(data.babySeconds(day, now, baby: Baby.chloe), 1800);
    expect(data.babySeconds(day, now, baby: Baby.luca), 1800);
  });
  test('a third child is named, tracked, and restored', () {
    final data = RelayState(childNames: ['Ava', 'Noah', 'Mia']);
    data.start(ShiftKind.point, day, baby: Baby.child3);
    final restored = RelayState.fromJson(data.toJson());
    final now = day.add(const Duration(minutes: 12));
    expect(restored.childNames, ['Ava', 'Noah', 'Mia']);
    expect(restored.babyName(Baby.child3), 'Mia');
    expect(restored.availableBabies, [
      Baby.chloe,
      Baby.luca,
      Baby.child3,
      Baby.both,
    ]);
    expect(restored.babySeconds(day, now, baby: Baby.child3), 720);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/cloud.dart';
import 'package:relay/cloud_merge.dart';
import 'package:relay/model.dart';

RelayState _history(int id, DateTime start) => RelayState(
  shifts: [
    Shift(
      id: id,
      kind: ShiftKind.focus,
      start: start,
      end: start.add(const Duration(minutes: 30)),
    ),
  ],
  sessions: [
    Session(
      shiftId: id,
      kind: ShiftKind.focus,
      start: start,
      end: start.add(const Duration(minutes: 30)),
    ),
  ],
);

void main() {
  test('disjoint completed sessions are combined chronologically', () {
    final base = RelayState().toJson();
    final local = _history(1, DateTime.utc(2026, 11, 19, 9)).toJson();
    final remote = _history(2, DateTime.utc(2026, 11, 19, 10)).toJson();
    final result = mergeCloudPayload(base, local, remote);
    expect(result.conflicts, isEmpty);
    expect(
      RelayState.fromJson(result.payload!).sessions.map((s) => s.shiftId),
      [1, 2],
    );
  });

  test('overlapping records are not combined into double-counted work', () {
    final base = RelayState().toJson();
    final local = _history(1, DateTime.utc(2026, 11, 19, 9)).toJson();
    final remote = _history(2, DateTime.utc(2026, 11, 19, 9, 15)).toJson();
    final result = mergeCloudPayload(base, local, remote);
    expect(result.payload, isNull);
    expect(result.conflicts, contains('overlapping sessions'));
  });

  test('two active sessions with distinct IDs require explicit review', () {
    final base = RelayState().toJson();
    final local = _history(1, DateTime.utc(2026, 11, 19, 9)).toJson();
    final remote = _history(2, DateTime.utc(2026, 11, 19, 10)).toJson();
    (local['sessions'] as List).single['end'] = null;
    (remote['sessions'] as List).single['end'] = null;
    final result = mergeCloudPayload(base, local, remote);
    expect(result.payload, isNull);
    expect(result.conflicts, contains('multiple or overlapping active timers'));
  });

  test(
    'separately created colliding schedule IDs never form a hybrid record',
    () {
      final base = RelayState().toJson();
      final local = _history(1, DateTime.utc(2026, 11, 19, 9)).toJson();
      final remote = _history(1, DateTime.utc(2026, 11, 19, 11)).toJson();
      final result = mergeCloudPayload(base, local, remote);
      expect(result.payload, isNull);
      expect(result.conflicts, contains('shifts[1]'));
    },
  );

  test(
    'a deletion cannot silently erase a record concurrently edited elsewhere',
    () {
      final base = _history(1, DateTime.utc(2026, 11, 19, 9)).toJson();
      final local = RelayState().toJson();
      final remote = copyCloudJson(base);
      (remote['shifts'] as List).single['end'] = DateTime.utc(
        2026,
        11,
        19,
        9,
        45,
      ).toIso8601String();
      final result = mergeCloudPayload(base, local, remote);
      expect(result.payload, isNull);
      expect(result.conflicts, contains('shifts[1]'));
    },
  );

  test('widget request IDs do not manufacture a conflict', () {
    final base = RelayState().toJson();
    final local = copyCloudJson(base)..['lastWidgetRequestId'] = 'left';
    final remote = copyCloudJson(base)..['lastWidgetRequestId'] = 'right';
    local['alerts'] = true;
    remote['dailyPersonalHours'] = 4;
    final result = mergeCloudPayload(base, local, remote);
    expect(result.conflicts, isEmpty);
    expect(result.payload!['lastWidgetRequestId'], 'left');
    expect(result.payload!['alerts'], isTrue);
    expect(result.payload!['dailyPersonalHours'], 4);
  });

  test('divergent ending times for one interruption require review', () {
    final original = _history(1, DateTime.utc(2026, 11, 19, 9));
    original.sessions.single.end = null;
    original.sessions.single.interruptions.add(
      Interruption(DateTime.utc(2026, 11, 19, 9, 5)),
    );
    final base = original.toJson();
    final local = copyCloudJson(base), remote = copyCloudJson(base);
    (local['sessions'] as List).single['interruptions'][0]['end'] =
        DateTime.utc(2026, 11, 19, 9, 10).toIso8601String();
    (remote['sessions'] as List).single['interruptions'][0]['end'] =
        DateTime.utc(2026, 11, 19, 9, 12).toIso8601String();
    expect(mergeCloudPayload(base, local, remote).payload, isNull);
  });
}

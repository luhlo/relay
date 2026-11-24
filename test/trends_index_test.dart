import 'package:flutter_test/flutter_test.dart';
import 'package:relay/model.dart';
import 'package:relay/trends.dart';

void _same(TrendDay actual, TrendDay expected) {
  expect(actual.day, expected.day);
  expect(actual.total, expected.total, reason: '${actual.day}: total');
  expect(actual.actual, expected.actual, reason: '${actual.day}: actual');
  expect(actual.lost, expected.lost, reason: '${actual.day}: interrupted');
  expect(actual.baby, expected.baby, reason: '${actual.day}: care');
  expect(
    actual.interruptions,
    expected.interruptions,
    reason: '${actual.day}: count',
  );
  expect(
    actual.hasWork,
    expected.hasWork,
    reason: '${actual.day}: recorded work',
  );
  expect(
    actual.hasBaby,
    expected.hasBaby,
    reason: '${actual.day}: recorded care',
  );
  expect(actual.care, expected.care, reason: '${actual.day}: each child');
}

void main() {
  test('indexed totals match exact per-day calculations across midnight and range boundaries', () {
    final now = DateTime(2026, 11, 4, 12);
    final data = RelayState(childNames: ['One', 'Two', 'Three']);
    data.start(ShiftKind.focus, DateTime(2026, 10, 31, 23, 45));
    data.toggleInterruption(DateTime(2026, 10, 31, 23, 50));
    data.toggleInterruption(DateTime(2026, 11, 1, 0, 15));
    data.finish(DateTime(2026, 11, 1, 1));
    data.start(ShiftKind.point, DateTime(2026, 11, 1, 23, 30), baby: Baby.both);
    data.finish(DateTime(2026, 11, 2, 0, 30));
    data.start(ShiftKind.point, DateTime(2026, 11, 2, 14));
    data.finish(DateTime(2026, 11, 2, 15));
    data.start(ShiftKind.point, DateTime(2026, 11, 2, 16), baby: Baby.child3);
    data.finish(DateTime(2026, 11, 2, 17));
    data.start(ShiftKind.focus, DateTime(2026, 11, 3, 23, 30));
    data.toggleInterruption(DateTime(2026, 11, 3, 23, 45));
    for (final days in [1, 3, 7, 30]) {
      for (final point in dailyTrends(data, now, days, now)) {
        _same(point, TrendDay(point.day, data, now));
      }
    }
  });

  test('index preserves zero-duration recorded sessions, empty gaps and start-day interruption counts', () {
    final now = DateTime(2026, 11, 4, 12);
    final zero = DateTime(2026, 11, 2, 9);
    final data = RelayState(
      sessions: [
        Session(shiftId: 1, kind: ShiftKind.focus, start: zero, end: zero),
        Session(
          shiftId: 2,
          kind: ShiftKind.focus,
          start: DateTime(2026, 11, 3, 23),
          end: now,
          interruptions: [Interruption(DateTime(2026, 11, 3, 23, 30), now)],
        ),
      ],
    );
    final points = dailyTrends(data, now, 7, now);
    for (final point in points) {
      _same(point, TrendDay(point.day, data, now));
    }
    expect(points[4].hasWork, isTrue);
    expect(points[4].actual, 0);
    expect(points[5].interruptions, 1);
    expect(points[6].interruptions, 0);
    expect(points.first.hasWork, isFalse);
  });

  test(
    'history cache reuses completed days and detects in-place record edits',
    () {
      final now = DateTime(2026, 11, 4, 12);
      final data = RelayState();
      data.start(ShiftKind.focus, now.subtract(const Duration(hours: 2)));
      data.finish(now.subtract(const Duration(hours: 1)));
      final cache = DailyTrendsCache();
      final first = cache.read(data, now, 30, now);
      final unchanged = cache.read(
        data,
        now,
        30,
        now.add(const Duration(seconds: 1)),
      );
      expect(identical(first, unchanged), isTrue);
      data.sessions.single.end = now.subtract(const Duration(minutes: 30));
      final edited = cache.read(
        data,
        now,
        30,
        now.add(const Duration(seconds: 2)),
      );
      expect(identical(first, edited), isFalse);
      expect(edited.last.total, 5400);
      data.childNames = ['Only one child'];
      expect(cache.read(data, now, 30, now).last.care.keys, [Baby.chloe]);
    },
  );

  test('active clock updates only today while a midnight roll refreshes its day boundary', () {
    final beforeMidnight = DateTime(2026, 11, 3, 23, 59, 30);
    final data = RelayState();
    data.start(
      ShiftKind.focus,
      beforeMidnight.subtract(const Duration(minutes: 2)),
    );
    final cache = DailyTrendsCache();
    final first = cache.read(data, beforeMidnight, 7, beforeMidnight);
    final ticking = cache.read(
      data,
      beforeMidnight,
      7,
      beforeMidnight.add(const Duration(seconds: 10)),
    );
    expect(identical(first.first, ticking.first), isTrue);
    expect(ticking.last.total, first.last.total + 10);
    data.toggleInterruption(beforeMidnight.add(const Duration(seconds: 15)));
    final afterMidnight = beforeMidnight.add(const Duration(minutes: 1));
    final next = cache.read(data, afterMidnight, 7, afterMidnight);
    expect(next.last.day, dayStart(afterMidnight));
    for (final point in next) {
      _same(point, TrendDay(point.day, data, afterMidnight));
    }
  });

  test('history outside the selected range is cached even with a current active timer', () {
    final now = DateTime(2026, 11, 4, 12);
    final data = RelayState()..start(ShiftKind.focus, now);
    final cache = DailyTrendsCache();
    final ending = now.subtract(const Duration(days: 7));
    final first = cache.read(data, ending, 30, now);
    final next = cache.read(
      data,
      ending,
      30,
      now.add(const Duration(seconds: 1)),
    );
    expect(identical(first, next), isTrue);
  });

  test('a century-wide range with 1000 sessions avoids repeated full-history scans', () {
    final now = DateTime(2026, 11, 22, 12);
    final data = RelayState();
    for (var index = 0; index < 1000; index++) {
      final start = now.subtract(Duration(hours: 12 * (1000 - index)));
      data.start(
        index.isEven ? ShiftKind.focus : ShiftKind.point,
        start,
        baby: index.isEven ? null : Baby.both,
      );
      if (index.isEven) {
        data.toggleInterruption(start.add(const Duration(minutes: 10)));
        data.toggleInterruption(start.add(const Duration(minutes: 15)));
      }
      data.finish(start.add(const Duration(minutes: 30)));
    }
    final watch = Stopwatch()..start();
    final cache = DailyTrendsCache();
    final points = cache.read(data, now, 46346, now);
    final repeated = cache.read(
      data,
      now,
      46346,
      now.add(const Duration(seconds: 1)),
    );
    watch.stop();
    expect(points.length, 46346);
    expect(identical(points, repeated), isTrue);
    expect(points.fold(0, (sum, point) => sum + point.total), 900000);
    expect(points.fold(0, (sum, point) => sum + point.baby), 900000);
    // The previous algorithm took ~46 seconds for just one equivalent pass on
    // the audit machine. This loose ceiling catches that unusable regression.
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    // ignore: avoid_print
    print(
      'Indexed 46,346 days / 1000 sessions + cached tick: ${watch.elapsedMilliseconds}ms',
    );
  });
}

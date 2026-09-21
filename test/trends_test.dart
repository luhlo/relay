import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/model.dart';
import 'package:relay/trends.dart';

void main() {
  final now = DateTime(2026, 9, 20, 12);
  test('range crosses month boundaries and excludes future days', () {
    final points = dailyTrends(RelayState(), DateTime(2026, 10), 30, now);
    expect(points.length, 30);
    expect(points.first.day, DateTime(2026, 8, 22));
    expect(points.last.day, dayStart(now));
    expect(points.every((p) => !p.hasWork && !p.hasBaby), isTrue);
  });
  test('daily work and counts distinguish no data from zero interruptions', () {
    final data = RelayState();
    final start = DateTime(2026, 9, 19, 23, 30);
    data.start(ShiftKind.focus, start);
    data.toggleInterruption(start.add(const Duration(minutes: 20)));
    data.toggleInterruption(start.add(const Duration(minutes: 40)));
    data.finish(start.add(const Duration(hours: 1)));
    final points = dailyTrends(data, now, 7, now);
    expect(points[4].hasWork, isFalse);
    expect(points[5].total, 1800);
    expect(points[5].actual, 1200);
    expect(points[5].lost, 600);
    expect(points[5].interruptions, 1);
    expect(points[6].hasWork, isTrue);
    expect(points[6].interruptions, 0);
    expect(points[6].lost, 600);
  });
  testWidgets('phone chart supports range, metric and day selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = RelayState();
    data.start(ShiftKind.focus, now.subtract(const Duration(hours: 2)));
    data.toggleInterruption(now.subtract(const Duration(minutes: 15)));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TrendsCard(data: data, ending: now, now: now),
          ),
        ),
      ),
    );
    await tester.tap(find.text('30 days'));
    await tester.pumpAndSettle();
    expect(find.text('Aug 22 – Sep 20, 2026'), findsOneWidget);
    await tester.tap(find.text('Interruptions'));
    await tester.pumpAndSettle();
    expect(find.text('Interruption count: 1'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Previous trend day'));
    await tester.tap(find.byTooltip('Previous trend day'));
    await tester.pumpAndSettle();
    expect(find.text('Interruption count: not recorded'), findsOneWidget);
    await tester.ensureVisible(find.text('Baby Time'));
    await tester.tap(find.text('Baby Time'));
    await tester.pumpAndSettle();
    expect(find.text('Baby 1: not recorded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

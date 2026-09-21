import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/model.dart';
import 'package:relay/time_pies.dart';

void main() {
  testWidgets('daily and focus percentages use distinct totals on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final day = DateTime(2026, 9, 20);
    final data = RelayState();
    data.start(ShiftKind.focus, day.add(const Duration(hours: 9)));
    data.toggleInterruption(day.add(const Duration(hours: 9, minutes: 30)));
    data.toggleInterruption(day.add(const Duration(hours: 9, minutes: 45)));
    data.start(
      ShiftKind.point,
      day.add(const Duration(hours: 10)),
      baby: Baby.both,
    );
    data.finish(day.add(const Duration(hours: 11)));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TimePies(
              data: data,
              day: day,
              now: day.add(const Duration(hours: 12)),
            ),
          ),
        ),
      ),
    );
    expect(find.text('50.0%'), findsNWidgets(2));
    expect(find.text('75.0%'), findsOneWidget);
    expect(find.text('25.0%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty day has no invented percentages', (tester) async {
    final day = DateTime(2026, 9, 20);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TimePies(data: RelayState(), day: day, now: day),
          ),
        ),
      ),
    );
    expect(find.text('—'), findsNWidgets(4));
    expect(find.textContaining('NaN'), findsNothing);
    expect(
      find.text('Start a focus session to see your work-time split.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

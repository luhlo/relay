import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:relay/alerts.dart';
import 'package:relay/app_theme.dart';
import 'package:relay/home_widget.dart';
import 'package:relay/main.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';

class _Store extends RelayStore {
  _Store(this.state);
  final RelayState state;
  @override
  Future<RelayState> load() async => state;
}

class _NoAlerts extends ShiftAlerts {
  @override
  bool get supported => false;
}

class _NoWidget extends RelayHomeWidget {
  @override
  bool get supported => false;
}

void main() {
  Future<void> home(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RelayHome(
          store: _Store(RelayState()),
          alerts: _NoAlerts(),
          homeWidget: _NoWidget(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final selected in [DateTime(2020), DateTime(2100, 12, 31)]) {
    testWidgets('Schedule picker reopens after navigating past $selected', (
      tester,
    ) async {
      await home(tester);
      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(DateFormat('EEE, MMM d, yyyy').format(DateTime.now())),
      );
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(DatePickerDialog))).pop(selected);
      await tester.pumpAndSettle();
      final previous = selected.year == 2020;
      await tester.tap(find.byTooltip(previous ? 'Previous day' : 'Next day'));
      await tester.pumpAndSettle();
      final target = DateTime(
        selected.year,
        selected.month,
        selected.day + (previous ? -1 : 1),
      );
      await tester.tap(
        find.text(DateFormat('EEE, MMM d, yyyy').format(target)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final picker = tester.widget<DatePickerDialog>(
        find.byType(DatePickerDialog),
      );
      expect(picker.firstDate.isAfter(target), isFalse);
      expect(picker.lastDate.isBefore(target), isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Insights date picker reopens after going earlier than 1900', (
    tester,
  ) async {
    await home(tester);
    await tester.tap(find.text('Insights'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Choose dates'));
    await tester.tap(find.text('Choose dates'));
    await tester.pumpAndSettle();
    final first = DateTime(1900);
    Navigator.of(tester.element(find.byType(DateRangePickerDialog)))
        .pop(DateTimeRange(start: first, end: first));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Previous Insights date'));
    await tester.tap(find.byTooltip('Previous Insights date'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Choose dates'));
    await tester.tap(find.text('Choose dates'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final picker = tester.widget<DateRangePickerDialog>(
      find.byType(DateRangePickerDialog),
    );
    expect(picker.firstDate.isAfter(DateTime(1899, 12, 31)), isFalse);
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  for (final screen in [
    'idle',
    'focus',
    'interrupted',
    'baby',
    'Schedule',
    'Insights',
  ]) {
    testWidgets('$screen remains usable on a small phone with large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.now();
      final state = RelayState(childNames: ['Alexandria', 'Baby 2']);
      if (screen == 'focus' || screen == 'interrupted') {
        state.start(ShiftKind.focus, now.subtract(const Duration(minutes: 20)));
        if (screen == 'interrupted') state.toggleInterruption(now);
      }
      if (screen == 'baby') {
        state.start(
          ShiftKind.point,
          now.subtract(const Duration(minutes: 20)),
          baby: Baby.chloe,
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: relayTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: RelayHome(
            store: _Store(state),
            alerts: _NoAlerts(),
            homeWidget: _NoWidget(),
            onMenu: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (screen == 'Schedule' || screen == 'Insights') {
        await tester.tap(find.text(screen));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      final scrollable = find.byType(SingleChildScrollView).first;
      await tester.drag(scrollable, const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

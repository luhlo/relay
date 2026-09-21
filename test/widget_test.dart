import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/main.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';

class MemoryStore extends RelayStore {
  RelayState state = RelayState();
  bool fail = false;
  @override
  Future<RelayState> load() async => state;
  @override
  Future<void> save(RelayState value) async {
    if (fail) throw StateError('disk full');
    state = RelayState.fromJson(value.toJson());
  }
}

void main() {
  testWidgets('phone dashboard keeps both shift choices above the fold', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: RelayHome(store: MemoryStore(), onMenu: () {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('relay-brand-logo')), findsOneWidget);
    expect(find.text('Start Focus').hitTestable(), findsOneWidget);
    expect(find.text('Baby Time').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone flow: focus, interrupt, resume, handoff, metrics', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryStore();
    await tester.pumpWidget(MaterialApp(home: RelayHome(store: store)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Start Focus'));
    await tester.tap(find.text('Start Focus'));
    await tester.pumpAndSettle();
    expect(find.text('Focus mode'), findsOneWidget);
    await tester.ensureVisible(find.text('Interruption'));
    await tester.tap(find.text('Interruption'));
    await tester.pumpAndSettle();
    expect(find.text('Interrupted'), findsNWidgets(2));
    expect(store.state.active!.interruption, isNotNull);
    await tester.tap(find.text('Resume Focus'));
    await tester.pumpAndSettle();
    expect(store.state.active!.interruption, isNull);
    await tester.ensureVisible(find.text('Baby Time'));
    await tester.tap(find.text('Baby Time'));
    await tester.pumpAndSettle();
    expect(store.state.active!.kind, ShiftKind.focus);
    await tester.tap(find.text('Baby 1'));
    await tester.pumpAndSettle();
    expect(store.state.active!.kind, ShiftKind.point);
    expect(store.state.active!.baby, Baby.chloe);
    expect(find.text('Taking care of Baby 1. Be here, fully.'), findsOneWidget);
    await tester.ensureVisible(find.text('Baby Time'));
    await tester.tap(find.text('Baby Time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Baby 2'));
    await tester.pumpAndSettle();
    expect(store.state.active!.baby, Baby.luca);
    await tester.ensureVisible(find.text('Baby Time'));
    await tester.tap(find.text('Baby Time'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('All children'));
    await tester.tap(find.text('All children'));
    await tester.pumpAndSettle();
    expect(store.state.active!.baby, Baby.both);
    await tester.tap(find.text('Insights'));
    await tester.pumpAndSettle();
    expect(find.text('Focus, planned & lived'), findsOneWidget);
    expect(find.text('Total work time'), findsOneWidget);
    expect(find.text('Baby 1'), findsOneWidget);
    expect(find.text('Baby 2'), findsOneWidget);
    await tester.ensureVisible(find.text('All time'));
    await tester.tap(find.text('All time'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All time'))
          .selected,
      isTrue,
    );
    await tester.tap(find.text('Choose dates'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('failed writes roll back the active mode', (tester) async {
    final store = MemoryStore()..fail = true;
    await tester.pumpWidget(MaterialApp(home: RelayHome(store: store)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Start Focus'));
    await tester.tap(find.text('Start Focus'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save this change. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('Ready when you are.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('active focus keeps interruption and account menu visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryStore();
    store.state.start(ShiftKind.focus, DateTime.now());

    await tester.pumpWidget(
      MaterialApp(
        home: RelayHome(store: store, onMenu: () {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Interruption').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Open account menu'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

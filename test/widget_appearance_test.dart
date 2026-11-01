import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/home_widget.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';
import 'package:relay/widget_appearance.dart';

class _AppearanceStore extends RelayStore {
  RelayState state = RelayState();
  bool fail = false;

  @override
  Future<RelayState> load() async => RelayState.fromJson(state.toJson());

  @override
  Future<void> save(RelayState value) async {
    if (fail) throw StateError('No save acknowledgement');
    state = RelayState.fromJson(value.toJson());
  }
}

class _AppearanceWidget extends RelayHomeWidget {
  bool failSync = false;
  String? source;
  WidgetColors? synced;

  @override
  bool get supported => false;

  @override
  Future<void> sync(RelayState state, String context, DateTime now) async {
    if (failSync) throw StateError('Launcher unavailable');
    source = context;
    synced = state.widgetColors;
  }
}

void main() {
  Future<void> open(
    WidgetTester tester,
    _AppearanceStore store,
    _AppearanceWidget widget,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      WidgetAppearance(store: store, homeWidget: widget),
                ),
              ),
              child: const Text('Open appearance'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open appearance'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'colors persist and save preserves the latest tracking and names',
    (tester) async {
      final store = _AppearanceStore();
      final widget = _AppearanceWidget();
      await open(tester, store, widget);
      await tester.ensureVisible(find.byTooltip('Work Time: Blue'));
      await tester.tap(find.byTooltip('Work Time: Blue'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<WidgetAppearancePreview>(
              find.byType(WidgetAppearancePreview),
            )
            .colors
            .work,
        0xFF2762B2,
      );

      // Another timer update while appearance is open must survive this save.
      store.state.childNames = ['Noah'];
      store.state.personalTimeEnabled = true;
      store.state.lastWidgetRequestId = 'latest-request';
      store.state.start(
        ShiftKind.point,
        DateTime(2026, 11, 1, 9),
        baby: Baby.chloe,
      );
      await tester.tap(find.text('Save widget colors'));
      await tester.pumpAndSettle();

      expect(store.state.widgetColors.work, 0xFF2762B2);
      expect(store.state.childNames, ['Noah']);
      expect(store.state.active?.kind, ShiftKind.point);
      expect(store.state.personalTimeEnabled, isTrue);
      expect(store.state.lastWidgetRequestId, 'latest-request');
      expect(widget.synced?.work, 0xFF2762B2);
      expect(widget.source, 'local');
      expect(find.text('Open appearance'), findsOneWidget);

      await tester.tap(find.text('Open appearance'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<WidgetAppearancePreview>(
              find.byType(WidgetAppearancePreview),
            )
            .colors
            .work,
        0xFF2762B2,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('each role has its own color and defaults can be restored', (
    tester,
  ) async {
    final store = _AppearanceStore();
    final widget = _AppearanceWidget();
    await open(tester, store, widget);
    await tester.tap(find.widgetWithText(ListTile, 'Baby Time'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Baby Time: Rose'));
    await tester.tap(find.byTooltip('Baby Time: Rose'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save widget colors'));
    await tester.pumpAndSettle();
    expect(store.state.widgetColors.work, const WidgetColors().work);
    expect(store.state.widgetColors.baby, 0xFFE9A7BD);

    await tester.tap(find.text('Open appearance'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Restore default colors'), 200);
    await tester.tap(find.text('Restore default colors'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save widget colors'));
    await tester.pumpAndSettle();
    expect(store.state.widgetColors.toJson(), const WidgetColors().toJson());
  });

  testWidgets('failed saves stay visible and preserve saved colors', (
    tester,
  ) async {
    final store = _AppearanceStore();
    await open(tester, store, _AppearanceWidget());
    await tester.ensureVisible(find.byTooltip('Work Time: Green'));
    await tester.tap(find.byTooltip('Work Time: Green'));
    store.fail = true;
    await tester.tap(find.text('Save widget colors'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save your colors. Please try again.'),
      findsOneWidget,
    );
    expect(store.state.widgetColors.work, const WidgetColors().work);
    expect(find.text('Save widget colors'), findsOneWidget);
  });

  testWidgets('a launcher sync error cannot roll back confirmed colors', (
    tester,
  ) async {
    final store = _AppearanceStore();
    await open(tester, store, _AppearanceWidget()..failSync = true);
    await tester.ensureVisible(find.byTooltip('Work Time: Slate'));
    await tester.tap(find.byTooltip('Work Time: Slate'));
    await tester.tap(find.text('Save widget colors'));
    await tester.pumpAndSettle();
    expect(store.state.widgetColors.work, 0xFF454857);
    expect(find.text('Open appearance'), findsOneWidget);
    expect(
      find.text('Could not save your colors. Please try again.'),
      findsNothing,
    );
  });
}

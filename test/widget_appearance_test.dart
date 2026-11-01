import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/home_widget.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';
import 'package:relay/widget_appearance.dart';

class _AppearanceStore extends RelayStore {
  RelayState state = RelayState();
  bool fail = false;
  int saves = 0;
  @override
  Future<RelayState> load() async => RelayState.fromJson(state.toJson());
  @override
  Future<void> save(RelayState value) async {
    saves++;
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
    _AppearanceWidget widget, {
    double textScale = 1,
    Size viewport = const Size(390, 844),
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
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

  Future<void> pickPart(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.byKey(const ValueKey('widget-part')));
    await tester.tap(find.byKey(const ValueKey('widget-part')));
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text(label).last),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> enterHex(
    WidgetTester tester,
    String value, {
    bool apply = true,
  }) async {
    final field = find.byKey(const ValueKey('widget-hex'));
    await tester.ensureVisible(field);
    await tester.enterText(field, value);
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    if (apply) {
      await tester.tap(find.byTooltip('Apply hex color'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> textMode(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(SegmentedButton<bool>));
    await tester.tap(find.text('Text'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'arbitrary background persists without overwriting newer tracking',
    (tester) async {
      final store = _AppearanceStore();
      final widget = _AppearanceWidget();
      await open(tester, store, widget);
      await enterHex(tester, '#123ABC', apply: false);
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
      expect(store.state.widgetColors.backgroundFor('work'), 0xFF123ABC);
      expect(store.state.childNames, ['Noah']);
      expect(store.state.active?.kind, ShiftKind.point);
      expect(store.state.personalTimeEnabled, isTrue);
      expect(store.state.lastWidgetRequestId, 'latest-request');
      expect(widget.synced?.backgroundFor('work'), 0xFF123ABC);
      expect(widget.source, 'local');
      await tester.tap(find.text('Open appearance'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<WidgetAppearancePreview>(
              find.byType(WidgetAppearancePreview),
            )
            .colors
            .backgroundFor('work'),
        0xFF123ABC,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'timer text, child buttons, all babies, arrows and messages keep separate colors',
    (tester) async {
      final store = _AppearanceStore()
        ..state = RelayState(childNames: ['Ava', 'Noah', 'Mia']);
      await open(tester, store, _AppearanceWidget());
      await pickPart(tester, 'Timer bar');
      await enterHex(tester, '#102030');
      await textMode(tester);
      await enterHex(tester, '#FEBC98');
      await pickPart(tester, 'Picker arrows and Cancel');
      await enterHex(tester, '#12121F');
      await tester.ensureVisible(find.byType(SegmentedButton<bool>));
      await tester.tap(find.text('Background'));
      await tester.pumpAndSettle();
      await pickPart(tester, 'Ava button');
      await enterHex(tester, '#37A9D4');
      await pickPart(tester, 'All babies');
      await enterHex(tester, '#563412');
      await pickPart(tester, 'Messages');
      await enterHex(tester, '#809010');
      await tester.tap(find.text('Save widget colors'));
      await tester.pumpAndSettle();
      final saved = store.state.widgetColors;
      expect(saved.backgroundFor('timer'), 0xFF102030);
      expect(saved.foregroundFor('timer'), 0xFFFEBC98);
      expect(saved.usesAutomaticText('timer'), isFalse);
      expect(saved.backgroundFor('child0'), 0xFF37A9D4);
      expect(saved.backgroundFor('allBabies'), 0xFF563412);
      expect(saved.foregroundFor('navigation'), 0xFF12121F);
      expect(saved.backgroundFor('notice'), 0xFF809010);
      await tester.tap(find.text('Open appearance'));
      await tester.pumpAndSettle();
      await pickPart(tester, 'Timer bar');
      final preview = tester.widget<WidgetAppearancePreview>(
        find.byType(WidgetAppearancePreview),
      );
      expect(preview.colors.foregroundFor('timer'), 0xFFFEBC98);
      expect(find.text('Work time · 00:12:34'), findsOneWidget);
    },
  );

  testWidgets('invalid hex cannot be committed', (tester) async {
    final store = _AppearanceStore();
    await open(tester, store, _AppearanceWidget());
    await enterHex(tester, '#12XX99', apply: false);
    await tester.tap(find.text('Save widget colors'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter six hex digits, for example #6450CA.'),
      findsOneWidget,
    );
    expect(store.saves, 0);
    expect(
      store.state.widgetColors.backgroundFor('work'),
      const WidgetColors().backgroundFor('work'),
    );
  });

  testWidgets(
    'automatic text resets only that override and defaults restore the full theme',
    (tester) async {
      final store = _AppearanceStore();
      store.state.widgetColors = const WidgetColors()
          .withBackground('work', 0xFF809080)
          .withText('work', 0xFF110033)
          .withBackground('timer', 0xFF102030)
          .withText('timer', 0xFFEEEE00);
      await open(tester, store, _AppearanceWidget());
      await textMode(tester);
      await tester.ensureVisible(find.text('Automatic text contrast'));
      await tester.tap(find.text('Automatic text contrast'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save widget colors'));
      await tester.pumpAndSettle();
      expect(store.state.widgetColors.usesAutomaticText('work'), isTrue);
      expect(store.state.widgetColors.backgroundFor('work'), 0xFF809080);
      expect(store.state.widgetColors.foregroundFor('timer'), 0xFFEEEE00);
      await tester.tap(find.text('Open appearance'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Restore default colors'));
      await tester.tap(find.text('Restore default colors'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save widget colors'));
      await tester.pumpAndSettle();
      expect(store.state.widgetColors.toJson(), const WidgetColors().toJson());
      expect(store.state.widgetColors.resume, 0xFF6450CA);
      expect(store.state.widgetColors.end, 0xFFDDEAAD);
    },
  );

  testWidgets('RGB sliders let the parent adjust an arbitrary color', (
    tester,
  ) async {
    final store = _AppearanceStore();
    await open(tester, store, _AppearanceWidget());
    await enterHex(tester, '#123456');
    final slider = find.byKey(const ValueKey('widget-red'));
    await tester.ensureVisible(slider);
    await tester.drag(slider, const Offset(35, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save widget colors'));
    await tester.pumpAndSettle();
    expect(store.state.widgetColors.work & 0x00FFFF, 0x3456);
    expect((store.state.widgetColors.work >> 16) & 255, isNot(0x12));
  });

  testWidgets('failed saves preserve saved colors and tracking', (
    tester,
  ) async {
    final store = _AppearanceStore();
    store.state.start(ShiftKind.focus, DateTime(2026, 11, 1, 9));
    await open(tester, store, _AppearanceWidget());
    await enterHex(tester, '#BAD123');
    store.fail = true;
    await tester.tap(find.text('Save widget colors'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save your colors. Please try again.'),
      findsOneWidget,
    );
    expect(store.state.widgetColors.work, const WidgetColors().work);
    expect(store.state.active?.kind, ShiftKind.focus);
    expect(find.text('Save widget colors'), findsOneWidget);
  });

  testWidgets('launcher sync errors cannot undo confirmed custom colors', (
    tester,
  ) async {
    final store = _AppearanceStore();
    await open(tester, store, _AppearanceWidget()..failSync = true);
    await enterHex(tester, '#998877');
    await tester.tap(find.text('Save widget colors'));
    await tester.pumpAndSettle();
    expect(store.state.widgetColors.work, 0xFF998877);
    expect(find.text('Open appearance'), findsOneWidget);
  });

  testWidgets(
    'compact phones can edit configured children and show baby time',
    (tester) async {
      final store = _AppearanceStore()
        ..state = RelayState(childNames: ['Ava', 'Noah', 'Mia']);
      await open(tester, store, _AppearanceWidget());
      tester.view.physicalSize = const Size(320, 640);
      await tester.pumpAndSettle();
      await pickPart(tester, 'Mia button');
      expect(find.text('Mia time · 00:12:34'), findsOneWidget);
      await enterHex(tester, '#A12B3C');
      await tester.tap(find.text('Save widget colors'));
      await tester.pumpAndSettle();
      expect(store.state.widgetColors.backgroundFor('child2'), 0xFFA12B3C);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact editor supports larger text and All babies mode', (
    tester,
  ) async {
    final store = _AppearanceStore()
      ..state = RelayState(childNames: ['Ava', 'Noah']);
    await open(
      tester,
      store,
      _AppearanceWidget(),
      textScale: 1.3,
      viewport: const Size(320, 640),
    );
    await pickPart(tester, 'All babies');
    expect(find.text('All babies time · 00:12:34'), findsOneWidget);
    await enterHex(tester, '#ABCDEF');
    await tester.tap(find.text('Save widget colors'));
    await tester.pumpAndSettle();
    expect(store.state.widgetColors.backgroundFor('allBabies'), 0xFFABCDEF);
    expect(tester.takeException(), isNull);
  });
}

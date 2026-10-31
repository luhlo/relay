import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/home_widget.dart';
import 'package:relay/main.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';

class WidgetStore extends RelayStore {
  RelayState state = RelayState();
  Completer<void>? saving;
  bool fail = false;

  @override
  Future<RelayState> load() async => RelayState.fromJson(state.toJson());

  @override
  Future<void> save(RelayState value) async {
    await saving?.future;
    if (fail) throw StateError('Save failed');
    state = RelayState.fromJson(value.toJson());
  }
}

class WidgetBridge extends RelayHomeWidget {
  final events = StreamController<void>.broadcast();
  Map<String, dynamic>? pending;
  Map<String, dynamic>? snapshot;

  @override
  Stream<void> get actions => events.stream;

  @override
  Future<Map<String, dynamic>?> takeAction() async {
    final action = pending;
    pending = null;
    return action;
  }

  @override
  Future<void> sync(RelayState state, String context, DateTime now) async {
    snapshot = widgetSnapshot(state, context, now);
  }
}

void main() {
  testWidgets('cold widget action saves Work Time and publishes its timer', (
    tester,
  ) async {
    final store = WidgetStore();
    final bridge = WidgetBridge()
      ..pending = {'context': 'local', 'action': 'work'};
    await tester.pumpWidget(
      MaterialApp(
        home: RelayHome(store: store, homeWidget: bridge),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.state.active!.kind, ShiftKind.focus);
    expect(bridge.snapshot!['status'], 'work');
    expect(bridge.snapshot!['running'], isTrue);
    await tester.pumpWidget(const SizedBox());
    await bridge.events.close();
  });

  testWidgets(
    'a widget action arriving during save is drained after acknowledgment',
    (tester) async {
      final store = WidgetStore();
      final bridge = WidgetBridge();
      await tester.pumpWidget(
        MaterialApp(
          home: RelayHome(store: store, homeWidget: bridge),
        ),
      );
      await tester.pumpAndSettle();
      final save = Completer<void>();
      store.saving = save;
      await tester.ensureVisible(find.text('Start Focus'));
      await tester.tap(find.text('Start Focus'));
      await tester.pump();
      bridge.pending = {'context': 'local', 'action': 'baby', 'babyIndex': -1};
      bridge.events.add(null);
      await tester.pump();
      expect(store.state.active, isNull);
      save.complete();
      await tester.pumpAndSettle();
      expect(store.state.active!.kind, ShiftKind.point);
      expect(store.state.active!.baby, Baby.both);
      expect(bridge.snapshot!['subtitle'], 'All babies');
      await tester.pumpWidget(const SizedBox());
      await bridge.events.close();
    },
  );

  testWidgets(
    'failed widget writes preserve the saved timer and report failure',
    (tester) async {
      final store = WidgetStore()..fail = true;
      final bridge = WidgetBridge()
        ..pending = {'context': 'local', 'action': 'work'};
      await tester.pumpWidget(
        MaterialApp(
          home: RelayHome(store: store, homeWidget: bridge),
        ),
      );
      await tester.pumpAndSettle();
      expect(store.state.active, isNull);
      expect(bridge.snapshot!['status'], 'idle');
      expect(
        find.text('Could not save this change. Please try again.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await bridge.events.close();
    },
  );
}

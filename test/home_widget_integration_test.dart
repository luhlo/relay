import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/home_widget.dart';
import 'package:relay/main.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';

class WidgetStore extends RelayStore {
  RelayState state = RelayState();
  @override
  Future<RelayState> load() async => RelayState.fromJson(state.toJson());
  @override
  Future<void> save(RelayState value) async {
    state = RelayState.fromJson(value.toJson());
  }
}

class WidgetBridge extends RelayHomeWidget {
  Map<String, dynamic>? snapshot;
  @override
  bool get supported => true;
  @override
  Future<void> sync(RelayState state, String context, DateTime now) async {
    snapshot = widgetSnapshot(state, context, now);
  }
}

void main() {
  testWidgets(
    'returning to Relay reloads time saved by the background widget',
    (tester) async {
      final store = WidgetStore();
      final bridge = WidgetBridge();
      await tester.pumpWidget(
        MaterialApp(
          home: RelayHome(store: store, homeWidget: bridge),
        ),
      );
      await tester.pumpAndSettle();
      expect(bridge.snapshot!['status'], 'idle');
      // A different engine saved while the foreground app was paused.
      store.state.start(ShiftKind.focus, DateTime.now());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Focus mode'), findsOneWidget);
      expect(bridge.snapshot!['status'], 'work');
      await tester.pumpWidget(const SizedBox());
    },
  );
}

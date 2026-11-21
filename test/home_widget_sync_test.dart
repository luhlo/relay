import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/home_widget.dart';
import 'package:relay/model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('relay.test.widget.sync');
  late List<MethodCall> calls;
  late RelayHomeWidget widget;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    widget = RelayHomeWidget(channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'ordinary clock snapshots omit cloud flags to preserve queued sync',
    () async {
      await widget.sync(RelayState(), 'cloud:owner', DateTime(2026));
      final update = calls.single.arguments as Map;
      expect(update.containsKey('syncPending'), isFalse);
      expect(update.containsKey('syncBlocked'), isFalse);
    },
  );

  test(
    'durable save sends explicit pending and blocked state to native',
    () async {
      await widget.sync(
        RelayState(),
        'cloud:owner',
        DateTime(2026),
        syncPending: true,
        syncBlocked: false,
      );
      final update = calls.single.arguments as Map;
      expect(update['syncPending'], isTrue);
      expect(update['syncBlocked'], isFalse);
      expect(update['context'], 'cloud:owner');
    },
  );

  test(
    'sync request queues network work through a separate native method',
    () async {
      await widget.requestCloudSync();
      expect(calls.single.method, 'requestCloudSync');
      expect(calls.single.arguments, isNull);
    },
  );
}

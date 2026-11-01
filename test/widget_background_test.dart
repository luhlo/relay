import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/home_widget.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';
import 'package:relay/widget_background.dart';

class _BackgroundStore extends RelayStore {
  RelayState state = RelayState();
  int saves = 0;
  bool failSave = false;

  @override
  Future<RelayState> load() async => RelayState.fromJson(state.toJson());

  @override
  Future<void> save(RelayState state) async {
    saves++;
    if (failSave) throw StateError('Disk write was not acknowledged');
    this.state = RelayState.fromJson(state.toJson());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.relay.relay/widget_background');
  late _BackgroundStore store;
  Map<String, dynamic>? job;
  late List<Map<String, dynamic>> completions;

  Map<String, dynamic> action(String kind, String id) {
    final snapshot = widgetSnapshot(store.state, 'local', DateTime.now());
    return {
      'context': 'local',
      'action': kind,
      'requestId': id,
      'expectedStatus': snapshot['status'],
      'sessionStart': snapshot['sessionStart'],
    };
  }

  Future<void> run() => runWidgetBackground(
    openStore: (context) async {
      expect(context, 'local');
      return store;
    },
  );

  setUp(() {
    store = _BackgroundStore();
    job = null;
    completions = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getAction':
              return job;
            case 'complete':
              completions.add(Map<String, dynamic>.from(call.arguments as Map));
              return null;
            default:
              throw StateError('Unexpected method ${call.method}');
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'headless work, interruption and end save without mounting UI',
    () async {
      job = action('work', 'work-1');
      await run();
      expect(store.state.active?.kind, ShiftKind.focus);
      expect(completions.last['success'], isTrue);
      expect((completions.last['snapshot'] as Map)['status'], 'work');

      job = action('interruption', 'interruption-1');
      await run();
      expect(store.state.active?.interruption, isNotNull);
      expect(completions.last['success'], isTrue);
      expect((completions.last['snapshot'] as Map)['running'], isTrue);

      job = action('end', 'end-1');
      await run();
      expect(store.state.active, isNull);
      expect(store.state.sessions.single.interruptions.single.end, isNotNull);
      expect(completions.last['success'], isTrue);
      expect((completions.last['snapshot'] as Map)['status'], 'idle');
      expect(store.saves, 3);
      expect(completions, hasLength(3));
      expect(store.state.lastWidgetRequestId, 'end-1');
    },
  );

  test('a retried receipt never toggles or saves a second time', () async {
    store.state.start(ShiftKind.focus, DateTime.now());
    job = action('interruption', 'same-request');
    await run();
    final original = store.state.active!.interruption!.start;
    await run();
    expect(store.state.active!.interruption!.start, original);
    expect(store.state.active!.interruptions, hasLength(1));
    expect(store.saves, 1);
    expect(completions, hasLength(2));
    expect(completions.every((result) => result['success'] == true), isTrue);
  });

  test('an unacknowledged save never publishes the mutated snapshot', () async {
    store.failSave = true;
    job = action('work', 'unconfirmed');
    await run();
    expect(store.state.active, isNull);
    expect(store.state.lastWidgetRequestId, isNull);
    expect(completions.single['success'], isFalse);
    expect(completions.single.containsKey('snapshot'), isFalse);
    expect(completions.single['error'], contains('Could not confirm the save'));
  });

  test('malformed and unknown contexts never open storage', () async {
    var opened = false;
    Future<RelayStore> unexpectedStore(String _) async {
      opened = true;
      return store;
    }

    job = {'context': 'local', 'action': 'work'};
    await runWidgetBackground(openStore: unexpectedStore);
    expect(opened, isFalse);
    expect(completions.single['success'], isFalse);

    job = {'context': 'not-an-account', 'action': 'work', 'requestId': 'bad'};
    await runWidgetBackground(openStore: unexpectedStore);
    expect(opened, isFalse);
    expect(completions.last['success'], isFalse);
    expect(store.saves, 0);
  });
}

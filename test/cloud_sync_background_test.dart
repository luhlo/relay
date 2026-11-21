import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/account_cache.dart';
import 'package:relay/cloud.dart';
import 'package:relay/cloud_sync_background.dart';
import 'package:relay/model.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

class _SyncStore extends CloudStore {
  _SyncStore()
    : super(
        SupabaseClient('https://relay.example.invalid', 'test-key'),
        'owner',
        ['Baby 1'],
        householdId: 'household',
      );

  bool pending = true;
  int loads = 0;
  int syncs = 0;
  bool disposed = false;
  Object? loadError;
  Object? syncError;
  CloudSyncPhase afterSync = CloudSyncPhase.synced;

  @override
  Future<RelayState> load() async {
    loads++;
    if (loadError case final Object error) throw error;
    return RelayState();
  }

  @override
  Future<bool> hasPendingChanges() async => pending;

  @override
  Future<void> synchronize() async {
    syncs++;
    if (syncError case final Object error) throw error;
    pending = afterSync != CloudSyncPhase.synced;
    syncStatus.value = CloudSyncStatus(phase: afterSync, pending: pending);
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.relay.relay/cloud_sync_background');
  late _SyncStore store;
  Object? action;
  late List<Map<String, dynamic>> replies;
  int opens = 0;

  Future<void> run() => runCloudSyncBackground(
    openStore: (context) async {
      expect(context, 'cloud:owner');
      opens++;
      return store;
    },
  );

  setUp(() {
    store = _SyncStore();
    action = {'context': 'cloud:owner'};
    replies = [];
    opens = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getAction':
              return action;
            case 'complete':
              replies.add(Map<String, dynamic>.from(call.arguments as Map));
              return null;
            default:
              throw StateError('Unexpected call ${call.method}');
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (!store.disposed) store.dispose();
  });

  test(
    'drains pending writes without returning a stale widget snapshot',
    () async {
      await run();
      expect(opens, 1);
      expect(store.loads, 1);
      expect(store.syncs, 1);
      expect(store.disposed, isTrue);
      expect(replies.single, {
        'context': 'cloud:owner',
        'pending': false,
        'blocked': false,
      });
      expect(replies.single.containsKey('snapshot'), isFalse);
    },
  );

  test('an already-drained queue skips network sync', () async {
    store.pending = false;
    await run();
    expect(store.syncs, 0);
    expect(replies.single['pending'], isFalse);
  });

  for (final invalid in <Object?>[
    null,
    <String, dynamic>{},
    {'context': 'local'},
    {'context': 'cloud:'},
  ]) {
    test(
      'invalid or signed-out action $invalid cannot open account data',
      () async {
        action = invalid;
        await run();
        expect(opens, 0);
        expect(replies.single, {
          'context': null,
          'pending': true,
          'blocked': true,
        });
      },
    );
  }

  for (final phase in [
    CloudSyncPhase.conflict,
    CloudSyncPhase.needsSignIn,
    CloudSyncPhase.error,
  ]) {
    test('$phase keeps the outbox and requires app review', () async {
      store.afterSync = phase;
      await run();
      expect(replies.single['pending'], isTrue);
      expect(replies.single['blocked'], isTrue);
    });
  }

  for (final phase in [CloudSyncPhase.pending, CloudSyncPhase.offline]) {
    test('$phase keeps pending changes retryable', () async {
      store.afterSync = phase;
      await run();
      expect(replies.single['pending'], isTrue);
      expect(replies.single['blocked'], isFalse);
    });
  }

  test(
    'timeout preserves the durable outbox and does not expose details',
    () async {
      store.syncError = TimeoutException('private server details');
      await run();
      expect(replies.single, {
        'context': 'cloud:owner',
        'pending': true,
        'blocked': false,
      });
    },
  );

  for (final error in [
    CloudScopeException(),
    CloudSaveException('Sign in to reconnect this account'),
    const AccountMembershipUnavailable(),
    const AuthException('Sign in again', statusCode: '401'),
  ]) {
    test(
      'account or storage issue blocks retries for review: $error',
      () async {
        store.loadError = error;
        await run();
        expect(store.syncs, 0);
        expect(replies.single['pending'], isTrue);
        expect(replies.single['blocked'], isTrue);
      },
    );
  }
}

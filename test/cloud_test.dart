import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/cloud.dart';
import 'package:relay/cloud_merge.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Server {
  int revision = 0, reads = 0, writes = 0, requests = 0;
  bool offline = false, loseAcknowledgement = false;
  String household = 'household-one';
  CloudJson payload = RelayState(childNames: ['Ava', 'Noah']).toJson();
  final receipts = <String, int>{};
  final payloads = <String, CloudJson>{};
  Completer<void>? applied, release, secondRequested;
  String? rpcError;

  Future<SupabaseClient> client({String userId = 'owner-id'}) async {
    final client = SupabaseClient(
      'https://relay.example.invalid',
      'public-test-key',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'access_token': 'test-token',
              'token_type': 'bearer',
              'expires_in': 3600,
              'refresh_token': 'test-refresh',
              'user': {
                'id': userId,
                'aud': 'authenticated',
                'email': 'test@example.invalid',
                'created_at': '2026-01-01T00:00:00Z',
                'app_metadata': <String, dynamic>{},
                'user_metadata': <String, dynamic>{},
              },
            }),
            200,
            request: request,
          );
        }
        if (offline) throw http.ClientException('Offline', request.url);
        if (request.url.path.endsWith('/household_members')) {
          return http.Response(
            jsonEncode({'household_id': household}),
            200,
            request: request,
          );
        }
        if (request.url.path.endsWith('/parent_records')) {
          reads++;
          expect(request.url.queryParameters['user_id'], 'eq.$userId');
          return http.Response(
            jsonEncode({
              'revision': revision,
              'payload': payload,
              'household_members': {'household_id': household},
            }),
            200,
            request: request,
          );
        }
        expect(request.url.path, '/rest/v1/rpc/relay_sync_records');
        requests++;
        if (requests == 2) secondRequested?.complete();
        final body = jsonDecode(request.body) as Map;
        expect(body.containsKey('user_id'), isFalse);
        if (rpcError != null) return _error(request, rpcError!);
        if (body['expected_household_id'] != household) {
          return _error(request, '42501');
        }
        final id = body['mutation_id'] as String;
        final next = Map<String, dynamic>.from(body['new_payload'] as Map);
        if (receipts.containsKey(id)) {
          expect(cloudJsonEqual(payloads[id], next), isTrue);
        } else {
          if (body['expected_revision'] != revision) {
            return _error(request, '40001');
          }
          payload = copyCloudJson(next);
          writes++;
          revision++;
          receipts[id] = revision;
          payloads[id] = copyCloudJson(next);
        }
        applied?.complete();
        applied = null;
        if (release != null) await release!.future;
        if (loseAcknowledgement) {
          loseAcknowledgement = false;
          throw http.ClientException('Acknowledgement lost');
        }
        return http.Response(
          jsonEncode({
            'applied_revision': receipts[id],
            'revision': revision,
            'payload': payload,
          }),
          200,
          request: request,
        );
      }),
    );
    await client.auth.signInWithPassword(
      email: 'test@example.invalid',
      password: 'test-password',
    );
    addTearDown(client.dispose);
    return client;
  }

  http.Response _error(http.Request request, String code) => http.Response(
    jsonEncode({'code': code, 'message': 'Simulated server response'}),
    code == '40001' ? 409 : 403,
    request: request,
  );

  CloudStore store(SupabaseClient client, CloudCache cache, {String? scope}) {
    final result = CloudStore(
      client,
      client.auth.currentUser!.id,
      ['Ava', 'Noah'],
      householdId: scope ?? household,
      cache: cache,
      networkTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(result.dispose);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'signed-in writes commit locally without waiting for or calling the server',
    () async {
      final server = _Server(), cache = MemoryCloudCache();
      final client = await server.client();
      final store = server.store(client, cache);
      final state = await store.load();
      expect(state.babyName(Baby.chloe), 'Ava');
      server.offline = true;
      state.start(ShiftKind.focus, DateTime.utc(2026, 11, 19, 9));
      await store.save(state);
      expect(server.writes, 0);
      expect(store.revision, 0);
      expect(store.syncStatus.value.phase, CloudSyncPhase.pending);
      final restored = server.store(client, cache);
      final loaded = await restored.load();
      expect(loaded.active!.kind, ShiftKind.focus);
      expect(server.reads, 1);
      await restored.synchronize();
      expect(restored.syncStatus.value.phase, CloudSyncPhase.offline);
      expect(await restored.hasPendingChanges(), isTrue);
      server.offline = false;
      await restored.synchronize();
      expect(server.writes, 1);
      expect(restored.revision, 1);
      expect(restored.syncStatus.value.phase, CloudSyncPhase.synced);
    },
  );

  test('unacknowledged commits are retried with the same mutation id after restart', () async {
    final server = _Server(), cache = MemoryCloudCache();
    final client = await server.client();
    final store = server.store(client, cache);
    final state = (await store.load())..alerts = true;
    await store.save(state);
    server.loseAcknowledgement = true;
    await store.synchronize();
    expect(server.writes, 1);
    expect(await store.hasPendingChanges(), isTrue);
    final queued = await cache.read('owner-id');
    final id = (queued!['flight'] as Map)['id'];
    final restored = server.store(client, cache);
    await restored.load();
    await restored.synchronize();
    expect(server.writes, 1);
    expect(server.receipts.keys, contains(id));
    expect(await restored.hasPendingChanges(), isFalse);
  });

  test(
    'foreground and headless engines share one durable in-flight mutation',
    () async {
      final server = _Server(), cache = MemoryCloudCache();
      final client = await server.client();
      final first = server.store(client, cache),
          second = server.store(client, cache);
      final state = (await first.load())..alerts = true;
      await second.load();
      await first.save(state);
      server.applied = Completer<void>();
      final applied = server.applied!.future;
      server.secondRequested = Completer<void>();
      server.release = Completer<void>();
      final a = first.synchronize();
      await applied;
      final b = second.synchronize();
      await server.secondRequested!.future;
      server.release!.complete();
      server.release = null;
      await Future.wait([a, b]);
      expect(server.writes, 1);
      expect(server.receipts, hasLength(1));
      expect(await first.hasPendingChanges(), isFalse);
      expect(await second.hasPendingChanges(), isFalse);
    },
  );

  test('a lost acknowledgement reconciles the latest remote copy before newer edits upload', () async {
    final server = _Server(), cache = MemoryCloudCache();
    final client = await server.client();
    final first = server.store(client, cache);
    var state = (await first.load())..alerts = true;
    await first.save(state);
    server.loseAcknowledgement = true;
    await first.synchronize();
    final other = server.store(client, MemoryCloudCache());
    final remoteEdit = (await other.load())..dailyPersonalHours = 5;
    await other.save(remoteEdit);
    await other.synchronize();
    state = (await first.load())..alerts = false;
    await first.save(state);
    await first.synchronize();
    expect(server.writes, 3);
    expect(server.payload['dailyPersonalHours'], 5);
    expect(server.payload['alerts'], isFalse);
    expect(await first.hasPendingChanges(), isFalse);
  });

  test('newer device edits during a network request remain queued and are synced next', () async {
    final server = _Server(), cache = MemoryCloudCache();
    final client = await server.client();
    final foreground = server.store(client, cache),
        widget = server.store(client, cache);
    var state = (await foreground.load())..alerts = true;
    await foreground.save(state);
    server.applied = Completer<void>();
    final applied = server.applied!.future;
    server.release = Completer<void>();
    final syncing = foreground.synchronize();
    await applied;
    state = (await widget.load())..dailyPersonalHours = 4;
    await widget.save(state);
    server.release!.complete();
    server.release = null;
    await syncing;
    expect(server.payload['alerts'], isTrue);
    expect(server.payload['dailyPersonalHours'], 4);
    expect(server.writes, 2);
    expect(await foreground.hasPendingChanges(), isFalse);
  });

  test(
    'local CAS prevents stale foreground state from replacing a widget action',
    () async {
      final server = _Server(), cache = MemoryCloudCache();
      final client = await server.client();
      final foreground = server.store(client, cache),
          widget = server.store(client, cache);
      final old = await foreground.load();
      final current = (await widget.load())..alerts = true;
      await widget.save(current);
      old.dailyPersonalHours = 6;
      await expectLater(
        foreground.save(old),
        throwsA(isA<LocalSaveConflict>()),
      );
      final restored = await widget.load();
      expect(restored.alerts, isTrue);
      expect(restored.dailyPersonalHours, 3);
    },
  );

  test('background peek never advances the foreground save baseline or uses the network', () async {
    final server = _Server(), cache = MemoryCloudCache();
    final client = await server.client();
    final foreground = server.store(client, cache),
        widget = server.store(client, cache);
    final stale = await foreground.load();
    final next = (await widget.load())..alerts = true;
    await widget.save(next);
    final reads = server.reads;
    server.offline = true;
    final peek = await foreground.peekCachedState();
    expect(peek.alerts, isTrue);
    expect(server.reads, reads);
    stale.dailyPersonalHours = 6;
    await expectLater(
      foreground.save(stale),
      throwsA(isA<LocalSaveConflict>()),
    );
    peek.dailyPersonalHours = 10;
    expect((await widget.load()).dailyPersonalHours, 3);
  });

  test(
    'separate devices merge disjoint preferences instead of overwriting',
    () async {
      final server = _Server();
      final client = await server.client();
      final a = server.store(client, MemoryCloudCache()),
          b = server.store(client, MemoryCloudCache());
      final here = (await a.load())..alerts = true;
      final there = (await b.load())..dailyPersonalHours = 5;
      await a.save(here);
      await b.save(there);
      await a.synchronize();
      await b.synchronize();
      expect(server.payload['alerts'], isTrue);
      expect(server.payload['dailyPersonalHours'], 5);
      expect(b.syncStatus.value.phase, CloudSyncPhase.synced);
    },
  );

  test(
    'colliding timers stop synchronization and preserve both conflict copies',
    () async {
      final server = _Server();
      final client = await server.client();
      final a = server.store(client, MemoryCloudCache()),
          b = server.store(client, MemoryCloudCache());
      final here = await a.load(), there = await b.load();
      here.start(ShiftKind.focus, DateTime.utc(2026, 11, 19, 9));
      there.start(
        ShiftKind.point,
        DateTime.utc(2026, 11, 19, 9, 1),
        baby: Baby.chloe,
      );
      await a.save(here);
      await b.save(there);
      await a.synchronize();
      await b.synchronize();
      expect(server.writes, 1);
      expect(b.syncStatus.value.phase, CloudSyncPhase.conflict);
      final conflict = await b.conflict();
      expect(conflict, isNotNull);
      expect(
        RelayState.fromJson(conflict!.local).active!.kind,
        ShiftKind.point,
      );
      expect(
        RelayState.fromJson(conflict.remote).active!.kind,
        ShiftKind.focus,
      );
      // Local tracking remains usable while the conflict is awaiting review.
      final local = (await b.load())..finish(DateTime.utc(2026, 11, 19, 9, 10));
      await b.save(local);
      await b.synchronize();
      expect(server.writes, 1);
      await b.resolveConflict(keepLocal: false);
      expect((await b.recoveryCopies()), hasLength(2));
      expect((await b.load()).active!.kind, ShiftKind.focus);
      expect(await b.hasPendingChanges(), isFalse);
    },
  );

  test('explicit local conflict choice archives cloud copy and retries through CAS', () async {
    final server = _Server();
    final client = await server.client();
    final a = server.store(client, MemoryCloudCache()),
        b = server.store(client, MemoryCloudCache());
    final here = (await a.load())..dailyPersonalHours = 4;
    final there = (await b.load())..dailyPersonalHours = 6;
    await a.save(here);
    await b.save(there);
    await a.synchronize();
    await b.synchronize();
    expect(b.syncStatus.value.phase, CloudSyncPhase.conflict);
    await b.resolveConflict(keepLocal: true);
    await b.synchronize();
    expect(server.payload['dailyPersonalHours'], 6);
    expect((await b.recoveryCopies()), hasLength(2));
  });

  test(
    'same-account household changes block an old outbox until explicit review',
    () async {
      final server = _Server(), cache = MemoryCloudCache();
      final client = await server.client();
      final old = server.store(client, cache);
      final state = (await old.load())..alerts = true;
      await old.save(state);
      server.household = 'household-two';
      server.payload = RelayState(childNames: ['Ava', 'Noah']).toJson();
      final next = server.store(client, cache);
      await expectLater(next.load(), throwsA(isA<CloudScopeException>()));
      await next.synchronize();
      expect(next.syncStatus.value.phase, CloudSyncPhase.error);
      expect(server.writes, 0);
      await next.useCurrentHousehold();
      expect(await next.hasPendingChanges(), isFalse);
      final backups = await next.recoveryCopies();
      expect(backups, hasLength(2));
      await expectLater(
        next.restoreRecoveryCopy(backups.first.id),
        throwsA(isA<CloudScopeException>()),
      );
    },
  );

  test('clean-cache sync never imports a different household after same-user rejoin', () async {
    final server = _Server(), cache = MemoryCloudCache();
    final client = await server.client();
    final store = server.store(client, cache);
    await store.load();
    server.household = 'new-household';
    server.payload = (RelayState()..dailyPersonalHours = 9).toJson();
    await store.synchronize();
    expect(store.syncStatus.value.phase, CloudSyncPhase.error);
    expect((await store.load()).dailyPersonalHours, 3);
    expect(server.writes, 0);
    expect((await cache.read('owner-id'))!['householdId'], 'household-one');
  });

  test(
    '401/403 membership failures retain the queued state and pause sync',
    () async {
      final server = _Server(), cache = MemoryCloudCache();
      final client = await server.client();
      final store = server.store(client, cache);
      final state = (await store.load())..alerts = true;
      await store.save(state);
      server.rpcError = '42501';
      await store.synchronize();
      expect(store.syncStatus.value.phase, CloudSyncPhase.needsSignIn);
      expect(await store.hasPendingChanges(), isTrue);
      expect((await store.load()).alerts, isTrue);
      expect(store.syncStatus.value.phase, CloudSyncPhase.needsSignIn);
    },
  );

  test(
    'other signed-in identities cannot read or change an account cache',
    () async {
      final server = _Server(), cache = MemoryCloudCache();
      final owner = await server.client();
      final store = server.store(owner, cache);
      final state = (await store.load())..alerts = true;
      await store.save(state);
      final other = await server.client(userId: 'other-parent');
      final wrong = CloudStore(
        other,
        'owner-id',
        ['Ava', 'Noah'],
        cache: cache,
        householdId: server.household,
      );
      addTearDown(wrong.dispose);
      await expectLater(wrong.load(), throwsA(isA<CloudSaveException>()));
      await expectLater(wrong.save(state), throwsA(isA<CloudSaveException>()));
      expect((await store.load()).alerts, isTrue);
    },
  );

  test('a first-ever account needs an initial connection instead of inventing history', () async {
    final server = _Server(), cache = MemoryCloudCache();
    final client = await server.client();
    server.offline = true;
    final store = server.store(client, cache);
    await expectLater(store.load(), throwsA(isA<CloudSaveException>()));
    expect(await cache.read('owner-id'), isNull);
  });

  test('import guard prevents replacing cloud history', () {
    final state = RelayState();
    expect(canImportRecords(state), isTrue);
    state.start(ShiftKind.focus, DateTime(2026, 9, 20));
    expect(canImportRecords(state), isFalse);
  });

  test(
    'cloud timestamps retain instants and household names after serialization',
    () {
      final state = RelayState(childOne: 'Ava', childTwo: 'Noah');
      final instant = DateTime.parse('2026-09-20T15:00:00-05:00');
      state.start(ShiftKind.point, instant, baby: Baby.both);
      final json = state.toJson();
      expect((json['sessions'][0]['start'] as String).endsWith('Z'), isTrue);
      final copy = RelayState.fromJson(json);
      expect(copy.sessions.single.start.isAtSameMomentAs(instant), isTrue);
      expect(copy.babyName(Baby.chloe), 'Ava');
    },
  );
}

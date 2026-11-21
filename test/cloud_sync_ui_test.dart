import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/cloud.dart';
import 'package:relay/cloud_sync_ui.dart';
import 'package:relay/model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<CloudStore> _store(WidgetTester tester, {bool conflict = true}) async {
  final client = (await tester.runAsync(
    () async => SupabaseClient(
      'https://relay.example.invalid',
      'test-public-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    ),
  ))!;
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final token =
      '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': 'owner', 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.signature';
  await client.auth.setInitialSession(
    jsonEncode({
      'access_token': token,
      'refresh_token': 'test-refresh',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': 'owner',
        'aud': 'authenticated',
        'created_at': '2026-01-01T00:00:00Z',
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
      },
    }),
  );
  addTearDown(() => tester.runAsync(client.dispose));
  final cache = MemoryCloudCache();
  final local = RelayState(dailyPersonalHours: 3).toJson();
  final remote = RelayState(dailyPersonalHours: 5).toJson();
  await cache.update(
    'owner',
    (_) => {
      'schema': 1,
      'generation': 1,
      'householdId': 'household',
      'baseRevision': 1,
      'base': RelayState().toJson(),
      'current': local,
      'flight': null,
      'conflict': conflict
          ? {
              'base': RelayState().toJson(),
              'local': local,
              'remote': remote,
              'remoteRevision': 2,
              'paths': ['dailyPersonalHours'],
            }
          : null,
      'backups': conflict
          ? []
          : [
              {
                'id': 'saved-copy',
                'createdAt': '2026-11-19T12:00:00Z',
                'label': 'Previous saved version',
                'householdId': 'household',
                'payload': remote,
              },
            ],
    },
  );
  final store = CloudStore(
    client,
    'owner',
    ['Baby 1'],
    householdId: 'household',
    cache: cache,
  );
  addTearDown(store.dispose);
  await store.load();
  return store;
}

void main() {
  testWidgets('sync labels and buttons fit a compact phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await _store(tester);
    var syncs = 0, reviews = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudSyncBanner(
            store: store,
            onSync: () => syncs++,
            onReview: () => reviews++,
          ),
        ),
      ),
    );
    for (final phase in CloudSyncPhase.values) {
      store.syncStatus.value = CloudSyncStatus(phase: phase, pending: true);
      await tester.pump();
      expect(
        find.text(syncStatusLabel(store.syncStatus.value)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
    store.syncStatus.value = const CloudSyncStatus(
      phase: CloudSyncPhase.pending,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Sync now'));
    await tester.tap(find.text(syncStatusLabel(store.syncStatus.value)));
    expect(syncs, 1);
    expect(reviews, 1);
  });

  testWidgets('conflict choice requires confirmation and keeps both copies', (
    tester,
  ) async {
    final store = await _store(tester);
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CloudSyncDetailsPage(
          store: store,
          onChanged: () async => changes++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final localButton = find.text('Use this device’s version');
    await tester.ensureVisible(localButton);
    await tester.pumpAndSettle();
    await tester.tap(localButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await store.conflict(), isNotNull);
    expect(await store.recoveryCopies(), isEmpty);
    expect(changes, 0);

    final remoteButton = find.text('Use the synced version');
    await tester.ensureVisible(remoteButton);
    await tester.pumpAndSettle();
    await tester.tap(remoteButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('Both versions will be kept'), findsOneWidget);
    await tester.tap(find.text('Use this version'));
    await tester.pumpAndSettle();
    expect(await store.conflict(), isNull);
    expect((await store.load()).dailyPersonalHours, 5);
    final copies = await store.recoveryCopies();
    expect(copies, hasLength(2));
    expect(
      copies.map((copy) => copy.payload['dailyPersonalHours']),
      containsAll([3, 5]),
    );
    expect(changes, 1);
  });

  testWidgets(
    'restoring a saved copy confirms and preserves the current version',
    (tester) async {
      final store = await _store(tester, conflict: false);
      var changes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CloudSyncDetailsPage(
            store: store,
            onChanged: () async => changes++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final restore = find.text('Restore this copy');
      await tester.ensureVisible(restore);
      await tester.pumpAndSettle();
      await tester.tap(restore);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await store.load()).dailyPersonalHours, 3);
      expect(changes, 0);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('current version will also be kept'),
        findsOneWidget,
      );
      await tester.tap(find.text('Restore copy'));
      await tester.pumpAndSettle();
      expect((await store.load()).dailyPersonalHours, 5);
      final copies = await store.recoveryCopies();
      expect(copies, hasLength(2));
      expect(
        copies.map((copy) => copy.payload['dailyPersonalHours']),
        containsAll([3, 5]),
      );
      expect(changes, 1);
    },
  );
}

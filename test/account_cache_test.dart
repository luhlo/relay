import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/account.dart';
import 'package:relay/account_cache.dart';
import 'package:relay/cloud.dart';
import 'package:relay/model.dart';
import 'package:relay/widget_background.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _member(
  String userId, [
  String householdId = 'family-one',
]) => {
  'user_id': userId,
  'household_id': householdId,
  'display_name': 'Test parent',
  'role': 'owner',
};
Map<String, dynamic> _household([String id = 'family-one']) => {
  'id': id,
  'name': 'Test household',
  'child_names': ['Baby 1', 'Baby 2'],
};
CachedAccountContext _context(
  String userId, [
  String householdId = 'family-one',
]) => CachedAccountContext.fromRows(
  userId: userId,
  member: _member(userId, householdId),
  household: _household(householdId),
)!;

Future<SupabaseClient> _client({
  required Future<http.Response> Function(http.Request) request,
  bool expired = false,
}) async {
  final client = SupabaseClient(
    'https://relay.example.invalid',
    'test-public-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((req) async {
      if (req.url.path.endsWith('/token')) {
        final expiry =
            DateTime.now().millisecondsSinceEpoch ~/ 1000 +
            (expired ? -3600 : 3600);
        String encode(Map<String, dynamic> value) => base64Url
            .encode(utf8.encode(jsonEncode(value)))
            .replaceAll('=', '');
        final token =
            '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
            '${encode({'sub': 'owner-id', 'exp': expiry})}.test-signature';
        return http.Response(
          jsonEncode({
            'access_token': token,
            'token_type': 'bearer',
            'expires_in': expired ? -3600 : 3600,
            'expires_at':
                DateTime.now().millisecondsSinceEpoch ~/ 1000 +
                (expired ? -3600 : 3600),
            'refresh_token': 'test-refresh',
            'user': {
              'id': 'owner-id',
              'aud': 'authenticated',
              'email': 'owner@example.invalid',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
            },
          }),
          200,
          request: req,
        );
      }
      return request(req);
    }),
  );
  await client.auth.signInWithPassword(
    email: 'owner@example.invalid',
    password: 'test-password',
  );
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('household context is isolated to the saved owner', () async {
    const cache = AccountContextCache();
    await cache.save(_context('first-owner'));
    final first = await cache.load('first-owner');
    expect(first?.userId, 'first-owner');
    expect(first?.household['child_names'], ['Baby 1', 'Baby 2']);
    expect(await cache.load('other-owner'), isNull);
    await cache.save(_context('other-owner', 'different-family'));
    await cache.remove('first-owner');
    expect(await cache.load('first-owner'), isNull);
    expect(
      (await cache.load('other-owner'))?.household['id'],
      'different-family',
    );
  });

  test('cache stores only household context rather than auth tokens or other fields', () async {
    final context = CachedAccountContext.fromRows(
      userId: 'owner-id',
      member: {..._member('owner-id'), 'access_token': 'private-token'},
      household: {..._household(), 'invite_code': 'private-invite'},
    );
    await const AccountContextCache().save(context!);
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('relay.account-context.v1.owner-id')!;
    expect(raw, isNot(contains('private-token')));
    expect(raw, isNot(contains('private-invite')));
  });

  test('forged owner and mismatched household copies never restore', () async {
    final value = _context('other-owner').toJson();
    SharedPreferences.setMockInitialValues({
      'relay.account-context.v1.owner-id': jsonEncode(value),
    });
    expect(await const AccountContextCache().load('owner-id'), isNull);
    expect(
      CachedAccountContext.fromRows(
        userId: 'owner-id',
        member: _member('owner-id'),
        household: _household('different-family'),
      ),
      isNull,
    );
    expect(
      CachedAccountContext.fromRows(
        userId: 'owner-id',
        member: _member('other-owner'),
        household: _household(),
      ),
      isNull,
    );
  });

  test('malformed metadata fails safely instead of guessing child names or membership', () async {
    SharedPreferences.setMockInitialValues({
      'relay.account-context.v1.owner-id': '{broken',
    });
    expect(await const AccountContextCache().load('owner-id'), isNull);
    expect(
      CachedAccountContext.fromRows(
        userId: 'owner-id',
        member: _member('owner-id'),
        household: {
          ..._household(),
          'child_names': [123],
        },
      ),
      isNull,
    );
    expect(
      CachedAccountContext.fromRows(
        userId: 'owner-id',
        member: {..._member('owner-id'), 'role': 'admin'},
        household: _household(),
      ),
      isNull,
    );
  });

  test('cached widget startup uses an expired saved identity without any network request', () async {
    var requests = 0;
    final client = await _client(
      expired: true,
      request: (req) async {
        requests++;
        throw StateError('Offline; metadata must not be requested');
      },
    );
    addTearDown(client.dispose);
    await const AccountContextCache().save(_context('owner-id'));
    expect(client.auth.currentSession!.isExpired, isTrue);
    final store = await openWidgetCloudStore('cloud:owner-id', client: client);
    expect(store.userId, 'owner-id');
    expect(store.householdId, 'family-one');
    expect(store.childNames, ['Baby 1', 'Baby 2']);
    expect(requests, 0);
  });

  test(
    'widget startup refuses another account before metadata or records access',
    () async {
      var requests = 0;
      final client = await _client(
        request: (req) async {
          requests++;
          throw StateError('Must not request another account');
        },
      );
      addTearDown(client.dispose);
      await const AccountContextCache().save(_context('other-owner'));
      await expectLater(
        openWidgetCloudStore('cloud:other-owner', client: client),
        throwsException,
      );
      expect(requests, 0);
    },
  );

  test(
    'first widget bootstrap fetches and caches only its own verified household',
    () async {
      final paths = <String>[];
      final client = await _client(
        request: (req) async {
          paths.add(req.url.path);
          if (req.url.path.endsWith('/household_members')) {
            expect(req.url.queryParameters['user_id'], 'eq.owner-id');
            return http.Response(
              jsonEncode([_member('owner-id')]),
              200,
              request: req,
            );
          }
          expect(req.url.path, endsWith('/households'));
          expect(req.url.queryParameters['id'], 'eq.family-one');
          return http.Response(jsonEncode([_household()]), 200, request: req);
        },
      );
      addTearDown(client.dispose);
      final store = await openWidgetCloudStore(
        'cloud:owner-id',
        client: client,
      );
      expect(store.householdId, 'family-one');
      expect(paths, hasLength(2));
      expect(
        (await const AccountContextCache().load('owner-id'))?.member['user_id'],
        'owner-id',
      );
    },
  );

  test(
    'confirmed missing membership is distinct from a network failure',
    () async {
      final client = await _client(
        request: (req) async => http.Response('[]', 200, request: req),
      );
      addTearDown(client.dispose);
      expect(await fetchAccountContext(client, 'owner-id'), isNull);
      expect(
        accountContextRequiresSignIn(
          const AuthException('expired', statusCode: '401'),
        ),
        isTrue,
      );
      expect(
        accountContextRequiresSignIn(
          const PostgrestException(message: 'denied', code: '42501'),
        ),
        isTrue,
      );
      expect(
        accountContextRequiresSignIn(AuthRetryableFetchException()),
        isFalse,
      );
    },
  );

  for (final revoked in [false, true]) {
    testWidgets(
      revoked
          ? 'confirmed household removal blocks cached access and retains records'
          : 'cached account starts tracking before metadata reconnects',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final metadata = Completer<http.Response>();
        var bootstrap = true;
        final client = (await tester.runAsync(
          () => _client(
            request: (req) async {
              if (req.url.path.endsWith('/parent_records') && bootstrap) {
                return http.Response(
                  jsonEncode({
                    'revision': 0,
                    'payload': RelayState().toJson(),
                    'household_members': {'household_id': 'family-one'},
                  }),
                  200,
                  request: req,
                );
              }
              if (req.url.path.endsWith('/household_members')) {
                final response = await metadata.future;
                return http.Response(
                  response.body,
                  response.statusCode,
                  request: req,
                );
              }
              throw StateError('Offline');
            },
          ),
        ))!;
        addTearDown(() => tester.runAsync(client.dispose));
        final records = MemoryCloudCache();
        await CloudStore(
          client,
          'owner-id',
          ['Baby 1', 'Baby 2'],
          householdId: 'family-one',
          cache: records,
        ).load();
        await const AccountContextCache().save(_context('owner-id'));
        bootstrap = false;
        await tester.pumpWidget(
          MaterialApp(
            home: AccountGate(
              client: client,
              createStore: (client, userId, names, householdId) => CloudStore(
                client,
                userId,
                names,
                householdId: householdId,
                cache: records,
              ),
            ),
          ),
        );
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.text('Start Focus'), findsOneWidget);
        expect(find.text('Let’s reconnect'), findsNothing);
        if (revoked) {
          await tester.runAsync(() async {
            metadata.complete(http.Response('[]', 200));
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(
            find.text('Let’s reconnect'),
            findsOneWidget,
            reason: tester
                .widgetList<Text>(find.byType(Text))
                .map((text) => text.data)
                .join(' | '),
          );
          expect(await const AccountContextCache().load('owner-id'), isNull);
          expect(await records.read('owner-id'), isNotNull);
        } else {
          await tester.tap(find.text('Start Focus'));
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          final saved = await CloudStore(
            client,
            'owner-id',
            ['Baby 1', 'Baby 2'],
            householdId: 'family-one',
            cache: records,
          ).load();
          expect(saved.active?.kind, ShiftKind.focus);
        }
        await tester.pumpWidget(const SizedBox());
        if (!metadata.isCompleted) {
          metadata.completeError(StateError('Offline'));
        }
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}

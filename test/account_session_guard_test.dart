import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/account_session_guard.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _owner = '11111111-1111-4111-8111-111111111111';
const _other = '22222222-2222-4222-8222-222222222222';
const _privateText = 'Synthetic account settings and pending records';
const _closedText = 'Account changed. Reopen this page from Settings.';

Future<SupabaseClient> _client({int lifetime = 3600}) async {
  final client = SupabaseClient(
    'https://relay.example.invalid',
    'test-public-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/logout')) {
        return http.Response('', 204, request: request);
      }
      if (!request.url.path.endsWith('/token')) {
        throw StateError('Unexpected synthetic auth request');
      }
      final body = jsonDecode(request.body) as Map;
      final id = body['email'] == 'other@example.invalid' ? _other : _owner;
      String encode(Map<String, dynamic> value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      return http.Response(
        jsonEncode({
          'access_token':
              '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
              '${encode({'sub': id, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + lifetime})}.synthetic-signature',
          'token_type': 'bearer',
          'expires_in': lifetime,
          'refresh_token': 'test-refresh',
          'user': {
            'id': id,
            'aud': 'authenticated',
            'email': body['email'],
            'created_at': '2026-01-01T00:00:00Z',
            'app_metadata': <String, dynamic>{},
            'user_metadata': <String, dynamic>{},
          },
        }),
        200,
        request: request,
      );
    }),
  );
  await client.auth.signInWithPassword(
    email: 'owner@example.invalid',
    password: 'test-password',
  );
  return client;
}

class _PrivatePage extends StatefulWidget {
  const _PrivatePage({required this.onOpen, required this.onDispose});
  final VoidCallback onOpen, onDispose;
  @override
  State<_PrivatePage> createState() => _PrivatePageState();
}

class _PrivatePageState extends State<_PrivatePage> {
  @override
  void initState() {
    super.initState();
    widget.onOpen();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text(_privateText));
}

void main() {
  for (final signOut in [true, false]) {
    testWidgets(
      signOut
          ? 'logout disposes private pages and signing back in cannot restore them'
          : 'account switch disposes private pages and the original account cannot restore them',
      (tester) async {
        final client = (await tester.runAsync(_client))!;
        addTearDown(() => tester.runAsync(client.dispose));
        var opened = 0, disposed = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: AccountSessionGuard(
              client: client,
              expectedUserId: _owner,
              child: _PrivatePage(
                onOpen: () => opened++,
                onDispose: () => disposed++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(_privateText), findsOneWidget);
        await tester.runAsync(() async {
          if (signOut) {
            await client.auth.signOut(scope: SignOutScope.local);
          } else {
            await client.auth.signInWithPassword(
              email: 'other@example.invalid',
              password: 'test-password',
            );
          }
        });
        await tester.pumpAndSettle();
        expect(find.text(_privateText), findsNothing);
        expect(find.text(_closedText), findsOneWidget);
        expect(opened, 1);
        expect(disposed, 1);
        await tester.runAsync(
          () => client.auth.signInWithPassword(
            email: 'owner@example.invalid',
            password: 'test-password',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(_privateText), findsNothing);
        expect(find.text(_closedText), findsOneWidget);
        expect(opened, 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('same-account expired token keeps offline settings available', (
    tester,
  ) async {
    final client = (await tester.runAsync(() => _client(lifetime: -60)))!;
    addTearDown(() => tester.runAsync(client.dispose));
    await tester.pumpWidget(
      MaterialApp(
        home: AccountSessionGuard(
          client: client,
          expectedUserId: _owner,
          child: const Scaffold(body: Text(_privateText)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(client.auth.currentSession!.isExpired, isTrue);
    expect(find.text(_privateText), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(minutes: 2));
    expect(find.text(_privateText), findsOneWidget);
    expect(find.text(_closedText), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wrong opening account never mounts its private child', (
    tester,
  ) async {
    final client = (await tester.runAsync(_client))!;
    addTearDown(() => tester.runAsync(client.dispose));
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AccountSessionGuard(
          client: client,
          expectedUserId: _other,
          child: _PrivatePage(onOpen: () => opened++, onDispose: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text(_privateText), findsNothing);
    expect(find.text(_closedText), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'rebinding a pushed page to another owner permanently closes it',
    (tester) async {
      final client = (await tester.runAsync(_client))!;
      addTearDown(() => tester.runAsync(client.dispose));
      Widget app(String userId) => MaterialApp(
        home: AccountSessionGuard(
          client: client,
          expectedUserId: userId,
          child: const Scaffold(body: Text(_privateText)),
        ),
      );
      await tester.pumpWidget(app(_owner));
      await tester.pumpAndSettle();
      expect(find.text(_privateText), findsOneWidget);
      await tester.pumpWidget(app(_other));
      await tester.pumpAndSettle();
      expect(find.text(_privateText), findsNothing);
      await tester.pumpWidget(app(_owner));
      await tester.pumpAndSettle();
      expect(find.text(_privateText), findsNothing);
      expect(find.text(_closedText), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

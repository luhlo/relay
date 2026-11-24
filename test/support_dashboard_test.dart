import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/support_dashboard.dart';
import 'package:relay/support_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _owner = '11111111-1111-4111-8111-111111111111';
const _other = '22222222-2222-4222-8222-222222222222';
const _privateMessage = 'Synthetic private feedback for the original account';
const _privateEmail = 'reply@example.invalid';

Map<String, dynamic> _reports() => {
  'feedback': [
    {
      'category': 'problem',
      'message': _privateMessage,
      'reply_email': _privateEmail,
      'app_version': '1.18.0+23',
      'platform': 'web',
      'created_at': '2026-11-22T12:00:00Z',
    },
  ],
  'diagnostics': <Map<String, dynamic>>[],
};

Future<SupabaseClient> _signedInClient({int lifetimeSeconds = 3600}) async {
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
      final userId = body['email'] == 'other@example.invalid' ? _other : _owner;
      final expiry =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + lifetimeSeconds;
      String encode(Map<String, dynamic> value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      return http.Response(
        jsonEncode({
          'access_token':
              '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
              '${encode({'sub': userId, 'exp': expiry})}.synthetic-signature',
          'token_type': 'bearer',
          'expires_in': lifetimeSeconds,
          'refresh_token': 'test-refresh',
          'user': {
            'id': userId,
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

void main() {
  for (final switchAccount in [false, true]) {
    testWidgets(
      switchAccount
          ? 'switching accounts clears already loaded private reports'
          : 'signing out clears already loaded private reports',
      (tester) async {
        final client = (await tester.runAsync(_signedInClient))!;
        addTearDown(() => tester.runAsync(client.dispose));
        var requests = 0;
        final service = RelaySupportService.forTesting((_) async {
          requests++;
          return _reports();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: SupportDashboardPage(client: client, service: service),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(_privateMessage), findsOneWidget);
        expect(find.text('Reply to: $_privateEmail'), findsOneWidget);

        await tester.runAsync(() async {
          if (switchAccount) {
            await client.auth.signInWithPassword(
              email: 'other@example.invalid',
              password: 'test-password',
            );
          } else {
            await client.auth.signOut(scope: SignOutScope.local);
          }
        });
        await tester.pumpAndSettle();
        expect(find.text(_privateMessage), findsNothing);
        expect(find.text('Reply to: $_privateEmail'), findsNothing);
        expect(
          find.textContaining('then reopen the support dashboard'),
          findsOneWidget,
        );
        expect(requests, 1);
        expect(find.byTooltip('Refresh reports'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a report response arriving after logout cannot restore private rows',
    (tester) async {
      final client = (await tester.runAsync(_signedInClient))!;
      addTearDown(() => tester.runAsync(client.dispose));
      final response = Completer<Map<String, dynamic>>();
      final service = RelaySupportService.forTesting((_) => response.future);
      await tester.pumpWidget(
        MaterialApp(
          home: SupportDashboardPage(client: client, service: service),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.runAsync(
        () => client.auth.signOut(scope: SignOutScope.local),
      );
      await tester.pump();
      response.complete(_reports());
      await tester.pumpAndSettle();
      expect(find.text(_privateMessage), findsNothing);
      expect(find.text('Reply to: $_privateEmail'), findsNothing);
      expect(
        find.textContaining('then reopen the support dashboard'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an expired saved session never requests private reports', (
    tester,
  ) async {
    final client = (await tester.runAsync(
      () => _signedInClient(lifetimeSeconds: -60),
    ))!;
    addTearDown(() => tester.runAsync(client.dispose));
    var requests = 0;
    final service = RelaySupportService.forTesting((_) async {
      requests++;
      return _reports();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SupportDashboardPage(client: client, service: service),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.text(_privateMessage), findsNothing);
    expect(
      find.textContaining('then reopen the support dashboard'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'expired foreground session clears its already displayed reports',
    (tester) async {
      final client = (await tester.runAsync(
        () => _signedInClient(lifetimeSeconds: 60),
      ))!;
      addTearDown(() => tester.runAsync(client.dispose));
      final service = RelaySupportService.forTesting((_) async => _reports());
      await tester.pumpWidget(
        MaterialApp(
          home: SupportDashboardPage(client: client, service: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_privateMessage), findsOneWidget);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(find.text(_privateMessage), findsNothing);
      expect(
        find.textContaining('then reopen the support dashboard'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}

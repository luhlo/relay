import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/account.dart';
import 'package:relay/cloud.dart';
import 'package:relay/main.dart' show RelayHome;
import 'package:relay/model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

RelayState _activeAt(DateTime at) {
  final state = RelayState();
  state.start(ShiftKind.focus, at.subtract(const Duration(hours: 1)));
  return state;
}

Future<SupabaseClient> _setupClient({
  required Future<http.Response> Function(http.Request) handle,
}) async {
  final client = SupabaseClient(
    'https://relay-audit.example.invalid',
    'fictional-public-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        String encode(Map<String, dynamic> value) => base64Url
            .encode(utf8.encode(jsonEncode(value)))
            .replaceAll('=', '');
        return http.Response(
          jsonEncode({
            'access_token':
                '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': 'preview-owner', 'exp': expiry})}.fictional-signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'expires_at': expiry,
            'refresh_token': 'fictional-refresh',
            'user': {
              'id': 'preview-owner',
              'aud': 'authenticated',
              'email': 'owner@example.invalid',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
            },
          }),
          200,
          request: request,
        );
      }
      return handle(request);
    }),
  );
  await client.auth.signInWithPassword(
    email: 'owner@example.invalid',
    password: 'fictional-password',
  );
  return client;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  for (final label in ['Forgot password?', 'Resend confirmation email']) {
    testWidgets('$label validates only an email address', (tester) async {
      await tester.pumpWidget(MaterialApp(home: AuthForm(onLocal: () {})));
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(
        find.text(
          'Enter an email address and a password with at least 8 characters.',
        ),
        findsNothing,
      );
    });
  }

  testWidgets('partner Insights freezes active totals until explicit refresh', (
    tester,
  ) async {
    final observedAt = DateTime(2026, 11, 22, 12);
    final initial = _activeAt(observedAt);
    final latest = RelayState.fromJson(initial.toJson())
      ..finish(observedAt.subtract(const Duration(minutes: 30)));
    var refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FamilyMemberInsightsPage(
          displayName: 'Fictional parent',
          initialRecords: initial,
          initialObservedAt: observedAt,
          clock: () => observedAt.add(const Duration(minutes: 2)),
          loadRecords: () async {
            refreshes++;
            return latest;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Snapshot ·'), findsOneWidget);
    expect(
      tester.widget<RelayHome>(find.byType(RelayHome)).observationTime,
      observedAt,
    );
    expect(find.text('1h 0m'), findsWidgets);
    await tester.pump(const Duration(minutes: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(refreshes, 0);
    expect(find.text('1h 2m'), findsNothing);
    expect(find.text('1h 0m'), findsWidgets);
    await tester.tap(find.byTooltip('Refresh family Insights'));
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    expect(find.text('30m'), findsWidgets);
    expect(
      tester.widget<RelayHome>(find.byType(RelayHome)).observationTime,
      observedAt.add(const Duration(minutes: 2)),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'historical open timers respect safety limits without changing source records',
    (tester) async {
      final observedAt = DateTime(2026, 11, 22, 12);
      final source = RelayState();
      source.start(
        ShiftKind.focus,
        observedAt.subtract(const Duration(days: 3)),
      );
      final before = jsonEncode(source.toJson());
      await tester.pumpWidget(
        MaterialApp(
          home: FamilyMemberInsightsPage(
            displayName: 'Fictional parent',
            initialRecords: source,
            initialObservedAt: observedAt.toUtc(),
            loadRecords: () async => source,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // With no acknowledgement, the existing no-response guard caps at 12h.
      await tester.tap(find.text('All time'));
      await tester.pumpAndSettle();
      expect(find.text('12h 0m'), findsWidgets);
      expect(find.text('72h 0m'), findsNothing);
      expect(jsonEncode(source.toJson()), before);
      expect(source.active, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed partner refresh retains its dated snapshot and allows retry',
    (tester) async {
      final observedAt = DateTime(2026, 11, 22, 12);
      var attempts = 0;
      final pending = Completer<RelayState>();
      await tester.pumpWidget(
        MaterialApp(
          home: FamilyMemberInsightsPage(
            displayName: 'Fictional parent',
            initialRecords: _activeAt(observedAt),
            initialObservedAt: observedAt,
            loadRecords: () {
              attempts++;
              return attempts == 1
                  ? pending.future
                  : Future.value(RelayState());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Refresh family Insights'));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Refresh family Insights',
              ),
            )
            .onPressed,
        isNull,
      );
      pending.completeError(StateError('fictional offline request'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not refresh. Showing the last snapshot.'),
        findsOneWidget,
      );
      expect(find.text('1h 0m'), findsWidgets);
      expect(
        tester.widget<RelayHome>(find.byType(RelayHome)).observationTime,
        observedAt,
      );
      await tester.tap(find.byTooltip('Refresh family Insights'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.textContaining('Could not refresh.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'quiet metadata refresh retains setup drafts and invitation codes until Continue',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var created = false, metadataRequests = 0;
      final member = {
        'user_id': 'preview-owner',
        'household_id': 'fictional-family',
        'display_name': 'Fictional parent',
        'role': 'owner',
      };
      final household = {
        'id': 'fictional-family',
        'name': 'Fictional family',
        'child_names': ['Baby 1'],
      };
      final client = (await tester.runAsync(
        () => _setupClient(
          handle: (request) async {
            final path = request.url.path;
            Object body;
            if (path.endsWith('/household_members')) {
              metadataRequests++;
              body = created ? [member] : [];
            } else if (path.endsWith('/households')) {
              body = [household];
            } else if (path.endsWith('/rpc/relay_create_household_v2')) {
              created = true;
              body = 'fictional-family';
            } else if (path.endsWith('/rpc/relay_invite_member')) {
              body = 'fictional-invitation-code';
            } else if (path.endsWith('/parent_records')) {
              body = {
                'revision': 0,
                'payload': RelayState().toJson(),
                'household_members': {'household_id': 'fictional-family'},
              };
            } else {
              throw StateError('Unexpected fictional request $path');
            }
            return http.Response(jsonEncode(body), 200, request: request);
          },
        ),
      ))!;
      addTearDown(() => tester.runAsync(client.dispose));
      await tester.pumpWidget(
        MaterialApp(
          home: AccountGate(
            client: client,
            createStore: (client, userId, names, householdId) => CloudStore(
              client,
              userId,
              names,
              householdId: householdId,
              cache: MemoryCloudCache(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final name = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Your name',
      );
      final family = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Household name',
      );
      await tester.enterText(name, 'Fictional parent');
      await tester.enterText(family, 'Fictional family');
      final initialRequests = metadataRequests;
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(name).controller!.text,
        'Fictional parent',
      );
      expect(metadataRequests, initialRequests);
      await tester.ensureVisible(find.text('Add another family member'));
      await tester.tap(find.text('Add another family member'));
      await tester.pumpAndSettle();
      final email = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Family member 2 email (optional)',
      );
      await tester.ensureVisible(email);
      await tester.enterText(email, 'caregiver@example.invalid');
      await tester.ensureVisible(find.text('Create household'));
      await tester.tap(find.text('Create household'));
      await tester.pumpAndSettle();
      expect(find.text('Your family is ready'), findsOneWidget);
      expect(find.text('fictional-invitation-code'), findsOneWidget);
      await tester.pump(const Duration(minutes: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Your family is ready'), findsOneWidget);
      expect(find.text('fictional-invitation-code'), findsOneWidget);
      expect(metadataRequests, initialRequests);
      await tester.ensureVisible(find.text('Continue to Relay'));
      await tester.tap(find.text('Continue to Relay'));
      await tester.pumpAndSettle();
      expect(metadataRequests, greaterThan(initialRequests));
      expect(find.text('Start Focus'), findsOneWidget);
      expect(find.text('Your family is ready'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

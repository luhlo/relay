import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/account.dart';
import 'package:relay/cloud.dart';
import 'package:relay/household_management.dart';
import 'package:relay/main.dart';
import 'package:relay/model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

const ownerId = '11111111-1111-4111-8111-111111111111';
const caregiverId = '22222222-2222-4222-8222-222222222222';
const familyId = '33333333-3333-4333-8333-333333333333';
const inviteCode = '44444444-4444-4444-8444-444444444444';

Map<String, dynamic> owner() => {
  'user_id': ownerId,
  'household_id': familyId,
  'display_name': 'Test owner',
  'role': 'owner',
  'is_active': true,
};
Map<String, dynamic> caregiver() => {
  'user_id': caregiverId,
  'household_id': familyId,
  'display_name': 'Alex',
  'role': 'caregiver',
  'is_active': true,
};
Map<String, dynamic> invitation() => {
  'code': inviteCode,
  'email': 'caregiver@example.invalid',
  'member_role': 'caregiver',
  'expires_at': '2027-01-01T12:00:00Z',
};

Future<SupabaseClient> clientFor(
  String userId,
  Future<List<Map<String, dynamic>>> Function() members,
) async {
  final client = SupabaseClient(
    'https://relay.example.invalid',
    'test-public-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        String encode(Map<String, dynamic> value) => base64Url
            .encode(utf8.encode(jsonEncode(value)))
            .replaceAll('=', '');
        return http.Response(
          jsonEncode({
            'access_token':
                '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
                '${encode({'sub': userId, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.synthetic-signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'test-refresh',
            'user': {
              'id': userId,
              'aud': 'authenticated',
              'email': 'parent@example.invalid',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
            },
          }),
          200,
          request: request,
        );
      }
      if (request.url.path.endsWith('/logout')) {
        return http.Response('', 204, request: request);
      }
      if (request.url.path.endsWith('/household_members')) {
        expect(request.url.queryParameters['is_active'], 'eq.true');
        return http.Response(
          jsonEncode(await members()),
          200,
          request: request,
        );
      }
      if (request.url.path.endsWith('/parent_records')) {
        return http.Response(
          jsonEncode({'payload': RelayState().toJson()}),
          200,
          request: request,
        );
      }
      throw StateError('Unexpected synthetic request: ${request.url.path}');
    }),
  );
  await client.auth.signInWithPassword(
    email: 'parent@example.invalid',
    password: 'test-password',
  );
  return client;
}

class ManagementStore extends CloudStore {
  ManagementStore(SupabaseClient client, String userId)
    : super(
        client,
        userId,
        ['Ava', 'Noah'],
        householdId: familyId,
        cache: MemoryCloudCache(),
      );
  int writes = 0;
  @override
  Future<RelayState> load() async =>
      RelayState(childNames: List.of(childNames));
  @override
  Future<void> save(RelayState state) async => writes++;
}

Widget settings(
  ManagementStore store,
  HouseholdManagementService service, {
  bool ownsHousehold = true,
}) => MaterialApp(
  home: HouseholdAccount(
    member: ownsHousehold ? owner() : caregiver(),
    household: {
      'id': familyId,
      'name': 'Test family',
      'child_names': ['Ava', 'Noah'],
    },
    store: store,
    managementService: service,
    onSignOut: () async {},
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'children are normalized without reordering their stable positions',
    () async {
      Map<String, dynamic>? sent;
      final service = HouseholdManagementService.forTesting((
        name,
        params,
      ) async {
        expect(name, 'relay_update_household_children');
        sent = params;
        return params['children'];
      });
      expect(await service.updateChildren(['  Ava ', '', 'Noah']), [
        'Ava',
        'Baby 2',
        'Noah',
      ]);
      expect(sent, {
        'children': ['Ava', 'Baby 2', 'Noah'],
      });
      await expectLater(
        service.updateChildren([]),
        throwsA(isA<HouseholdManagementException>()),
      );
      await expectLater(
        service.updateChildren(List.filled(9, 'Baby')),
        throwsA(isA<HouseholdManagementException>()),
      );
      await expectLater(
        service.updateChildren(['x' * 41]),
        throwsA(isA<HouseholdManagementException>()),
      );
    },
  );

  test(
    'an account change prevents management writes and discards late replies',
    () async {
      var current = ownerId, calls = 0;
      final reply = Completer<dynamic>();
      final service = HouseholdManagementService.forTesting(
        (_, _) {
          calls++;
          return reply.future;
        },
        expectedUserId: ownerId,
        currentUserId: () => current,
      );
      final save = service.updateChildren(['Ava']);
      current = caregiverId;
      reply.complete(['Ava']);
      await expectLater(save, throwsA(isA<HouseholdManagementException>()));
      await expectLater(
        service.revokeInvitation(inviteCode),
        throwsA(isA<HouseholdManagementException>()),
      );
      expect(calls, 1);
    },
  );

  test(
    'remove/revoke call only scoped RPCs and never delete records directly',
    () async {
      final calls = <String>[];
      final service = HouseholdManagementService.forTesting((
        name,
        params,
      ) async {
        calls.add(name);
        if (name == 'relay_remove_household_member') {
          expect(params, {'member_user_id': caregiverId});
        }
        if (name == 'relay_revoke_household_invite') {
          expect(params, {'invite_code': inviteCode});
        }
        return null;
      }, expectedUserId: ownerId);
      await service.removeMember(caregiverId);
      await service.revokeInvitation(inviteCode);
      await expectLater(
        service.removeMember(ownerId),
        throwsA(isA<HouseholdManagementException>()),
      );
      expect(calls, [
        'relay_remove_household_member',
        'relay_revoke_household_invite',
      ]);
    },
  );

  testWidgets(
    'owner saves child count/names once while the request is pending',
    (tester) async {
      final client = (await tester.runAsync(
        () => clientFor(ownerId, () async => [owner(), caregiver()]),
      ))!;
      addTearDown(() => tester.runAsync(client.dispose));
      final store = ManagementStore(client, ownerId);
      final save = Completer<dynamic>();
      var writes = 0;
      List<String>? sent;
      final service = HouseholdManagementService.forTesting((
        name,
        params,
      ) async {
        if (name == 'relay_list_household_invites') return [];
        expect(name, 'relay_update_household_children');
        writes++;
        sent = List<String>.from(params['children']);
        return save.future;
      }, expectedUserId: ownerId);
      await tester.pumpWidget(settings(store, service));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Children'));
      await tester.tap(find.text('Children'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '3'));
      await tester.pumpAndSettle();
      final third = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Child 3 name (optional)',
      );
      await tester.ensureVisible(third);
      await tester.enterText(third, '');
      await tester.ensureVisible(find.text('Save children'));
      await tester.tap(find.text('Save children'));
      await tester.pump();
      await tester.tap(find.text('Save children'));
      await tester.pump();
      expect(writes, 1);
      expect(sent, ['Ava', 'Noah', 'Baby 3']);
      save.complete(sent);
      await tester.pumpAndSettle();
      expect(store.childNames, ['Ava', 'Noah', 'Baby 3']);
      expect(
        store.writes,
        0,
        reason: 'Metadata editing must not overwrite timer records',
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'member removal needs confirmation and preserves the list on failure',
    (tester) async {
      final client = (await tester.runAsync(
        () => clientFor(ownerId, () async => [owner(), caregiver()]),
      ))!;
      addTearDown(() => tester.runAsync(client.dispose));
      final store = ManagementStore(client, ownerId);
      var removes = 0;
      final service = HouseholdManagementService.forTesting((name, _) async {
        if (name == 'relay_list_household_invites') return [];
        removes++;
        throw StateError('Synthetic offline failure');
      }, expectedUserId: ownerId);
      await tester.pumpWidget(settings(store, service));
      await tester.pumpAndSettle();
      expect(find.text('Remove Test owner'), findsNothing);
      await tester.ensureVisible(find.text('Remove Alex'));
      await tester.tap(find.text('Remove Alex'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Their personal time records are kept'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(removes, 0);
      await tester.tap(find.text('Remove Alex'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove member'));
      await tester.pumpAndSettle();
      expect(removes, 1);
      expect(find.text('Remove Alex'), findsOneWidget);
      expect(store.writes, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'confirmed member removal updates access UI once without touching records',
    (tester) async {
      var removed = false, calls = 0;
      final client = (await tester.runAsync(
        () => clientFor(
          ownerId,
          () async => [owner(), if (!removed) caregiver()],
        ),
      ))!;
      addTearDown(() => tester.runAsync(client.dispose));
      final store = ManagementStore(client, ownerId);
      final response = Completer<dynamic>();
      final service = HouseholdManagementService.forTesting((
        name,
        params,
      ) async {
        if (name == 'relay_list_household_invites') return [];
        expect(name, 'relay_remove_household_member');
        expect(params, {'member_user_id': caregiverId});
        calls++;
        await response.future;
        removed = true;
        return null;
      }, expectedUserId: ownerId);
      await tester.pumpWidget(settings(store, service));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Remove Alex'));
      await tester.tap(find.text('Remove Alex'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove member'));
      await tester.pump();
      expect(calls, 1);
      response.complete(null);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('Remove Alex'), findsNothing);
      expect(find.textContaining('View Alex'), findsNothing);
      expect(store.writes, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('logging out dismisses a pending private member confirmation', (
    tester,
  ) async {
    final client = (await tester.runAsync(
      () => clientFor(ownerId, () async => [owner(), caregiver()]),
    ))!;
    addTearDown(() => tester.runAsync(client.dispose));
    var writes = 0;
    final service = HouseholdManagementService.forTesting((name, _) async {
      if (name == 'relay_list_household_invites') return [];
      writes++;
      return null;
    }, expectedUserId: ownerId);
    await tester.pumpWidget(
      settings(ManagementStore(client, ownerId), service),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Remove Alex'));
    await tester.tap(find.text('Remove Alex'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Alex?'), findsOneWidget);
    await tester.runAsync(() => client.auth.signOut(scope: SignOutScope.local));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending invitation can be revoked only after confirmation', (
    tester,
  ) async {
    final client = (await tester.runAsync(
      () => clientFor(ownerId, () async => [owner()]),
    ))!;
    addTearDown(() => tester.runAsync(client.dispose));
    final store = ManagementStore(client, ownerId);
    var revoked = false, writes = 0;
    final service = HouseholdManagementService.forTesting((name, params) async {
      if (name == 'relay_list_household_invites') {
        return revoked ? [] : [invitation()];
      }
      expect(name, 'relay_revoke_household_invite');
      expect(params, {'invite_code': inviteCode});
      writes++;
      revoked = true;
      return null;
    }, expectedUserId: ownerId);
    await tester.pumpWidget(settings(store, service));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Revoke invitation'));
    await tester.tap(find.text('Revoke invitation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text(inviteCode), findsOneWidget);
    await tester.tap(find.text('Revoke invitation'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke invitation'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text(inviteCode), findsNothing);
    expect(find.text('No pending invitations.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'nonowners see family history without owner management controls',
    (tester) async {
      final client = (await tester.runAsync(
        () => clientFor(caregiverId, () async => [owner(), caregiver()]),
      ))!;
      addTearDown(() => tester.runAsync(client.dispose));
      var requests = 0;
      final service = HouseholdManagementService.forTesting((_, _) async {
        requests++;
        return [];
      }, expectedUserId: caregiverId);
      await tester.pumpWidget(
        settings(
          ManagementStore(client, caregiverId),
          service,
          ownsHousehold: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Children'), findsNothing);
      expect(find.text('Save children'), findsNothing);
      expect(find.text('Remove Test owner'), findsNothing);
      expect(find.text('Remove Alex'), findsNothing);
      expect(find.text('Add family member'), findsNothing);
      expect(find.text('Pending invitations'), findsNothing);
      expect(requests, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'household refresh failure keeps previously loaded invite codes',
    (tester) async {
      final client = (await tester.runAsync(
        () => clientFor(ownerId, () async => [owner()]),
      ))!;
      addTearDown(() => tester.runAsync(client.dispose));
      var fail = false;
      final service = HouseholdManagementService.forTesting((name, _) async {
        expect(name, 'relay_list_household_invites');
        if (fail) throw StateError('Synthetic offline failure');
        return [invitation()];
      }, expectedUserId: ownerId);
      await tester.pumpWidget(
        settings(ManagementStore(client, ownerId), service),
      );
      await tester.pumpAndSettle();
      expect(find.text(inviteCode), findsOneWidget);
      fail = true;
      await tester.ensureVisible(find.text('Refresh household'));
      await tester.tap(find.text('Refresh household'));
      await tester.pumpAndSettle();
      expect(find.text(inviteCode), findsOneWidget);
      expect(
        find.textContaining('Could not refresh invitations.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'private archive observation stays fixed and has no write controls',
    (tester) async {
      final cutoff = DateTime(2026, 11, 24, 11);
      final state = RelayState(childNames: ['Past child']);
      state.sessions.add(
        Session(
          shiftId: 1,
          kind: ShiftKind.focus,
          start: cutoff.subtract(const Duration(hours: 1)),
        ),
      );
      final calls = <String>[];
      final service = HouseholdManagementService.forTesting((name, _) async {
        calls.add(name);
        return [
          {
            'id': inviteCode,
            'household_name': 'Previous family',
            'child_names': ['Past child'],
            'payload': state.toJson(),
            'archived_at': cutoff.toUtc().toIso8601String(),
          },
        ];
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PersonalTimeHistoryPage(
            service: service,
            cache: MemoryCloudCache(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final home = tester.widget<RelayHome>(find.byType(RelayHome));
      expect(home.readOnly, isTrue);
      expect(home.store, isA<ReadOnlyStore>());
      expect(home.observationTime, cutoff);
      await tester.pump(const Duration(minutes: 10));
      expect(
        tester.widget<RelayHome>(find.byType(RelayHome)).observationTime,
        cutoff,
      );
      expect(find.text('Start Focus'), findsNothing);
      expect(find.text('End shift'), findsNothing);
      expect(calls, ['relay_list_personal_record_archives']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'detached history keeps local pending time when cloud is unavailable',
    (tester) async {
      final cache = MemoryCloudCache();
      final local = RelayState(childNames: ['Device child']);
      local.sessions.add(
        Session(
          shiftId: 1,
          kind: ShiftKind.focus,
          start: DateTime.now().subtract(const Duration(minutes: 20)),
        ),
      );
      await cache.update(
        ownerId,
        (_) => {'current': local.toJson(), 'backups': []},
      );
      var requests = 0;
      final service = HouseholdManagementService.forTesting((name, _) async {
        expect(name, 'relay_list_personal_record_archives');
        requests++;
        throw StateError('Synthetic offline failure');
      }, expectedUserId: ownerId);
      await tester.pumpWidget(
        MaterialApp(
          home: PersonalTimeHistoryPage(service: service, cache: cache),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not refresh your cloud saved time.'),
        findsOneWidget,
      );
      expect(find.byType(RelayHome), findsOneWidget);
      expect(tester.widget<RelayHome>(find.byType(RelayHome)).readOnly, isTrue);
      expect(find.textContaining('Device snapshot'), findsOneWidget);
      expect(requests, 1);
      await tester.tap(find.byTooltip('Refresh your saved time'));
      await tester.pumpAndSettle();
      expect(find.byType(RelayHome), findsOneWidget);
      expect(requests, 2);
      expect(await cache.read(ownerId), isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'device history appears before a pending cloud request completes',
    (tester) async {
      final cache = MemoryCloudCache();
      final local = RelayState(childNames: ['Device child']);
      local.sessions.add(
        Session(
          shiftId: 1,
          kind: ShiftKind.focus,
          start: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );
      await cache.update(
        ownerId,
        (_) => {'current': local.toJson(), 'backups': []},
      );
      final remote = Completer<dynamic>();
      final service = HouseholdManagementService.forTesting(
        (_, _) => remote.future,
        expectedUserId: ownerId,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PersonalTimeHistoryPage(service: service, cache: cache),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(RelayHome), findsOneWidget);
      expect(find.byKey(const ValueKey('saved-time-loading')), findsOneWidget);
      expect(tester.widget<RelayHome>(find.byType(RelayHome)).readOnly, isTrue);
      remote.complete([]);
      await tester.pumpAndSettle();
      expect(find.byType(RelayHome), findsOneWidget);
      expect(find.byKey(const ValueKey('saved-time-loading')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'saved-time recovery remains usable on a small phone with large text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cache = MemoryCloudCache();
      final local = RelayState(childNames: ['Device child']);
      await cache.update(
        ownerId,
        (_) => {'current': local.toJson(), 'backups': []},
      );
      final service = HouseholdManagementService.forTesting(
        (_, _) async => throw StateError('offline'),
        expectedUserId: ownerId,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: PersonalTimeHistoryPage(service: service, cache: cache),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Refresh your saved time'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

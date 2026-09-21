import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/cloud.dart';
import 'package:relay/model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('cloud saves use authenticated owner and advance revision only after acknowledgment', () async {
    var conflict = false;
    var saves = 0;
    final user = {
      'id': 'owner-id',
      'aud': 'authenticated',
      'email': 'test@example.invalid',
      'created_at': '2026-01-01T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    };
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
              'user': user,
            }),
            200,
            request: request,
          );
        }
        if (request.url.path.endsWith('/parent_records')) {
          expect(request.url.queryParameters['user_id'], 'eq.owner-id');
          return http.Response(
            jsonEncode({'revision': 4, 'payload': RelayState().toJson()}),
            200,
            request: request,
          );
        }
        expect(request.url.path, '/rest/v1/rpc/relay_save_records');
        final body = jsonDecode(request.body);
        expect(body['expected_revision'], saves == 0 ? 4 : 5);
        expect(body.containsKey('user_id'), isFalse);
        saves++;
        return conflict
            ? http.Response(
                jsonEncode({'code': '40001', 'message': 'Conflict'}),
                409,
                request: request,
              )
            : http.Response('5', 200, request: request);
      }),
    );
    addTearDown(client.dispose);
    await client.auth.signInWithPassword(
      email: 'test@example.invalid',
      password: 'test-password',
    );
    final store = CloudStore(client, 'owner-id', ['Ava', 'Noah']);
    final state = await store.load();
    expect(state.babyName(Baby.chloe), 'Ava');
    expect(state.babyName(Baby.luca), 'Noah');
    await store.save(state);
    expect(store.revision, 5);
    conflict = true;
    await expectLater(store.save(state), throwsA(isA<CloudSaveException>()));
    expect(store.revision, 5);
    final other = CloudStore(client, 'other-parent', ['Ava', 'Noah'])
      ..revision = 0;
    await expectLater(other.save(state), throwsA(isA<CloudSaveException>()));
    expect(saves, 2);
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

import 'package:supabase_flutter/supabase_flutter.dart';

import 'model.dart';
import 'storage.dart';

const relaySupabaseUrl = 'https://mhfkjrtrfdnmjmmvlueg.supabase.co';
// Publishable browser key only. Never place a secret/service-role key here.
const relayPublishableKey = 'sb_publishable_K4HF2hnwtBwM196HRV_7ZQ_gxMKJkhD';

class CloudSaveException implements Exception {
  CloudSaveException(this.message);
  final String message;
}

class CloudStore extends RelayStore {
  CloudStore(this.client, this.userId, this.childNames);
  final SupabaseClient client;
  final String userId;
  final List<String> childNames;
  int? revision;

  @override
  Future<RelayState> load() async {
    final row = await client
        .from('parent_records')
        .select()
        .eq('user_id', userId)
        .single();
    revision = (row['revision'] as num).toInt();
    final state = RelayState.fromJson(
      Map<String, dynamic>.from(row['payload']),
    );
    state.childNames = List.of(childNames);
    return state;
  }

  @override
  Future<void> save(RelayState state) async {
    if (client.auth.currentUser?.id != userId || revision == null) {
      throw CloudSaveException(
        'Sign in and refresh your records before saving.',
      );
    }
    try {
      final value = await client.rpc(
        'relay_save_records',
        params: {'expected_revision': revision, 'new_payload': state.toJson()},
      );
      revision = (value as num).toInt();
    } on PostgrestException catch (e) {
      throw CloudSaveException(
        e.code == '40001'
            ? 'Another device changed your records. Tap Refresh before trying again.'
            : 'Cloud save failed. Refresh and try again. Your change was not saved.',
      );
    } catch (_) {
      throw CloudSaveException(
        'Could not confirm the cloud save. Reconnect and tap Refresh before trying again.',
      );
    }
  }
}

class ReadOnlyStore extends RelayStore {
  ReadOnlyStore(this.state);
  final RelayState state;
  @override
  Future<RelayState> load() async => state;
  @override
  Future<void> save(RelayState state) async => throw StateError('Read only');
}

/// Import only into a new empty cloud account; never guess how to merge timers.
bool canImportRecords(RelayState cloud) =>
    cloud.sessions.isEmpty && cloud.shifts.isEmpty;

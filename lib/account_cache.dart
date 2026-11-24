import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AccountMembershipUnavailable implements Exception {
  const AccountMembershipUnavailable();
}

bool accountContextRequiresSignIn(Object error) =>
    error is AuthException &&
        (error is AuthSessionMissingException ||
            error is AuthInvalidJwtException ||
            {'400', '401', '403'}.contains(error.statusCode)) ||
    error is PostgrestException &&
        {
          '401',
          '403',
          '42501',
          'PGRST301',
          'PGRST302',
          'PGRST303',
        }.contains(error.code);

Future<CachedAccountContext?> fetchAccountContext(
  SupabaseClient client,
  String userId, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (client.auth.currentUser?.id != userId) {
    throw const AuthException(
      'Sign in again to refresh your household.',
      statusCode: '401',
    );
  }
  final member = await client
      .from('household_members')
      .select()
      .eq('user_id', userId)
      .maybeSingle()
      .timeout(timeout);
  if (client.auth.currentUser?.id != userId) {
    throw const AuthException(
      'The signed-in account changed.',
      statusCode: '401',
    );
  }
  if (member == null || member['is_active'] == false) return null;
  final household = await client
      .from('households')
      .select()
      .eq('id', member['household_id'])
      .maybeSingle()
      .timeout(timeout);
  if (client.auth.currentUser?.id != userId) {
    throw const AuthException(
      'The signed-in account changed.',
      statusCode: '401',
    );
  }
  if (household == null) throw const AccountMembershipUnavailable();
  final context = CachedAccountContext.fromRows(
    userId: userId,
    member: member,
    household: household,
  );
  if (context == null) throw const AccountMembershipUnavailable();
  return context;
}

/// Cached identity context is only a local view of a previously verified
/// membership. It never grants access to the server or to another account.
class CachedAccountContext {
  CachedAccountContext._(this.userId, this.member, this.household);
  final String userId;
  final Map<String, dynamic> member;
  final Map<String, dynamic> household;

  static CachedAccountContext? fromRows({
    required String userId,
    required Map<String, dynamic> member,
    required Map<String, dynamic> household,
  }) {
    final householdId = household['id'];
    final names = household['child_names'];
    if (userId.isEmpty ||
        member['is_active'] == false ||
        member['user_id'] != userId ||
        householdId is! String ||
        householdId.isEmpty ||
        member['household_id'] != householdId ||
        !{'owner', 'parent', 'caregiver'}.contains(member['role']) ||
        member['display_name'] is! String ||
        household['name'] is! String ||
        (names != null &&
            (names is! List ||
                names.isEmpty ||
                names.length > 8 ||
                names.any(
                  (name) => name is! String || name.isEmpty || name.length > 40,
                )))) {
      return null;
    }
    return CachedAccountContext._(
      userId,
      {
        'user_id': userId,
        'household_id': householdId,
        'display_name': member['display_name'],
        'role': member['role'],
      },
      {
        'id': householdId,
        'name': household['name'],
        if (names != null) 'child_names': List<String>.from(names as List),
        'child_one': household['child_one'] is String
            ? household['child_one']
            : 'Baby 1',
        'child_two': household['child_two'] is String
            ? household['child_two']
            : 'Baby 2',
      },
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'owner_id': userId,
    'member': member,
    'household': household,
  };
}

class AccountContextCache {
  const AccountContextCache();

  String _key(String userId) =>
      'relay.account-context.v1.${Uri.encodeComponent(userId)}';

  Future<CachedAccountContext?> load(String userId) async {
    if (userId.isEmpty) return null;
    final preferences = await SharedPreferences.getInstance();
    // The foreground app and headless widget have separate preference caches.
    await preferences.reload();
    final raw = preferences.getString(_key(userId));
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['version'] != 1 ||
          value['owner_id'] != userId ||
          value['member'] is! Map ||
          value['household'] is! Map) {
        return null;
      }
      return CachedAccountContext.fromRows(
        userId: userId,
        member: Map<String, dynamic>.from(value['member'] as Map),
        household: Map<String, dynamic>.from(value['household'] as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(CachedAccountContext context) async {
    final validated = CachedAccountContext.fromRows(
      userId: context.userId,
      member: context.member,
      household: context.household,
    );
    if (validated == null) {
      throw StateError('The account context does not match its owner.');
    }
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(
      _key(context.userId),
      jsonEncode(validated.toJson()),
    )) {
      throw StateError('Could not prepare this account for offline use.');
    }
  }

  Future<void> remove(String userId) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.remove(_key(userId))) {
      throw StateError('Could not clear this account context.');
    }
  }
}

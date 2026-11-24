import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

typedef HouseholdRpc = Future<dynamic> Function(
  String name,
  Map<String, dynamic> params,
);

class HouseholdManagementException implements Exception {
  const HouseholdManagementException(this.message);
  final String message;
  @override
  String toString() => message;
}

class HouseholdInvitation {
  const HouseholdInvitation({
    required this.code,
    required this.email,
    required this.role,
    required this.expiresAt,
  });
  final String code, email, role;
  final DateTime expiresAt;

  factory HouseholdInvitation.fromJson(Map<String, dynamic> value) {
    final expires = DateTime.tryParse(value['expires_at']?.toString() ?? '');
    if (value['code'] is! String ||
        value['email'] is! String ||
        !{'parent', 'caregiver'}.contains(value['member_role']) ||
        expires == null) {
      throw const HouseholdManagementException(
        'Could not read the pending invitations. Please refresh.',
      );
    }
    return HouseholdInvitation(
      code: value['code'] as String,
      email: value['email'] as String,
      role: value['member_role'] as String,
      expiresAt: expires,
    );
  }
}

class PersonalTimeArchive {
  const PersonalTimeArchive({
    required this.id,
    required this.householdName,
    required this.childNames,
    required this.payload,
    required this.archivedAt,
    this.fromDevice = false,
  });
  final String id, householdName;
  final List<String> childNames;
  final Map<String, dynamic> payload;
  final DateTime archivedAt;
  final bool fromDevice;

  factory PersonalTimeArchive.fromJson(Map<String, dynamic> value) {
    final names = value['child_names'];
    final archived = DateTime.tryParse(value['archived_at']?.toString() ?? '');
    if (value['id'] is! String ||
        value['household_name'] is! String ||
        names is! List ||
        names.isEmpty ||
        names.length > 8 ||
        names.any((name) => name is! String) ||
        value['payload'] is! Map ||
        archived == null) {
      throw const HouseholdManagementException(
        'Could not read your saved time. Please refresh.',
      );
    }
    return PersonalTimeArchive(
      id: value['id'] as String,
      householdName: value['household_name'] as String,
      childNames: List<String>.from(names),
      payload: Map<String, dynamic>.from(value['payload'] as Map),
      archivedAt: archived.toLocal(),
    );
  }
}

/// Management writes always go to validated, owner-only database functions.
/// They are never queued or automatically retried after a timeout.
class HouseholdManagementService {
  HouseholdManagementService(SupabaseClient client, String expectedUserId)
    : _currentUserId = (() => client.auth.currentUser?.id),
      _expectedUserId = expectedUserId,
      _request = ((name, params) => client.rpc(name, params: params));

  HouseholdManagementService.forTesting(
    HouseholdRpc request, {
    String expectedUserId = 'test-owner',
    String? Function()? currentUserId,
  }) : _request = request,
       _expectedUserId = expectedUserId,
       _currentUserId = currentUserId ?? (() => expectedUserId);

  final HouseholdRpc _request;
  final String _expectedUserId;
  final String? Function() _currentUserId;
  String get expectedUserId => _expectedUserId;

  Future<dynamic> _call(
    String name, [
    Map<String, dynamic> params = const {},
  ]) async {
    void requireSameAccount() {
      if (_expectedUserId.isEmpty || _currentUserId() != _expectedUserId) {
        throw const HouseholdManagementException(
          'Your account changed. Reopen Settings before trying again.',
        );
      }
    }

    requireSameAccount();
    try {
      final result = await _request(
        name,
        params,
      ).timeout(const Duration(seconds: 12));
      requireSameAccount();
      return result;
    } on TimeoutException {
      throw const HouseholdManagementException(
        'Could not confirm this action. Refresh the household before trying again.',
      );
    }
  }

  Future<List<String>> updateChildren(List<String> children) async {
    if (children.isEmpty || children.length > 8) {
      throw const HouseholdManagementException(
        'Choose between 1 and 8 children.',
      );
    }
    final names = [
      for (final entry in children.indexed)
        entry.$2.trim().isEmpty ? 'Baby ${entry.$1 + 1}' : entry.$2.trim(),
    ];
    if (names.any((name) => name.length > 40)) {
      throw const HouseholdManagementException(
        'Child names must be 40 characters or fewer.',
      );
    }
    final result = await _call('relay_update_household_children', {
      'children': names,
    });
    if (result is! List ||
        result.length != names.length ||
        result.any(
          (name) => name is! String || name.isEmpty || name.length > 40,
        )) {
      throw const HouseholdManagementException(
        'Could not confirm the saved names. Refresh before trying again.',
      );
    }
    return List<String>.from(result);
  }

  Future<List<HouseholdInvitation>> invitations() async {
    final result = await _call('relay_list_household_invites');
    if (result is! List) {
      throw const HouseholdManagementException(
        'Could not read pending invitations.',
      );
    }
    return [
      for (final row in result)
        HouseholdInvitation.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  Future<String> inviteMember(String email, String role) async {
    final address = email.trim().toLowerCase();
    if (address.length > 254 ||
        !RegExp(r'^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$').hasMatch(address)) {
      throw const HouseholdManagementException(
        'Enter a valid family member email.',
      );
    }
    if (!{'parent', 'caregiver'}.contains(role)) {
      throw const HouseholdManagementException('Choose Parent or Caregiver.');
    }
    final code = await _call('relay_invite_member', {
      'member_email': address,
      'member_role': role,
    });
    if (code is! String || code.isEmpty) {
      throw const HouseholdManagementException(
        'Could not confirm the invitation. Refresh the pending list before retrying.',
      );
    }
    return code;
  }

  Future<void> revokeInvitation(String code) async {
    await _call('relay_revoke_household_invite', {'invite_code': code});
  }

  Future<void> removeMember(String userId) async {
    if (userId == _expectedUserId) {
      throw const HouseholdManagementException(
        'You cannot remove your own account from this page.',
      );
    }
    await _call('relay_remove_household_member', {'member_user_id': userId});
  }

  Future<List<PersonalTimeArchive>> personalArchives() async {
    final result = await _call('relay_list_personal_record_archives');
    if (result is! List) {
      throw const HouseholdManagementException(
        'Could not read your saved time.',
      );
    }
    return [
      for (final row in result)
        PersonalTimeArchive.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }
}

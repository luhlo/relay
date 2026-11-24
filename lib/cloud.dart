import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cloud_cache.dart';
import 'cloud_merge.dart';
import 'model.dart';
import 'storage.dart';

export 'cloud_cache.dart';

const relaySupabaseUrl = 'https://mhfkjrtrfdnmjmmvlueg.supabase.co';
// Publishable browser key only. Never place a secret/service-role key here.
const relayPublishableKey = 'sb_publishable_K4HF2hnwtBwM196HRV_7ZQ_gxMKJkhD';

class CloudSaveException implements Exception {
  CloudSaveException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CloudScopeException extends CloudSaveException {
  CloudScopeException()
    : super(
        'This device has saved records from a different household. Review them before connecting the new household.',
      );
}

enum CloudSyncPhase {
  synced,
  pending,
  offline,
  syncing,
  conflict,
  needsSignIn,
  error,
}

class CloudSyncStatus {
  const CloudSyncStatus({
    required this.phase,
    this.pending = false,
    this.message,
    this.lastSyncedAt,
  });
  final CloudSyncPhase phase;
  final bool pending;
  final String? message;
  final DateTime? lastSyncedAt;
}

class CloudConflict {
  CloudConflict(CloudJson value)
    : local = copyCloudJson(value['local'] as CloudJson),
      remote = copyCloudJson(value['remote'] as CloudJson),
      base = copyCloudJson(value['base'] as CloudJson),
      remoteRevision = (value['remoteRevision'] as num).toInt(),
      paths = List<String>.from(value['paths'] as List? ?? []);
  final CloudJson local, remote, base;
  final int remoteRevision;
  final List<String> paths;
}

class CloudRecoveryCopy {
  CloudRecoveryCopy(CloudJson value)
    : id = value['id'] as String,
      createdAt = DateTime.parse(value['createdAt'] as String).toLocal(),
      label = value['label'] as String,
      householdId = value['householdId'] as String?,
      payload = copyCloudJson(value['payload'] as CloudJson);
  final String id, label;
  final DateTime createdAt;
  final String? householdId;
  final CloudJson payload;
}

String _mutationId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final text = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${text.substring(0, 8)}-${text.substring(8, 12)}-${text.substring(12, 16)}-${text.substring(16, 20)}-${text.substring(20)}';
}

CloudJson _payload(CloudJson envelope) =>
    copyCloudJson(envelope['current'] as CloudJson);
CloudJson _base(CloudJson envelope) =>
    copyCloudJson(envelope['base'] as CloudJson);
bool _pending(CloudJson envelope) =>
    envelope['flight'] != null ||
    !cloudJsonEqual(envelope['base'], envelope['current']);

/// Signed-in tracking always commits to this account's local transaction first.
/// synchronize() is separate so widget taps and app saves never wait on a network.
class CloudStore extends RelayStore {
  CloudStore(
    this.client,
    this.userId,
    this.childNames, {
    this.householdId,
    CloudCache? cache,
    this.networkTimeout = const Duration(seconds: 8),
  }) : cache = cache ?? defaultCloudCache;
  final SupabaseClient client;
  final String userId;
  final List<String> childNames;
  final String? householdId;
  final CloudCache cache;
  final Duration networkTimeout;
  final syncStatus = ValueNotifier<CloudSyncStatus>(
    const CloudSyncStatus(phase: CloudSyncPhase.syncing),
  );
  int? revision;
  String? _resolvedHouseholdId;
  CloudJson? _loadedPayload;
  Future<void>? _syncing;
  bool _disposed = false;

  String? get _scope => householdId ?? _resolvedHouseholdId;

  void _checkOwner() {
    if (client.auth.currentUser?.id != userId) {
      _emit(
        CloudSyncPhase.needsSignIn,
        message: 'Sign in to this Relay account to sync its saved records.',
      );
      throw CloudSaveException(
        'Sign in to this Relay account before opening its saved records.',
      );
    }
  }

  void _checkScope(CloudJson envelope) {
    if (_scope != null && envelope['householdId'] != _scope) {
      _emit(
        CloudSyncPhase.error,
        envelope: envelope,
        message: CloudScopeException().message,
      );
      throw CloudScopeException();
    }
    _resolvedHouseholdId ??= envelope['householdId'] as String?;
  }

  Future<CloudJson?> _read() async {
    _checkOwner();
    final value = await cache.read(userId);
    _checkOwner();
    return value;
  }

  void _emit(CloudSyncPhase phase, {CloudJson? envelope, String? message}) {
    if (_disposed) return;
    final stamp = envelope?['lastSyncedAt'] as String?;
    syncStatus.value = CloudSyncStatus(
      phase: phase,
      pending: envelope == null ? syncStatus.value.pending : _pending(envelope),
      message: message,
      lastSyncedAt: stamp == null
          ? syncStatus.value.lastSyncedAt
          : DateTime.tryParse(stamp)?.toLocal(),
    );
  }

  void _status(CloudJson envelope, {bool preserveProblem = false}) {
    revision = (envelope['baseRevision'] as num).toInt();
    if (envelope['conflict'] != null) {
      _emit(
        CloudSyncPhase.conflict,
        envelope: envelope,
        message: 'Changes on another device need your review. Your saved copy is safe here.',
      );
    } else if (preserveProblem &&
        {
          CloudSyncPhase.offline,
          CloudSyncPhase.needsSignIn,
          CloudSyncPhase.error,
        }.contains(syncStatus.value.phase)) {
      _emit(
        syncStatus.value.phase,
        envelope: envelope,
        message: syncStatus.value.message,
      );
    } else {
      _emit(
        _pending(envelope) ? CloudSyncPhase.pending : CloudSyncPhase.synced,
        envelope: envelope,
      );
    }
  }

  Future<CloudJson> _remote() async {
    _checkOwner();
    if (_scope == null) {
      final member = await client
          .from('household_members')
          .select('household_id,is_active')
          .eq('user_id', userId)
          .single()
          .timeout(networkTimeout);
      _checkOwner();
      if (member['is_active'] == false) {
        throw CloudSaveException(
          'Your household access has changed. Reopen Settings to connect a household. Your saved time is kept.',
        );
      }
      _resolvedHouseholdId = member['household_id'] as String;
    }
    final row = await client
        .from('parent_records')
        .select(
          'revision,payload,household_members!inner(household_id,is_active)',
        )
        .eq('user_id', userId)
        .single()
        .timeout(networkTimeout);
    _checkOwner();
    // The FK embed reads membership and records in one database snapshot.
    // parent_records itself has no household_id; a separate membership request
    // would leave a leave/rejoin race before this payload was fetched.
    final membership = row['household_members'];
    if (membership is Map && membership['is_active'] == false) {
      throw CloudSaveException(
        'Your household access has changed. Reopen Settings to connect a household. Your saved time is kept.',
      );
    }
    if (membership is! Map || membership['household_id'] is! String) {
      throw const FormatException('Missing household scope in records.');
    }
    if (membership['household_id'] != _scope) throw CloudScopeException();
    final payload = Map<String, dynamic>.from(row['payload'] as Map);
    RelayState.fromJson(payload); // Reject corrupt network data before caching.
    return {'revision': (row['revision'] as num).toInt(), 'payload': payload};
  }

  CloudJson _newEnvelope(CloudJson remote, {List<dynamic>? backups}) => {
    'schema': 1,
    'generation': 0,
    'householdId': _scope,
    'baseRevision': remote['revision'],
    'base': copyCloudJson(remote['payload'] as CloudJson),
    'current': copyCloudJson(remote['payload'] as CloudJson),
    'flight': null,
    'conflict': null,
    'lastSyncedAt': DateTime.now().toUtc().toIso8601String(),
    'backups': backups ?? [],
  };

  @override
  Future<RelayState> load() async {
    var envelope = await _read();
    if (envelope == null) {
      try {
        final remote = await _remote();
        envelope = await cache.update(userId, (current) {
          _checkOwner();
          return current ?? _newEnvelope(remote);
        });
      } catch (error) {
        _reportSyncFailure(error, null);
        throw CloudSaveException(
          'Connect once to download this account’s records. After that, tracking works offline.',
        );
      }
    }
    _checkOwner();
    _checkScope(envelope!);
    _loadedPayload = _payload(envelope);
    _status(envelope, preserveProblem: true);
    final state = RelayState.fromJson(_loadedPayload!);
    if (childNames.isNotEmpty) state.childNames = List.of(childNames);
    return state;
  }

  @override
  Future<void> save(RelayState state) async {
    _checkOwner();
    final expected = _loadedPayload;
    if (expected == null) {
      throw CloudSaveException(
        'Open your saved records before making changes.',
      );
    }
    final next = state.toJson();
    final envelope = await cache.update(userId, (current) {
      _checkOwner();
      if (current == null) {
        throw CloudSaveException(
          'Open your saved records before making changes.',
        );
      }
      _checkScope(current);
      if (!cloudJsonEqual(current['current'], expected)) {
        throw const LocalSaveConflict();
      }
      current['current'] = copyCloudJson(next);
      current['generation'] = (current['generation'] as int) + 1;
      if (current['conflict'] is Map) {
        (current['conflict'] as Map)['local'] = copyCloudJson(next);
      }
      return current;
    });
    _loadedPayload = _payload(envelope!);
    _status(envelope, preserveProblem: true);
  }

  /// Read the latest device snapshot for comparison without changing the CAS
  /// baseline belonging to the state currently displayed by the foreground UI.
  /// A background refresh must not make a stale edit look like a current edit.
  Future<RelayState> peekCachedState() async {
    final envelope = await _read();
    if (envelope == null) {
      throw CloudSaveException('Open your saved records before refreshing.');
    }
    _checkScope(envelope);
    final state = RelayState.fromJson(_payload(envelope));
    if (childNames.isNotEmpty) state.childNames = List.of(childNames);
    return state;
  }

  Future<bool> hasCachedRecords() async => await _read() != null;
  Future<bool> hasPendingChanges() async {
    final value = await _read();
    return value != null && _pending(value);
  }

  static Future<void> clearCachedRecords(String userId) =>
      defaultCloudCache.remove(userId);

  Future<CloudConflict?> conflict() async {
    final envelope = await _read();
    if (envelope == null || envelope['conflict'] == null) return null;
    return CloudConflict(
      Map<String, dynamic>.from(envelope['conflict'] as Map),
    );
  }

  Future<List<CloudRecoveryCopy>> recoveryCopies() async {
    final envelope = await _read();
    return (envelope?['backups'] as List? ?? [])
        .whereType<Map>()
        .map((value) => CloudRecoveryCopy(Map<String, dynamic>.from(value)))
        .toList();
  }

  CloudJson _backup(CloudJson envelope, CloudJson value, String label) => {
    'id': _mutationId(),
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'householdId': envelope['householdId'],
    'label': label,
    'payload': copyCloudJson(value),
  };

  Future<void> resolveConflict({required bool keepLocal}) async {
    _checkOwner();
    final envelope = await cache.update(userId, (current) {
      _checkOwner();
      if (current == null) {
        throw CloudSaveException('No saved account records are available.');
      }
      _checkScope(current);
      final conflict = current['conflict'] as Map?;
      if (conflict == null) {
        throw CloudSaveException(
          'These changes have already been reviewed. Refresh to see the latest records.',
        );
      }
      final backups = current['backups'] as List;
      backups.add(
        _backup(
          current,
          _payload(current),
          'This device before conflict review',
        ),
      );
      backups.add(
        _backup(
          current,
          Map<String, dynamic>.from(conflict['remote'] as Map),
          'Cloud copy before conflict review',
        ),
      );
      current['current'] = copyCloudJson(
        keepLocal
            ? current['current'] as CloudJson
            : Map<String, dynamic>.from(conflict['remote'] as Map),
      );
      current['base'] = copyCloudJson(
        Map<String, dynamic>.from(conflict['remote'] as Map),
      );
      current['baseRevision'] = conflict['remoteRevision'];
      current['flight'] = null;
      current['conflict'] = null;
      current['generation'] = (current['generation'] as int) + 1;
      return current;
    });
    _loadedPayload = _payload(envelope!);
    _status(envelope);
  }

  Future<void> restoreRecoveryCopy(String id) async {
    _checkOwner();
    final envelope = await cache.update(userId, (current) {
      _checkOwner();
      if (current == null) {
        throw CloudSaveException('No recovery copy is available.');
      }
      _checkScope(current);
      if (current['flight'] != null) {
        throw CloudSaveException(
          'Finish or retry the pending sync before restoring a copy.',
        );
      }
      final copies = (current['backups'] as List).whereType<Map>().where(
        (copy) => copy['id'] == id,
      );
      if (copies.length != 1) {
        throw CloudSaveException('This recovery copy is unavailable.');
      }
      final selected = copies.single;
      if (selected['householdId'] != current['householdId']) {
        throw CloudScopeException();
      }
      RelayState.fromJson(
        Map<String, dynamic>.from(selected['payload'] as Map),
      );
      (current['backups'] as List).add(
        _backup(current, _payload(current), 'Before restoring a recovery copy'),
      );
      if (current['conflict'] != null) {
        (current['backups'] as List).add(
          _backup(
            current,
            Map<String, dynamic>.from(
              (current['conflict'] as Map)['remote'] as Map,
            ),
            'Cloud copy before restoring a recovery copy',
          ),
        );
      }
      current['current'] = copyCloudJson(
        Map<String, dynamic>.from(selected['payload'] as Map),
      );
      current['conflict'] = null;
      current['generation'] = (current['generation'] as int) + 1;
      return current;
    });
    _loadedPayload = _payload(envelope!);
    _status(envelope);
  }

  /// Called only after the user chooses the newly joined household. Old records
  /// remain available as scoped recovery copies and can never auto-upload here.
  Future<void> useCurrentHousehold() async {
    _checkOwner();
    final remote = await _remote();
    final envelope = await cache.update(userId, (current) {
      _checkOwner();
      final backups = List<dynamic>.from(current?['backups'] as List? ?? []);
      if (current != null) {
        backups.add(
          _backup(current, _payload(current), 'Previous household device copy'),
        );
        backups.add(
          _backup(current, _base(current), 'Previous household cloud baseline'),
        );
      }
      return _newEnvelope(remote, backups: backups);
    });
    _loadedPayload = _payload(envelope!);
    _status(envelope);
  }

  Future<void> synchronize() async {
    if (_syncing != null) return _syncing;
    final operation = _synchronize();
    _syncing = operation;
    try {
      await operation;
    } finally {
      if (identical(_syncing, operation)) _syncing = null;
    }
  }

  CloudJson _reconcile(
    CloudJson envelope,
    CloudJson remote, {
    required CloudJson mergeBase,
    required bool acknowledged,
  }) {
    if ((remote['revision'] as num) < (envelope['baseRevision'] as num)) {
      return envelope;
    }
    final there = copyCloudJson(remote['payload'] as CloudJson);
    final here = _payload(envelope);
    final merged = mergeCloudPayload(mergeBase, here, there);
    envelope['base'] = there;
    envelope['baseRevision'] = remote['revision'];
    envelope['flight'] = null;
    envelope['generation'] = (envelope['generation'] as int) + 1;
    if (merged.payload == null) {
      envelope['conflict'] = {
        'local': here,
        'remote': there,
        'base': copyCloudJson(mergeBase),
        'remoteRevision': remote['revision'],
        'paths': merged.conflicts,
      };
    } else {
      envelope['current'] = merged.payload;
      envelope['conflict'] = null;
    }
    if (acknowledged || merged.payload != null) {
      envelope['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
    }
    return envelope;
  }

  Future<void> _synchronize() async {
    CloudJson? envelope;
    try {
      _checkOwner();
      envelope = await _read();
      if (envelope == null) {
        await load();
        envelope = await _read();
      }
      _checkScope(envelope!);
      if (envelope['conflict'] != null) {
        _status(envelope);
        return;
      }
      _emit(CloudSyncPhase.syncing, envelope: envelope);
      if (client.auth.currentSession?.isExpired == true) {
        await client.auth.refreshSession().timeout(networkTimeout);
        _checkOwner();
      }
      for (var cycle = 0; cycle < 3; cycle++) {
        envelope = await _read();
        if (envelope == null) return;
        _checkScope(envelope);
        if (envelope['conflict'] != null) {
          _status(envelope);
          return;
        }
        if (!_pending(envelope)) {
          final remote = await _remote();
          envelope = await cache.update(userId, (current) {
            _checkOwner();
            if (current == null) return null;
            _checkScope(current);
            if (current['flight'] != null || current['conflict'] != null) {
              return current;
            }
            return _reconcile(
              current,
              remote,
              mergeBase: _base(current),
              acknowledged: false,
            );
          });
          if (envelope == null) return;
          if (!_pending(envelope) || envelope['conflict'] != null) {
            _status(envelope);
            return;
          }
        }
        envelope = await cache.update(userId, (current) {
          _checkOwner();
          if (current == null) return null;
          _checkScope(current);
          if (current['conflict'] != null || !_pending(current)) return current;
          current['flight'] ??= {
            'id': _mutationId(),
            'revision': current['baseRevision'],
            'payload': _payload(current),
            'base': _base(current),
            'householdId': current['householdId'],
          };
          return current;
        });
        if (envelope == null) return;
        if (envelope['conflict'] != null || envelope['flight'] == null) {
          _status(envelope);
          return;
        }
        final flight = Map<String, dynamic>.from(envelope['flight'] as Map);
        try {
          final value = await client
              .rpc(
                'relay_sync_records',
                params: {
                  'expected_revision': flight['revision'],
                  'mutation_id': flight['id'],
                  'new_payload': flight['payload'],
                  'expected_household_id': flight['householdId'],
                },
              )
              .timeout(networkTimeout);
          _checkOwner();
          final response = Map<String, dynamic>.from(value as Map);
          final remote = {
            'revision': (response['revision'] as num).toInt(),
            'payload': Map<String, dynamic>.from(response['payload'] as Map),
          };
          RelayState.fromJson(remote['payload'] as CloudJson);
          if ((response['applied_revision'] as num) >
              (response['revision'] as num)) {
            throw const FormatException('Invalid sync acknowledgement.');
          }
          envelope = await cache.update(userId, (current) {
            _checkOwner();
            if (current == null) return null;
            _checkScope(current);
            if ((current['flight'] as Map?)?['id'] != flight['id']) {
              return current;
            }
            return _reconcile(
              current,
              remote,
              mergeBase: Map<String, dynamic>.from(flight['payload'] as Map),
              acknowledged: true,
            );
          });
        } on PostgrestException catch (error) {
          if (error.code != '40001') rethrow;
          final remote = await _remote();
          envelope = await cache.update(userId, (current) {
            _checkOwner();
            if (current == null) return null;
            _checkScope(current);
            if ((current['flight'] as Map?)?['id'] != flight['id']) {
              return current;
            }
            return _reconcile(
              current,
              remote,
              mergeBase: Map<String, dynamic>.from(flight['base'] as Map),
              acknowledged: false,
            );
          });
        }
        if (envelope == null) return;
        _status(envelope);
        if (!_pending(envelope) || envelope['conflict'] != null) return;
      }
    } catch (error) {
      _reportSyncFailure(error, envelope);
    }
  }

  void _reportSyncFailure(Object error, CloudJson? envelope) {
    if (error is AuthRetryableFetchException) {
      _emit(
        CloudSyncPhase.offline,
        envelope: envelope,
        message: 'Saved on this device. Changes will sync when a connection is available.',
      );
    } else if (error is CloudScopeException) {
      _emit(CloudSyncPhase.error, envelope: envelope, message: error.message);
    } else if (error is AuthException ||
        error is CloudSaveException ||
        error is PostgrestException &&
            {
              '28000',
              '42501',
              '401',
              '403',
              'PGRST301',
              'PGRST302',
              'PGRST303',
              'PGRST116',
            }.contains(error.code)) {
      _emit(
        CloudSyncPhase.needsSignIn,
        envelope: envelope,
        message: 'Your records are saved on this device. Reconnect or sign in again to sync.',
      );
    } else if (error is PostgrestException || error is FormatException) {
      _emit(
        CloudSyncPhase.error,
        envelope: envelope,
        message:
            'Sync needs attention. Your records remain saved on this device.',
      );
    } else {
      _emit(
        CloudSyncPhase.offline,
        envelope: envelope,
        message: 'Saved on this device. Changes will sync when a connection is available.',
      );
    }
  }

  void dispose() {
    _disposed = true;
    syncStatus.dispose();
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

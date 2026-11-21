import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'alerts.dart';
import 'account_cache.dart';
import 'cloud.dart';
import 'home_widget.dart';
import 'model.dart';
import 'storage.dart';
import 'timer_guard.dart';

const _backgroundChannel = MethodChannel('app.relay.relay/widget_background');
const _operationTimeout = Duration(seconds: 20);

/// Invoked by the main library's VM entrypoint in a fresh, headless engine.
/// The worker owns the one-use job and destroys the engine after completion.
Future<void> runWidgetBackground({
  Future<RelayStore> Function(String context)? openStore,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  RelayState? loaded;
  String? source;
  bool saveStarted = false;
  bool saveConfirmed = false;
  Map<String, dynamic> completion;
  try {
    final job = await _backgroundChannel
        .invokeMapMethod<String, dynamic>('getAction')
        .timeout(_operationTimeout);
    final context = job?['context'];
    final requestId = job?['requestId'];
    if (job == null ||
        context is! String ||
        requestId is! String ||
        requestId.isEmpty) {
      throw const _WidgetJobException('Open Relay and try the widget again.');
    }
    source = context;

    if (context != 'local' &&
        (!context.startsWith('cloud:') || context.length <= 'cloud:'.length)) {
      throw const _WidgetJobException('Open Relay to reconnect your widget.');
    }
    final store = await (openStore ?? _openStore)(context)
        .timeout(_operationTimeout);

    loaded = await store.load().timeout(_operationTimeout);
    if (loaded.lastWidgetRequestId != requestId) {
      final kind = job['action'];
      bool changed;
      if (kind == 'guard' || kind == 'confirmTimer' || kind == 'stopTimer') {
        changed = updateTimerGuard(
          loaded,
          DateTime.now(),
          action: kind as String,
          expectedSessionStart: job['sessionStart'] as String?,
        ).changed;
      } else {
        final guarded = updateTimerGuard(loaded, DateTime.now());
        if (!(guarded.changed &&
            loaded.active == null &&
            kind != 'work' &&
            kind != 'baby')) {
          applyWidgetAction(loaded, job, context, DateTime.now());
        }
        changed = true;
      }
      if (changed) {
        loaded.lastWidgetRequestId = requestId;
        saveStarted = true;
        await store.save(loaded).timeout(_operationTimeout);
        saveConfirmed = true;
      }
    }

    var syncPending = false;
    var syncBlocked = false;
    String? syncMessage;
    if (store is CloudStore) {
      try {
        syncPending = await store.hasPendingChanges();
      } catch (_) {
        // A confirmed local write stays successful even if its status cannot
        // be re-read. Ask the independent worker to check it conservatively.
        syncPending = true;
      }
      final phase = store.syncStatus.value.phase;
      syncBlocked =
          phase == CloudSyncPhase.conflict ||
          phase == CloudSyncPhase.needsSignIn ||
          phase == CloudSyncPhase.error;
      if (syncPending) {
        syncMessage = syncBlocked
            ? 'Saved on this device. Open Relay to review syncing.'
            : 'Saved on this device. Waiting to sync.';
      }
    }

    // A successful save is final. Notification permission/scheduling problems
    // must never turn it into a retry that applies the same tap a second time.
    String? reminderMessage;
    try {
      final alerts = ShiftAlerts();
      await alerts.initialize().timeout(_operationTimeout);
      await alerts.sync(loaded).timeout(_operationTimeout);
    } catch (_) {
      reminderMessage = syncPending
          ? 'Saved on this device. Open Relay to check syncing and shift reminders.'
          : 'Saved. Open Relay to check shift reminders.';
    }
    completion = {
      'success': true,
      'snapshot': {
        ...widgetSnapshot(loaded, context, DateTime.now()),
        'syncPending': syncPending,
        'syncBlocked': syncBlocked,
      },
      'syncPending': syncPending,
      'syncBlocked': syncBlocked,
      'error': ?(reminderMessage ?? syncMessage),
    };
  } catch (error) {
    // After any unacknowledged save, the server/disk may already have committed.
    // Do not publish the mutated in-memory state or blindly replay the action.
    final uncertainSave = saveStarted && !saveConfirmed;
    completion = {
      'success': false,
      'error': uncertainSave
          ? 'Could not confirm the save. Open Relay to refresh your time.'
          : _errorMessage(error),
      if (!uncertainSave && loaded != null && source != null)
        'snapshot': widgetSnapshot(loaded, source, DateTime.now()),
    };
  }

  // Complete exactly once. If Android has already stopped a timed-out worker,
  // there is no second action or fallback write to perform in this engine.
  try {
    await _backgroundChannel
        .invokeMethod<void>('complete', completion)
        .timeout(const Duration(seconds: 5));
  } catch (_) {
    // The native worker is responsible for displaying a timeout failure.
  }
}

Future<RelayStore> _openStore(String source) async =>
    source == 'local' ? RelayStore() : openWidgetCloudStore(source);

Future<CloudStore> openWidgetCloudStore(
  String source, {
  SupabaseClient? client,
  AccountContextCache contextCache = const AccountContextCache(),
}) async {
  if (client == null) {
    await Supabase.initialize(
      url: relaySupabaseUrl,
      publishableKey: relayPublishableKey,
      // A widget cannot handle a browser callback and has no Activity attached.
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
      debug: false,
    ).timeout(_operationTimeout);
  }
  final activeClient = client ?? Supabase.instance.client;
  // initialize restores the saved local session before returning. An expired
  // access token may refresh later, but its owner can keep tracking offline.
  final userId = activeClient.auth.currentUser?.id;
  if (userId == null || source != 'cloud:$userId') {
    throw CloudSaveException('Sign in to Relay to reconnect this widget.');
  }

  var cached = await contextCache.load(userId);
  if (cached == null) {
    cached = await fetchAccountContext(activeClient, userId);
    if (cached == null) {
      throw CloudSaveException(
        'Open Relay online once to prepare this account for offline tracking.',
      );
    }
    await contextCache.save(cached);
  }
  if (activeClient.auth.currentUser?.id != userId) {
    throw CloudSaveException('Sign in to Relay to reconnect this widget.');
  }
  final household = cached.household;
  final configured = household['child_names'];
  final names = configured is List && configured.isNotEmpty
      ? List<String>.from(configured)
      : <String>[
          household['child_one'] as String? ?? 'Baby 1',
          household['child_two'] as String? ?? 'Baby 2',
        ];
  return CloudStore(
    activeClient,
    userId,
    names,
    householdId: household['id'] as String,
  );
}

String _errorMessage(Object error) {
  if (error is _WidgetJobException) return error.message;
  if (error is ArgumentError) return error.message.toString();
  if (error is CloudSaveException) return error.message;
  if (error is TimeoutException) {
    return 'Connection timed out. Open Relay and try again.';
  }
  return 'Could not load your time. Open Relay to reconnect.';
}

class _WidgetJobException implements Exception {
  const _WidgetJobException(this.message);
  final String message;
}

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'account_cache.dart';
import 'cloud.dart';
import 'widget_background.dart';

const _cloudSyncChannel = MethodChannel(
  'app.relay.relay/cloud_sync_background',
);

/// Network-constrained WorkManager entrypoint. It only drains the local outbox;
/// widget controls have already committed independently, including while offline.
Future<void> runCloudSyncBackground({
  Future<CloudStore> Function(String context)? openStore,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  CloudStore? store;
  String? source;
  var pending = true;
  var blocked = false;
  try {
    final action = await _cloudSyncChannel
        .invokeMapMethod<String, dynamic>('getAction')
        .timeout(const Duration(seconds: 5));
    final context = action?['context'];
    if (context is! String ||
        !context.startsWith('cloud:') ||
        context.length <= 6) {
      blocked = true;
    } else {
      source = context;
      store = await (openStore ?? openWidgetCloudStore)(context)
          .timeout(const Duration(seconds: 20));
      await store.load().timeout(const Duration(seconds: 10));
      if (await store.hasPendingChanges()) {
        await store.synchronize().timeout(const Duration(seconds: 60));
      }
      pending = await store.hasPendingChanges();
      blocked = {
        CloudSyncPhase.conflict,
        CloudSyncPhase.needsSignIn,
        CloudSyncPhase.error,
      }.contains(store.syncStatus.value.phase);
    }
  } on CloudScopeException {
    blocked = true;
  } on CloudSaveException {
    blocked = true;
  } catch (error) {
    blocked =
        error is AccountMembershipUnavailable ||
        accountContextRequiresSignIn(error);
    // Keep the durable pending signal for a bounded WorkManager retry. Do not
    // publish a stale state, repeat a tap, or expose exception messages.
  }
  try {
    await _cloudSyncChannel
        .invokeMethod<void>('complete', {
          'context': source,
          'pending': pending,
          'blocked': blocked,
        })
        .timeout(const Duration(seconds: 3));
  } catch (_) {
    // Native source/generation checks retain pending work after a lost reply.
  } finally {
    store?.dispose();
  }
}

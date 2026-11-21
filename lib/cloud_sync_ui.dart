import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'cloud.dart';
import 'model.dart';

String syncStatusLabel(CloudSyncStatus status) => switch (status.phase) {
  CloudSyncPhase.synced => 'Saved on this device · Synced',
  CloudSyncPhase.pending => 'Saved on this device · Waiting to sync',
  CloudSyncPhase.offline => 'Offline · Saved on this device',
  CloudSyncPhase.syncing => 'Saved on this device · Syncing',
  CloudSyncPhase.conflict => 'Saved on this device · Review changes',
  CloudSyncPhase.needsSignIn => 'Saved on this device · Sign in to sync',
  CloudSyncPhase.error => 'Saved on this device · Sync needs attention',
};

class CloudSyncBanner extends StatelessWidget {
  const CloudSyncBanner({
    super.key,
    required this.store,
    required this.onSync,
    required this.onReview,
  });
  final CloudStore store;
  final VoidCallback onSync, onReview;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<CloudSyncStatus>(
    valueListenable: store.syncStatus,
    builder: (context, status, _) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: TextButton.icon(
                onPressed: onReview,
                icon: Icon(
                  status.phase == CloudSyncPhase.synced
                      ? Icons.cloud_done_outlined
                      : status.phase == CloudSyncPhase.conflict
                      ? Icons.cloud_off_outlined
                      : Icons.cloud_upload_outlined,
                  size: 19,
                ),
                label: Text(
                  syncStatusLabel(status),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: status.phase == CloudSyncPhase.conflict
                ? 'Review saved copies'
                : 'Sync now',
            onPressed: status.phase == CloudSyncPhase.syncing
                ? null
                : status.phase == CloudSyncPhase.conflict
                ? onReview
                : onSync,
            icon: status.phase == CloudSyncPhase.syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    status.phase == CloudSyncPhase.conflict
                        ? Icons.compare_arrows
                        : Icons.sync,
                  ),
          ),
        ],
      ),
    ),
  );
}

class CloudSyncDetailsPage extends StatefulWidget {
  const CloudSyncDetailsPage({
    super.key,
    required this.store,
    required this.onChanged,
  });
  final CloudStore store;
  final Future<void> Function() onChanged;
  @override
  State<CloudSyncDetailsPage> createState() => _CloudSyncDetailsPageState();
}

class _CloudSyncDetailsPageState extends State<CloudSyncDetailsPage> {
  CloudConflict? conflict;
  List<CloudRecoveryCopy> copies = [];
  bool loading = true, busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final latestConflict = await widget.store.conflict();
      final latestCopies = await widget.store.recoveryCopies();
      if (!mounted) return;
      setState(() {
        conflict = latestConflict;
        copies = latestCopies.reversed.toList();
        loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error =
              'Could not open this account’s saved copies. Please try again.';
        });
      }
    }
  }

  Future<void> _choose(bool keepLocal) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          keepLocal ? 'Use this device’s version?' : 'Use the synced version?',
        ),
        content: const Text(
          'Both versions will be kept in Saved copies on this device. Your choice becomes the version used here and will sync to your account. If another device changes it again, Relay will check again before saving.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Use this version'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await _run(() => widget.store.resolveConflict(keepLocal: keepLocal));
  }

  Future<void> _restore(CloudRecoveryCopy copy) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Restore this saved copy?'),
        content: const Text(
          'Your current version will also be kept in Saved copies. This copy will replace the records shown here and sync to your account. Copies from another household can be viewed, but cannot be restored into this household.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Restore copy'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await _run(() => widget.store.restoreRecoveryCopy(copy.id));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      await widget.onChanged();
      await _load();
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = failure is CloudSaveException ? failure.message : 'Could not apply this choice. Your saved copies are still on this device.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _copy(String title, Map<String, dynamic> payload, {Widget? action}) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              _RecordSummary(payload: payload),
              if (action != null) ...[const SizedBox(height: 12), action],
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sync & saved copies')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              ValueListenableBuilder<CloudSyncStatus>(
                valueListenable: widget.store.syncStatus,
                builder: (context, status, _) => Text(
                  syncStatusLabel(status),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Timers and schedules save on this device first. Sync retries when Relay has a connection. On the web, keep Relay open or reopen it to finish syncing. Signing in, inviting caregivers and changing shared household details require a connection.',
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (conflict != null) ...[
                const SizedBox(height: 24),
                const Text(
                  'Two devices changed the same records. Compare the copies, then choose which version to use. Neither will be silently discarded.',
                ),
                const SizedBox(height: 12),
                _copy(
                  'This device',
                  conflict!.local,
                  action: FilledButton(
                    onPressed: busy ? null : () => _choose(true),
                    child: const Text('Use this device’s version'),
                  ),
                ),
                _copy(
                  'Synced copy',
                  conflict!.remote,
                  action: OutlinedButton(
                    onPressed: busy ? null : () => _choose(false),
                    child: const Text('Use the synced version'),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              const Text(
                'Saved copies',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Recovery copies are private to this account on this device. They remain here when you log out and become available when you sign back into the same account. Clearing app or browser storage removes them.',
              ),
              if (copies.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('No recovery copies have been needed.'),
                ),
              for (final copy in copies)
                _copy(
                  '${copy.label}\n${DateFormat.yMMMd().add_jm().format(copy.createdAt)}',
                  copy.payload,
                  action: OutlinedButton(
                    onPressed: busy ? null : () => _restore(copy),
                    child: const Text('Restore this copy'),
                  ),
                ),
            ],
          ),
  );
}

class _RecordSummary extends StatelessWidget {
  const _RecordSummary({required this.payload});
  final Map<String, dynamic> payload;
  @override
  Widget build(BuildContext context) {
    RelayState state;
    try {
      state = RelayState.fromJson(payload);
    } catch (_) {
      return const Text('This copy is preserved, but could not be previewed.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${state.sessions.length} time sessions · ${state.shifts.length} schedule blocks',
        ),
        if (state.active != null)
          Text(
            'Active: ${state.active!.kind == ShiftKind.focus ? 'Focus' : 'Baby Time'} since ${DateFormat.yMMMd().add_jm().format(state.active!.start)}',
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('View time records'),
          children: [
            for (final session in state.sessions.reversed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  session.kind == ShiftKind.focus
                      ? 'Focus'
                      : session.baby == null
                      ? 'Baby Time'
                      : state.babyName(session.baby!),
                ),
                subtitle: Text(
                  '${DateFormat.yMMMd().add_jm().format(session.start)} – ${session.end == null ? 'Still running' : DateFormat.yMMMd().add_jm().format(session.end!)}\n${session.interruptions.length} interruptions',
                ),
              ),
            if (state.sessions.isEmpty)
              const Text('No time sessions in this copy.'),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('View schedule'),
          children: [
            for (final shift in state.shifts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  shift.kind == ShiftKind.focus ? 'Focus' : 'Baby Time',
                ),
                subtitle: Text(
                  '${DateFormat.yMMMd().add_jm().format(shift.start)} – ${DateFormat.yMMMd().add_jm().format(shift.end)}',
                ),
              ),
            if (state.shifts.isEmpty)
              const Text('No schedule blocks in this copy.'),
          ],
        ),
      ],
    );
  }
}

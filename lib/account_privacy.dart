import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

const relayPrivacyUrl = 'https://relay.luhlo.com/privacy/';
const relayDeletionUrl = 'https://relay.luhlo.com/delete-account/';

bool accountDeletionRequested(Uri uri) =>
    uri.queryParameters['action'] == 'delete-account';

class PrivacyAndAccountActions extends StatelessWidget {
  const PrivacyAndAccountActions({super.key, this.onDeleteAccount});
  final VoidCallback? onDeleteAccount;

  Future<void> openLink(BuildContext context, String url) async {
    try {
      if (await launchUrl(Uri.parse(url))) return;
    } catch (_) {
      // Show a useful fallback if a browser is unavailable.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: SelectableText('Open $url in your browser.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextButton.icon(
        onPressed: () => openLink(context, relayPrivacyUrl),
        icon: const Icon(Icons.privacy_tip_outlined),
        label: const Text('Privacy policy'),
      ),
      if (onDeleteAccount != null)
        TextButton.icon(
          onPressed: onDeleteAccount,
          icon: const Icon(Icons.person_remove_outlined),
          label: const Text('Delete account'),
        ),
    ],
  );
}

/// The same deliberate, authenticated deletion flow is available on Android
/// and from the public account-deletion webpage, without reinstalling Relay.
class AccountDeletionPage extends StatefulWidget {
  const AccountDeletionPage({
    super.key,
    required this.onDeleted,
    required this.onDone,
    this.deleteAccount,
  });
  final Future<void> Function() onDeleted;
  final VoidCallback onDone;
  final Future<void> Function()? deleteAccount;

  @override
  State<AccountDeletionPage> createState() => _AccountDeletionPageState();
}

class _AccountDeletionPageState extends State<AccountDeletionPage> {
  final confirmation = TextEditingController();
  bool busy = false, deleted = false;
  String? message;

  @override
  void dispose() {
    confirmation.dispose();
    super.dispose();
  }

  Future<void> removeAccount() async {
    if (busy || confirmation.text != 'DELETE') return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permanently delete your account?'),
        content: const Text(
          'Your Relay sign-in, cloud schedules, work and Baby Time history, '
          'and account settings will be deleted. This cannot be undone. '
          'Other family members will keep their accounts and their own records.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (widget.deleteAccount != null) {
        await widget.deleteAccount!();
      } else {
        final client = Supabase.instance.client;
        if (client.auth.currentSession == null) {
          throw const AuthException(
            'Sign in again before deleting your account.',
          );
        }
        final response = await client.functions.invoke(
          'relay-delete-account',
          body: {'confirmation': 'DELETE'},
        );
        if (response.status != 200 ||
            response.data is! Map ||
            response.data['deleted'] != true) {
          throw StateError('Deletion was not confirmed.');
        }
      }
      // Backend success is final even if local OS cleanup has a problem.
      if (mounted) setState(() => deleted = true);
      try {
        await widget.onDeleted();
      } catch (_) {
        if (mounted) {
          message = 'Your account was deleted. Close and reopen Relay to clear this device’s sign-in.';
        }
      }
    } on AuthException {
      message = 'Your session expired. Sign out, sign in again, and retry.';
    } on FunctionException catch (e) {
      message = e.status == 401
          ? 'Your session expired. Sign out, sign in again, and retry.'
          : 'Could not confirm account deletion. Check your connection and try again.';
    } catch (_) {
      message = 'Could not confirm account deletion. Check your connection and try again.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy && !deleted,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Delete account'),
        automaticallyImplyLeading: !deleted,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                deleted
                    ? 'Your account was deleted'
                    : 'You control your account',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 20),
              if (deleted) ...[
                const Text(
                  'Your Relay account and associated cloud records have been deleted.',
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: widget.onDone,
                  child: const Text('Done'),
                ),
              ] else ...[
                const Text(
                  'Deleting your account permanently removes your sign-in, cloud '
                  'schedules, work sessions, interruptions, Baby Time history, '
                  'and account settings. Invitations connected to your account are removed.',
                ),
                const SizedBox(height: 16),
                const Text(
                  'Other caregivers keep their accounts and records. If you own '
                  'the household, ownership moves to a remaining member. If you '
                  'are its last member, the household and saved child names are deleted.',
                ),
                const SizedBox(height: 16),
                const Text(
                  'Separate records created in “this device” mode stay on that '
                  'device. Copies someone has already exported are outside Relay’s control.',
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: confirmation,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Type DELETE to confirm',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    minimumSize: const Size(48, 56),
                  ),
                  onPressed: busy || confirmation.text != 'DELETE'
                      ? null
                      : removeAccount,
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: Text(busy ? 'Deleting…' : 'Delete my account'),
                ),
                const PrivacyAndAccountActions(),
              ],
              if (busy) const LinearProgressIndicator(),
              if (message != null) ...[
                const SizedBox(height: 16),
                Text(message!, semanticsLabel: message),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Keeps a pushed page bound to the account that opened it, even when another
/// tab changes the session while the app's home route is underneath this page.
class AccountSessionGuard extends StatefulWidget {
  const AccountSessionGuard({
    super.key,
    this.client,
    required this.expectedUserId,
    required this.child,
    this.requireFreshSession = false,
    this.closedMessage = 'Account changed. Reopen this page from Settings.',
  });

  final SupabaseClient? client;
  final String expectedUserId;
  final Widget child;
  // Ordinary account pages keep same-account offline access. Private support
  // reports can opt into clearing their fetched content at token expiry.
  final bool requireFreshSession;
  final String closedMessage;

  @override
  State<AccountSessionGuard> createState() => _AccountSessionGuardState();
}

class _AccountSessionGuardState extends State<AccountSessionGuard>
    with WidgetsBindingObserver {
  late final SupabaseClient _client;
  late final String _openingUserId;
  StreamSubscription<AuthState>? _authChanges;
  Timer? _expiry;
  bool _revoked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client ?? Supabase.instance.client;
    _openingUserId = widget.expectedUserId;
    _revoked = !_sameAccount;
    _authChanges = _client.auth.onAuthStateChange.listen(
      (event) {
        if (!mounted) return;
        if (event.event == AuthChangeEvent.signedOut || !_sameAccount) {
          _revoke();
        } else if (!_revoked) {
          _scheduleExpiry();
        }
      },
      onError: (Object _) {
        if (!_sameAccount) _revoke();
      },
    );
    if (!_revoked) _scheduleExpiry();
  }

  bool get _sameAccount {
    final session = _client.auth.currentSession;
    final expiresAt = session?.expiresAt;
    return _openingUserId.isNotEmpty &&
        widget.expectedUserId == _openingUserId &&
        session?.user.id == _openingUserId &&
        _client.auth.currentUser?.id == _openingUserId &&
        (!widget.requireFreshSession ||
            expiresAt == null ||
            expiresAt * 1000 > DateTime.now().millisecondsSinceEpoch);
  }

  void _revoke() {
    if (!mounted || _revoked) return;
    _expiry?.cancel();
    // This is intentionally permanent for this page instance. Signing back in
    // cannot restore the old widget or an in-flight response from its account.
    setState(() => _revoked = true);
  }

  void _scheduleExpiry() {
    _expiry?.cancel();
    if (!widget.requireFreshSession) return;
    final session = _client.auth.currentSession;
    final expiresAt = session?.expiresAt;
    if (expiresAt == null) return;
    final delay = Duration(
      milliseconds: expiresAt * 1000 - DateTime.now().millisecondsSinceEpoch,
    );
    if (delay <= Duration.zero) {
      _revoke();
      return;
    }
    final token = session!.accessToken;
    _expiry = Timer(delay, () {
      if (_client.auth.currentSession?.accessToken == token || !_sameAccount) {
        _revoke();
      }
    });
  }

  @override
  void didUpdateWidget(AccountSessionGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameAccount ||
        (widget.client != null && !identical(widget.client, _client))) {
      _revoke();
    } else if (!_revoked) {
      _scheduleExpiry();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _revoked) return;
    if (!_sameAccount) {
      _revoke();
    } else {
      _scheduleExpiry();
    }
  }

  @override
  void dispose() {
    _authChanges?.cancel();
    _expiry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_revoked || !_sameAccount) {
      return Scaffold(
        appBar: AppBar(title: const Text('Account access')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(widget.closedMessage),
          ),
        ),
      );
    }
    return KeyedSubtree(
      key: ValueKey('account-page:$_openingUserId'),
      child: widget.child,
    );
  }
}

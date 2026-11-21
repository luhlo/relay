import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'alerts.dart';
import 'cloud.dart';
import 'main.dart' show RelayHome;
import 'model.dart';
import 'storage.dart';
import 'home_widget.dart';
import 'widget_appearance.dart';
import 'timer_guard.dart';
import 'timer_guard_settings.dart';
import 'account_privacy.dart';
import 'experience.dart';
import 'account_cache.dart';

Future<bool> confirmRelayLogout(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'Are you sure you want to log out of Relay on this device? '
          'Changes waiting to sync stay privately on this device. Sign in with '
          'the same account again to finish syncing them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    ) ??
    false;

class RelayAppPreferencesButton extends StatelessWidget {
  const RelayAppPreferencesButton({super.key, this.enabled = true});
  final bool enabled;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: !enabled
        ? null
        : () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => const RelayExperienceSettings()),
          ),
    icon: const Icon(Icons.tune_rounded),
    label: const Text('App preferences & help'),
  );
}

String get authRedirect => kIsWeb
    ? '${Uri.base.origin}${Uri.base.path}${accountDeletionRequested(Uri.base) ? '?action=delete-account' : ''}'
    : 'app.relay.relay://login-callback';

List<String> householdChildren(Map<String, dynamic> household) {
  final names = household['child_names'];
  if (names is List && names.isNotEmpty) return List<String>.from(names);
  return [
    household['child_one'] ?? 'Baby 1',
    household['child_two'] ?? 'Baby 2',
  ];
}

String personalTimeAgreement(int hours) {
  final duration = hours == 1 ? '1 hour' : '$hours hours';
  return 'Each person gets $duration of personal time every day, Monday through Sunday. '
      'You can coordinate the schedule together each day.\n\n'
      'Personal time can be used for anything you need to do on your own, including work, school, showering, using the bathroom, running errands, grocery shopping, or simply taking personal time.\n\n'
      'If your time is interrupted, you may pause the clock. The person whose personal-time period is active is responsible for tracking their time and interruptions and sharing the final time with the other person during the handoff.\n\n'
      'If one person needs more than $duration on a particular day, the other person receives one additional hour in their time bank. That free hour can be used whenever they choose.';
}

Future<void> clearDeletedAccountCopies(String userId) async {
  // This is called only after the deletion backend has acknowledged success.
  // Ordinary logout deliberately retains the owner's unsynced private copy.
  await Future.wait([
    CloudStore.clearCachedRecords(userId),
    const AccountContextCache().remove(userId),
  ]);
}

class AccountGate extends StatefulWidget {
  const AccountGate({super.key, this.client, this.createStore});
  final SupabaseClient? client;
  final CloudStore Function(
    SupabaseClient client,
    String userId,
    List<String> names,
    String householdId,
  )?
  createStore;
  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> with WidgetsBindingObserver {
  late final client = widget.client ?? Supabase.instance.client;
  final localStore = RelayStore();
  final contextCache = const AccountContextCache();
  StreamSubscription<AuthState>? subscription;
  Timer? contextRetry;
  bool foreground = true;
  bool refreshingContext = false;
  int refreshGeneration = 0;
  int cloudRevision = 0;
  Map<String, dynamic>? member, household;
  CloudStore? store;
  bool local = false, loading = true, recovery = false;
  bool deletionRequested = kIsWeb && accountDeletionRequested(Uri.base);
  String? error;
  String? loadedUser;
  int localRevision = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    subscription = client.auth.onAuthStateChange.listen(
      (event) {
        if (!mounted) return;
        if (event.event == AuthChangeEvent.passwordRecovery) {
          setState(() => recovery = true);
        }
        if (event.session?.user.id != loadedUser) {
          refresh();
        } else if (event.event == AuthChangeEvent.tokenRefreshed) {
          refresh(showLoading: false);
        }
      },
      onError: (Object _) {
        // An offline token refresh must not hide this account's cached records.
      },
    );
    contextRetry = Timer.periodic(const Duration(minutes: 1), (_) {
      if (foreground && !refreshingContext && client.auth.currentUser != null) {
        refresh(showLoading: false);
      }
    });
    refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground && !refreshingContext && client.auth.currentUser != null) {
      refresh(showLoading: false);
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    contextRetry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _isCurrent(String? uid, int generation) =>
      mounted &&
      generation == refreshGeneration &&
      client.auth.currentUser?.id == uid;

  Future<void> _clearUnavailableWidget() async {
    try {
      await RelayHomeWidget.instance.clear().timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {
      // A native bridge failure cannot restore access the server denied.
    }
  }

  void _useContext(CachedAccountContext cached) {
    final names = householdChildren(cached.household);
    final sameHousehold =
        store?.userId == cached.userId &&
        household?['id'] == cached.household['id'];
    final namesChanged =
        household == null ||
        householdChildren(household!).join('\u0000') != names.join('\u0000');
    member = cached.member;
    household = cached.household;
    if (sameHousehold) {
      store!.childNames
        ..clear()
        ..addAll(names);
    } else {
      final householdId = cached.household['id'] as String;
      store =
          widget.createStore?.call(client, cached.userId, names, householdId) ??
          CloudStore(client, cached.userId, names, householdId: householdId);
    }
    if (!sameHousehold || namesChanged) cloudRevision++;
    error = null;
    loading = false;
  }

  Future<void> refresh({bool showLoading = true}) async {
    final uid = client.auth.currentUser?.id;
    if (!showLoading && refreshingContext) return;
    final generation = ++refreshGeneration;
    final sameAccount = uid != null && loadedUser == uid && store != null;
    refreshingContext = true;
    setState(() {
      loading = !sameAccount;
      error = null;
      // An explicit Settings return reloads changes saved by its subpages.
      // Quiet metadata retries keep the active timer screen mounted.
      if (sameAccount && showLoading) cloudRevision++;
      if (!sameAccount) {
        member = null;
        household = null;
        store = null;
      }
      loadedUser = uid;
    });
    try {
      if (uid == null) {
        if (await RelayHomeWidget.instance.currentContext() == 'local') {
          local = true;
        } else if (!local) {
          await _clearUnavailableWidget();
        }
      }
      if (uid != null) {
        if (!sameAccount) {
          CachedAccountContext? cached;
          try {
            cached = await contextCache.load(uid);
          } catch (_) {
            // Fresh online metadata can still recover an unavailable cache.
          }
          if (!_isCurrent(uid, generation)) return;
          final cachedContext = cached;
          if (cachedContext != null) {
            setState(() => _useContext(cachedContext));
          }
        }
        final fresh = await fetchAccountContext(client, uid);
        if (!_isCurrent(uid, generation)) return;
        if (fresh == null) {
          final wasCached = member != null;
          try {
            await contextCache.remove(uid);
          } catch (_) {
            // Keep the access decision in memory even if device storage fails.
          }
          if (!_isCurrent(uid, generation)) return;
          member = null;
          household = null;
          store = null;
          await _clearUnavailableWidget();
          if (wasCached) {
            error =
                'Your household membership is no longer available. '
                'Any changes waiting to sync remain on this device. '
                'Reconnect or sign in again before joining another household.';
          }
        } else {
          // Use the verified context even if the optional metadata cache fails.
          setState(() => _useContext(fresh));
          try {
            await contextCache.save(fresh);
          } catch (_) {
            // Existing cached records remain usable; a later refresh retries.
          }
        }
      }
    } catch (failure) {
      if (!_isCurrent(uid, generation)) return;
      if (failure is AccountMembershipUnavailable) {
        try {
          if (uid != null) await contextCache.remove(uid);
        } catch (_) {
          // A storage failure must not restore a membership the server denied.
        }
        member = null;
        household = null;
        store = null;
        await _clearUnavailableWidget();
        error =
            'Your household is no longer available. '
            'Your unsynced records remain on this device. Reconnect to review your account.';
      } else if (accountContextRequiresSignIn(failure)) {
        error =
            'Sign in again to reconnect your account. '
            'Your changes waiting to sync remain on this device.';
      } else if (store == null) {
        error =
            'Connect to the internet and open this account once to prepare '
            'it for offline tracking. Your saved records have not been replaced.';
      }
    }
    if (_isCurrent(uid, generation)) {
      refreshingContext = false;
      setState(() => loading = false);
      if (uid != null && deletionRequested) {
        deletionRequested = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) openAccountDeletion();
        });
      }
    }
  }

  Future<void> openAccountDeletion() {
    final deletedUser = client.auth.currentUser?.id;
    return Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (pageContext) => AccountDeletionPage(
          onDeleted: () async {
            try {
              if (deletedUser != null) {
                await clearDeletedAccountCopies(deletedUser);
              }
            } finally {
              await signOut();
            }
          },
          onDone: () => Navigator.pop(pageContext),
        ),
      ),
    );
  }

  Future<void> signOut() async {
    // Local sign-out also works offline and clears the saved Supabase session.
    await client.auth.signOut(scope: SignOutScope.local);
    await RelayHomeWidget.instance.clear();
    final alerts = ShiftAlerts();
    await alerts.initialize();
    await alerts.sync(RelayState());
    if (mounted) {
      setState(() {
        local = false;
        recovery = false;
      });
    }
  }

  Future<void> openLocalMenu() async {
    final state = await localStore.load();
    if (!mounted) return;
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => LocalAccountSettings(
          store: localStore,
          initialChildNames: state.childNames,
          initialPersonalTimeEnabled: state.personalTimeEnabled,
          initialDailyPersonalHours: state.dailyPersonalHours,
          onSignIn: () {
            RelayHomeWidget.instance.clear();
            Navigator.pop(context, false);
            setState(() => local = false);
          },
        ),
      ),
    );
    // Appearance saves on its own page. Reload the dashboard whenever settings
    // closes so it cannot publish an older palette over that confirmed save.
    if (mounted) {
      setState(() => localRevision++);
    }
  }

  Future<void> openHousehold() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HouseholdAccount(
          member: member!,
          household: household!,
          store: store!,
          onSignOut: signOut,
        ),
      ),
    );
    if (mounted && client.auth.currentUser != null) refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (recovery) {
      return PasswordRecovery(onDone: () => setState(() => recovery = false));
    }
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (client.auth.currentUser == null && !local) {
      return AuthForm(
        deletionRequested: deletionRequested,
        onLocal: () => setState(() => local = true),
      );
    }
    if (client.auth.currentUser == null) {
      return RelayHome(
        key: ValueKey('local-$localRevision'),
        store: localStore,
        onMenu: openLocalMenu,
      );
    }
    if (error != null) {
      return Scaffold(
        appBar: AppBar(
          actions: [
            TextButton(
              onPressed: () async {
                if (await confirmRelayLogout(context) && mounted) {
                  await signOut();
                }
              },
              child: const Text('Log out'),
            ),
          ],
        ),
        body: FormPage(
          title: 'Let’s reconnect',
          children: [
            Text(error!),
            FilledButton(onPressed: refresh, child: const Text('Try again')),
            PrivacyAndAccountActions(onDeleteAccount: openAccountDeletion),
          ],
        ),
      );
    }
    if (member == null) {
      return HouseholdSetup(
        onDone: refresh,
        onSignOut: signOut,
        onDeleteAccount: openAccountDeletion,
      );
    }
    return RelayHome(
      key: ValueKey('cloud:$loadedUser:$cloudRevision'),
      store: store,
      onMenu: openHousehold,
    );
  }
}

class LocalAccountSettings extends StatefulWidget {
  const LocalAccountSettings({
    super.key,
    required this.store,
    required this.initialChildNames,
    required this.initialPersonalTimeEnabled,
    required this.initialDailyPersonalHours,
    required this.onSignIn,
  });
  final RelayStore store;
  final List<String> initialChildNames;
  final bool initialPersonalTimeEnabled;
  final int initialDailyPersonalHours;
  final VoidCallback onSignIn;

  @override
  State<LocalAccountSettings> createState() => _LocalAccountSettingsState();
}

class _LocalAccountSettingsState extends State<LocalAccountSettings> {
  late final List<TextEditingController> childNames = [
    for (final name in widget.initialChildNames)
      TextEditingController(text: name),
  ];
  late bool personalTimeEnabled = widget.initialPersonalTimeEnabled;
  late int dailyPersonalHours = widget.initialDailyPersonalHours;
  bool busy = false;
  String? message;

  @override
  void dispose() {
    for (final controller in childNames) {
      controller.dispose();
    }
    super.dispose();
  }

  void setChildCount(int count) => setState(() {
    while (childNames.length < count) {
      childNames.add(TextEditingController());
    }
    while (childNames.length > count) {
      childNames.removeLast().dispose();
    }
  });

  Future<void> save() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final state = await widget.store.load();
      state.childNames = [
        for (final entry in childNames.indexed)
          entry.$2.text.trim().isEmpty
              ? 'Baby ${entry.$1 + 1}'
              : entry.$2.text.trim(),
      ];
      state.personalTimeEnabled = personalTimeEnabled;
      state.dailyPersonalHours = dailyPersonalHours;
      await widget.store.save(state);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          message = 'Could not save these names. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: FormPage(
      title: 'This device',
      children: [
        const Text(
          'Choose the children shown in Baby Time. These names stay on this device until you sign in and import its history.',
        ),
        const Text(
          'How many children?',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var count = 1; count <= 8; count++)
              ChoiceChip(
                label: Text('$count'),
                selected: childNames.length == count,
                onSelected: busy ? null : (_) => setChildCount(count),
              ),
          ],
        ),
        for (final entry in childNames.indexed)
          TextField(
            controller: entry.$2,
            maxLength: 40,
            decoration: InputDecoration(
              labelText: 'Child ${entry.$1 + 1} name (optional)',
            ),
          ),
        const Text(
          'Leave a name blank and Relay will use Baby 1, Baby 2, and so on.',
        ),
        const Divider(),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Daily personal-time agreement',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: const Text(
            'Give each person the same amount of protected personal time every day.',
          ),
          value: personalTimeEnabled,
          onChanged: busy
              ? null
              : (value) => setState(() => personalTimeEnabled = value),
        ),
        if (personalTimeEnabled) ...[
          DropdownButtonFormField<int>(
            initialValue: dailyPersonalHours,
            decoration: const InputDecoration(
              labelText: 'Hours per person each day',
            ),
            items: [
              for (var hours = 1; hours <= 12; hours++)
                DropdownMenuItem(
                  value: hours,
                  child: Text(hours == 1 ? '1 hour' : '$hours hours'),
                ),
            ],
            onChanged: busy
                ? null
                : (value) => setState(() => dailyPersonalHours = value!),
          ),
          Text(personalTimeAgreement(dailyPersonalHours)),
        ],
        if (message != null) Text(message!),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? 'Saving…' : 'Save settings'),
        ),
        const Divider(),
        const TimerGuardSettings(responseMinutes: timerGuardResponseMinutes),
        RelayAppPreferencesButton(enabled: !busy),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => WidgetAppearance(store: widget.store),
                  ),
                ),
          icon: const Icon(Icons.palette_outlined),
          label: const Text('Widget appearance'),
        ),
        OutlinedButton(
          onPressed: busy ? null : widget.onSignIn,
          child: const Text('Sign in or create an account'),
        ),
        const PrivacyAndAccountActions(),
      ],
    ),
  );
}

class FormPage extends StatelessWidget {
  const FormPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 20),
              for (final child in children)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: child,
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class AuthForm extends StatefulWidget {
  const AuthForm({
    super.key,
    required this.onLocal,
    this.deletionRequested = false,
  });
  final VoidCallback onLocal;
  final bool deletionRequested;
  @override
  State<AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<AuthForm> {
  final email = TextEditingController(), password = TextEditingController();
  bool create = false, busy = false, passwordVisible = false;
  String? message;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit({bool reset = false, bool resend = false}) async {
    if (!email.text.trim().contains('@') ||
        (!reset && !resend && password.text.length < 8)) {
      setState(
        () => message =
            'Enter an email address and a password with at least 8 characters.',
      );
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (reset) {
        await auth.resetPasswordForEmail(
          email.text.trim(),
          redirectTo: authRedirect,
        );
        message =
            'If an account exists, check your email for a password reset link.';
      } else if (resend) {
        await auth.resend(
          type: OtpType.signup,
          email: email.text.trim(),
          emailRedirectTo: authRedirect,
        );
        message = 'Check your email for the confirmation link.';
      } else if (create) {
        await auth.signUp(
          email: email.text.trim(),
          password: password.text,
          emailRedirectTo: authRedirect,
        );
        message =
            'Check your email to confirm your account, then sign in here.';
        password.clear();
      } else {
        await auth.signInWithPassword(
          email: email.text.trim(),
          password: password.text,
        );
      }
    } on AuthException catch (e) {
      message = e.message;
    } catch (_) {
      message = 'Unable to connect. Please try again when you are online.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> signInWithGoogle() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final opened = await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: authRedirect,
      );
      if (!opened) {
        message = 'Could not open Google sign-in. Please try again.';
      }
    } on AuthException catch (e) {
      message = e.message;
    } catch (_) {
      message =
          'Unable to open Google sign-in. Check your connection and try again.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FormPage(
      title: widget.deletionRequested
          ? 'Sign in to delete your account'
          : create
          ? 'Create your Relay account'
          : 'Welcome to Relay',
      children: [
        if (widget.deletionRequested)
          const Text(
            'Sign in to your existing account to review and confirm deletion. Signing in does not delete anything.',
          ),
        const Text(
          'Your time, together. Sign in to save your records and share with your household.',
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : signInWithGoogle,
          icon: const Text(
            'G',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          label: const Text('Continue with Google'),
        ),
        const Row(
          children: [
            Expanded(child: Divider()),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('or use email'),
            ),
            Expanded(child: Divider()),
          ],
        ),
        TextField(
          controller: email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        TextField(
          controller: password,
          obscureText: !passwordVisible,
          enableSuggestions: false,
          autocorrect: false,
          autofillHints: [
            create ? AutofillHints.newPassword : AutofillHints.password,
          ],
          decoration: InputDecoration(
            labelText: 'Password (8+ characters)',
            suffixIcon: IconButton(
              tooltip: passwordVisible ? 'Hide password' : 'Show password',
              isSelected: passwordVisible,
              icon: const Icon(Icons.visibility_off_outlined),
              selectedIcon: const Icon(Icons.visibility_outlined),
              onPressed: busy
                  ? null
                  : () => setState(() => passwordVisible = !passwordVisible),
            ),
          ),
        ),
        if (message != null) Text(message!, semanticsLabel: message),
        FilledButton(
          onPressed: busy ? null : submit,
          child: Text(
            busy
                ? 'Please wait…'
                : create
                ? 'Create account'
                : 'Sign in',
          ),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () => setState(() {
                  create = !create;
                  passwordVisible = false;
                  message = null;
                }),
          child: Text(
            create ? 'Already have an account? Sign in' : 'Create an account',
          ),
        ),
        TextButton(
          onPressed: busy ? null : () => submit(reset: true),
          child: const Text('Forgot password?'),
        ),
        TextButton(
          onPressed: busy ? null : () => submit(resend: true),
          child: const Text('Resend confirmation email'),
        ),
        const PrivacyAndAccountActions(),
        const Divider(),
        if (!widget.deletionRequested)
          OutlinedButton(
            onPressed: busy ? null : widget.onLocal,
            child: const Text('Continue with this device’s records'),
          ),
        const Text(
          'Device records stay on this device until you choose to import them into your account.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
}

class HouseholdSetup extends StatefulWidget {
  const HouseholdSetup({
    super.key,
    required this.onDone,
    required this.onSignOut,
    this.onDeleteAccount,
  });
  final Future<void> Function() onDone, onSignOut;
  final VoidCallback? onDeleteAccount;
  @override
  State<HouseholdSetup> createState() => _HouseholdSetupState();
}

class _HouseholdSetupState extends State<HouseholdSetup> {
  final parent = TextEditingController(),
      home = TextEditingController(),
      code = TextEditingController();
  final childNames = <TextEditingController>[TextEditingController()];
  final inviteEmails = <TextEditingController>[];
  final inviteRoles = <String>[];
  final createdInvites = <({String email, String code, String role})>[];
  bool join = false, busy = false;
  String? error, inviteWarning;
  @override
  void dispose() {
    for (final c in [parent, home, code, ...childNames, ...inviteEmails]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    final fields = join ? [parent, code] : [parent, home];
    if (fields.any((f) => f.text.trim().isEmpty)) {
      setState(() => error = 'Please fill in each field.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (join) {
        await Supabase.instance.client.rpc(
          'relay_join_household',
          params: {
            'invite_code': code.text.trim(),
            'parent_name': parent.text.trim(),
          },
        );
        await widget.onDone();
      } else {
        final names = [
          for (final entry in childNames.indexed)
            entry.$2.text.trim().isEmpty
                ? 'Baby ${entry.$1 + 1}'
                : entry.$2.text.trim(),
        ];
        await Supabase.instance.client.rpc(
          'relay_create_household_v2',
          params: {
            'household_name': home.text.trim(),
            'member_name': parent.text.trim(),
            'children': names,
            'caregiver_total': inviteEmails.length + 1,
          },
        );
        final failedInvites = <String>[];
        for (final entry in inviteEmails.indexed) {
          final address = entry.$2.text.trim();
          if (address.isEmpty) continue;
          try {
            final invitation = await Supabase.instance.client.rpc(
              'relay_invite_member',
              params: {
                'member_email': address,
                'member_role': inviteRoles[entry.$1],
              },
            ) as String;
            createdInvites.add((
              email: address,
              code: invitation,
              role: inviteRoles[entry.$1],
            ));
          } catch (_) {
            failedInvites.add(address);
          }
        }
        if (failedInvites.isNotEmpty) {
          inviteWarning =
              'Could not create a code for ${failedInvites.join(', ')}. You can add them later from Settings.';
        }
        if (createdInvites.isEmpty) {
          await widget.onDone();
        }
      }
    } on PostgrestException catch (e) {
      error = e.code == '22P02'
          ? 'Paste the complete invitation code.'
          : e.message;
    } catch (_) {
      error =
          'Could not save your household. Check your connection and try again.';
    }
    if (mounted) setState(() => busy = false);
  }

  Widget field(TextEditingController c, String label, int max) => TextField(
    controller: c,
    maxLength: max,
    decoration: InputDecoration(labelText: label),
  );
  void setChildCount(int count) => setState(() {
    while (childNames.length < count) {
      childNames.add(TextEditingController());
    }
    while (childNames.length > count) {
      childNames.removeLast().dispose();
    }
  });
  void addMember() => setState(() {
    inviteEmails.add(TextEditingController());
    inviteRoles.add('caregiver');
  });
  void removeMember(int index) => setState(() {
    inviteEmails.removeAt(index).dispose();
    inviteRoles.removeAt(index);
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: [
        if (widget.onDeleteAccount != null)
          TextButton(
            onPressed: busy ? null : widget.onDeleteAccount,
            child: const Text('Delete account'),
          ),
        TextButton(
          onPressed: busy
              ? null
              : () async {
                  if (await confirmRelayLogout(context) && mounted) {
                    await widget.onSignOut();
                  }
                },
          child: const Text('Log out'),
        ),
      ],
    ),
    body: createdInvites.isNotEmpty
        ? FormPage(
            title: 'Your family is ready',
            children: [
              const Text(
                'Share each code with the matching family member. They create their own Relay account, verify that email, and join with the code.',
              ),
              if (inviteWarning != null) Text(inviteWarning!),
              for (final invite in createdInvites)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${invite.email} · ${invite.role == 'parent' ? 'Parent' : 'Caregiver'}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(invite.code),
                        TextButton.icon(
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: invite.code),
                          ),
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy code'),
                        ),
                      ],
                    ),
                  ),
                ),
              FilledButton(
                onPressed: widget.onDone,
                child: const Text('Continue to Relay'),
              ),
            ],
          )
        : FormPage(
            title: join ? 'Join your household' : 'Your family’s space',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('I have an invitation code'),
                value: join,
                onChanged: busy ? null : (v) => setState(() => join = v),
              ),
              field(parent, 'Your name', 80),
              if (join)
                field(code, 'Invitation code', 36)
              else ...[
                field(home, 'Household name', 80),
                const Text(
                  'How many children do you have?',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var count = 1; count <= 8; count++)
                      ChoiceChip(
                        label: Text('$count'),
                        selected: childNames.length == count,
                        onSelected: busy ? null : (_) => setChildCount(count),
                      ),
                  ],
                ),
                for (final entry in childNames.indexed)
                  field(entry.$2, 'Child ${entry.$1 + 1} name (optional)', 40),
                const Text(
                  'Leave a name blank and Relay will use Baby 1, Baby 2, and so on.',
                ),
                const Divider(),
                Text(
                  'How many people take care of them? ${inviteEmails.length + 1}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Text(
                  'You count as one. Add relatives, partners, nannies, or other caregivers now, or add them later from Settings.',
                ),
                for (final entry in inviteEmails.indexed)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          TextField(
                            controller: entry.$2,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              labelText:
                                  'Family member ${entry.$1 + 2} email (optional)',
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: inviteRoles[entry.$1],
                                  decoration: const InputDecoration(
                                    labelText: 'Role',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'parent',
                                      child: Text('Parent'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'caregiver',
                                      child: Text('Caregiver'),
                                    ),
                                  ],
                                  onChanged: busy
                                      ? null
                                      : (value) => setState(
                                          () => inviteRoles[entry.$1] = value!,
                                        ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Remove family member',
                                onPressed: busy
                                    ? null
                                    : () => removeMember(entry.$1),
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: busy || inviteEmails.length >= 11
                      ? null
                      : addMember,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add another family member'),
                ),
              ],
              const Text(
                'Only members of your household and authorized Relay administrators can view household records. Each family member controls their own tracking.',
              ),
              if (error != null) Text(error!),
              FilledButton(
                onPressed: busy ? null : submit,
                child: Text(
                  busy
                      ? 'Saving…'
                      : join
                      ? 'Join household'
                      : 'Create household',
                ),
              ),
            ],
          ),
  );
}

class HouseholdAccount extends StatefulWidget {
  const HouseholdAccount({
    super.key,
    required this.member,
    required this.household,
    required this.store,
    required this.onSignOut,
  });
  final Map<String, dynamic> member, household;
  final CloudStore store;
  final Future<void> Function() onSignOut;
  @override
  State<HouseholdAccount> createState() => _HouseholdAccountState();
}

class SignedInAccountEmail extends StatelessWidget {
  const SignedInAccountEmail({super.key, required this.email});
  final String? email;

  @override
  Widget build(BuildContext context) => email == null || email!.isEmpty
      ? const SizedBox.shrink()
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Signed in as',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            SelectableText(email!),
          ],
        );
}

class _HouseholdAccountState extends State<HouseholdAccount> {
  final email = TextEditingController();
  late final TextEditingController familyName = TextEditingController(
    text: widget.household['name'] as String,
  );
  bool busy = false;
  bool personalTimeEnabled = false;
  int dailyPersonalHours = 3;
  bool loadingPersonalTime = true;
  CloudStore? personalTimeStore;
  String inviteRole = 'caregiver';
  String? message, invitation;
  List<Map<String, dynamic>> members = [];
  @override
  void initState() {
    super.initState();
    members = [widget.member];
    if (widget.member['role'] == 'owner') {
      loadPersonalTimeSettings(widget.store.userId);
    }
    loadMembers();
  }

  @override
  void dispose() {
    email.dispose();
    familyName.dispose();
    super.dispose();
  }

  Future<void> saveFamilyName() async {
    final name = familyName.text.trim();
    if (name.isEmpty || name.length > 80) {
      setState(() => message = 'Enter a family name up to 80 characters.');
      return;
    }
    await run(() async {
      await Supabase.instance.client.rpc(
        'relay_update_household_name',
        params: {'new_name': name},
      );
      widget.household['name'] = name;
      message = 'Family name updated.';
    });
  }

  Future<void> savePersonalTimeSettings() async {
    await run(() async {
      final agreementStore = personalTimeStore;
      if (agreementStore == null || widget.member['role'] != 'owner') {
        throw CloudSaveException(
          'Only the household owner can change this agreement.',
        );
      }
      final state = await agreementStore.load();
      state.personalTimeEnabled = personalTimeEnabled;
      state.dailyPersonalHours = dailyPersonalHours;
      await agreementStore.save(state);
      message = agreementStore.syncStatus.value.pending
          ? 'Personal-time agreement saved on this device. It will be shared after syncing.'
          : 'Personal-time agreement updated for your household.';
    });
  }

  Future<void> loadPersonalTimeSettings(String ownerId) async {
    try {
      final agreementStore = ownerId == widget.store.userId
          ? widget.store
          : null;
      final state = await readFamilyMemberRecords(ownerId);
      if (!mounted) return;
      setState(() {
        personalTimeStore = agreementStore;
        personalTimeEnabled = state.personalTimeEnabled;
        dailyPersonalHours = state.dailyPersonalHours;
        loadingPersonalTime = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loadingPersonalTime = false;
        message =
            'Could not load personal-time settings. Reopen this page to retry.';
      });
    }
  }

  Future<void> loadMembers() async {
    try {
      final rows = await Supabase.instance.client
          .from('household_members')
          .select()
          .eq('household_id', widget.household['id'])
          .timeout(const Duration(seconds: 8));
      final owner = rows.cast<Map<String, dynamic>>().where(
        (row) => row['role'] == 'owner',
      );
      if (mounted) setState(() => members = rows);
      if (owner.isNotEmpty) {
        if (widget.member['role'] != 'owner' || loadingPersonalTime) {
          await loadPersonalTimeSettings(owner.first['user_id'] as String);
        }
      } else if (mounted) {
        setState(() {
          loadingPersonalTime = false;
          message = 'Could not find the household owner.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loadingPersonalTime = false;
          message = 'Family membership changes and other members’ Insights need a connection. Your own tracking stays available.';
        });
      }
    }
  }

  Future<RelayState> readFamilyMemberRecords(String userId) async {
    if (userId == widget.store.userId) return widget.store.load();
    // Shared household views are read-only and online-only. They must never
    // populate another person's private offline cache on this account.
    final row = await Supabase.instance.client
        .from('parent_records')
        .select('payload')
        .eq('user_id', userId)
        .single()
        .timeout(const Duration(seconds: 8));
    final state = RelayState.fromJson(
      Map<String, dynamic>.from(row['payload'] as Map),
    );
    state.childNames = householdChildren(widget.household);
    return state;
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } on PostgrestException catch (e) {
      message = e.message;
    } on CloudSaveException catch (e) {
      message = e.message;
    } catch (_) {
      message = 'Could not complete this action. Check your connection and try again.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> importLocal() async {
    final localStore = RelayStore();
    final local = await localStore.load();
    final remote = await widget.store.load();
    if (!canImportRecords(remote)) {
      message = 'This account already has records. Import is available only before you begin cloud tracking, to avoid replacing existing history.';
      return;
    }
    if (local.sessions.isEmpty && local.shifts.isEmpty) {
      message = 'There are no device records to import.';
      return;
    }
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import this device’s records?'),
        content: Text(
          'Copy ${local.sessions.length} sessions and ${local.shifts.length} shifts into your signed-in account? Household members will be able to view them. The original device copy will remain. Child labels will use ${householdChildren(widget.household).join(', ')}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Import records'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    local.childNames = householdChildren(widget.household);
    await widget.store.save(local);
    message = widget.store.syncStatus.value.pending
        ? 'Device history saved to this account on this device and waiting to sync. Your original device records are unchanged.'
        : 'Device history copied to your account. Your original device records are unchanged.';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: FormPage(
      title: widget.household['name'],
      children: [
        SignedInAccountEmail(
          email: Supabase.instance.client.auth.currentUser?.email,
        ),
        if (widget.member['role'] == 'owner') ...[
          TextField(
            controller: familyName,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Family name'),
          ),
          FilledButton(
            onPressed: busy ? null : saveFamilyName,
            child: const Text('Save family name'),
          ),
        ],
        Text(householdChildren(widget.household).join(' · ')),
        const Text(
          'Timers and schedules save on this device first and sync when connected. Shared household and account changes require a connection. Use Refresh to check for changes from another device.',
        ),
        const TimerGuardSettings(responseMinutes: timerGuardResponseMinutes),
        RelayAppPreferencesButton(enabled: !busy),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => WidgetAppearance(store: widget.store),
                  ),
                ),
          icon: const Icon(Icons.palette_outlined),
          label: const Text('Widget appearance'),
        ),
        const Divider(),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Daily personal-time agreement',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: const Text(
            'Give each person the same amount of protected personal time every day. The household owner manages this shared agreement.',
          ),
          value: personalTimeEnabled,
          onChanged:
              busy || loadingPersonalTime || widget.member['role'] != 'owner'
              ? null
              : (value) => setState(() => personalTimeEnabled = value),
        ),
        if (personalTimeEnabled) ...[
          DropdownButtonFormField<int>(
            initialValue: dailyPersonalHours,
            decoration: const InputDecoration(
              labelText: 'Hours per person each day',
            ),
            items: [
              for (var hours = 1; hours <= 12; hours++)
                DropdownMenuItem(
                  value: hours,
                  child: Text(hours == 1 ? '1 hour' : '$hours hours'),
                ),
            ],
            onChanged: busy || widget.member['role'] != 'owner'
                ? null
                : (value) => setState(() => dailyPersonalHours = value!),
          ),
          Text(personalTimeAgreement(dailyPersonalHours)),
        ],
        if (widget.member['role'] == 'owner')
          FilledButton(
            onPressed: busy || loadingPersonalTime
                ? null
                : savePersonalTimeSettings,
            child: const Text('Save personal-time settings'),
          ),
        const Text(
          'Family members',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        for (final member in members)
          OutlinedButton(
            onPressed: busy
                ? null
                : () => run(() async {
                    final records = await readFamilyMemberRecords(
                      member['user_id'] as String,
                    );
                    if (!context.mounted) return;
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => Scaffold(
                          appBar: AppBar(
                            title: Text('${member['display_name']} · Insights'),
                          ),
                          body: RelayHome(
                            store: ReadOnlyStore(records),
                            readOnly: true,
                          ),
                        ),
                      ),
                    );
                  }),
            child: Text(
              'View ${member['display_name']}’s Insights · ${member['role'] == 'caregiver' ? 'Caregiver' : 'Parent'}',
            ),
          ),
        if (widget.member['role'] == 'owner') ...[
          const Divider(),
          TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Family member’s email',
            ),
          ),
          DropdownButtonFormField<String>(
            initialValue: 'caregiver',
            decoration: const InputDecoration(labelText: 'Role'),
            items: const [
              DropdownMenuItem(value: 'parent', child: Text('Parent')),
              DropdownMenuItem(value: 'caregiver', child: Text('Caregiver')),
            ],
            onChanged: busy ? null : (value) => inviteRole = value!,
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () => run(() async {
                    invitation = await Supabase.instance.client.rpc(
                      'relay_invite_member',
                      params: {
                        'member_email': email.text.trim(),
                        'member_role': inviteRole,
                      },
                    ) as String;
                  }),
            child: const Text('Add family member'),
          ),
          if (invitation != null) ...[
            SelectableText(invitation!),
            const Text(
              'Share this code with that family member. It expires after 7 days and works only for the email you entered. They create an account, verify that email, and choose “I have an invitation code.”',
            ),
            OutlinedButton(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: invitation!)),
              child: const Text('Copy invitation code'),
            ),
          ],
        ],
        const Divider(),
        OutlinedButton(
          onPressed: busy ? null : () => run(importLocal),
          child: const Text('Import this device’s history'),
        ),
        if (message != null) Text(message!),
        if (busy) const LinearProgressIndicator(),
        TextButton(
          onPressed: busy
              ? null
              : () async {
                  if (!await confirmRelayLogout(context) || !context.mounted) {
                    return;
                  }
                  await widget.onSignOut();
                  if (context.mounted) Navigator.pop(context);
                },
          child: const Text('Log out'),
        ),
        PrivacyAndAccountActions(
          onDeleteAccount: busy
              ? null
              : () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (pageContext) => AccountDeletionPage(
                      onDeleted: () async {
                        try {
                          await clearDeletedAccountCopies(widget.store.userId);
                        } finally {
                          await widget.onSignOut();
                        }
                      },
                      onDone: () {
                        Navigator.pop(pageContext);
                        if (context.mounted) Navigator.pop(context);
                      },
                    ),
                  ),
                ),
        ),
      ],
    ),
  );
}

class PasswordRecovery extends StatefulWidget {
  const PasswordRecovery({super.key, required this.onDone});
  final VoidCallback onDone;
  @override
  State<PasswordRecovery> createState() => _PasswordRecoveryState();
}

class _PasswordRecoveryState extends State<PasswordRecovery> {
  final password = TextEditingController();
  bool busy = false, passwordVisible = false;
  String? message;
  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FormPage(
      title: 'Choose a new password',
      children: [
        TextField(
          controller: password,
          obscureText: !passwordVisible,
          enableSuggestions: false,
          autocorrect: false,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(
            labelText: 'New password (8+ characters)',
            suffixIcon: IconButton(
              tooltip: passwordVisible ? 'Hide password' : 'Show password',
              isSelected: passwordVisible,
              icon: const Icon(Icons.visibility_off_outlined),
              selectedIcon: const Icon(Icons.visibility_outlined),
              onPressed: busy
                  ? null
                  : () => setState(() => passwordVisible = !passwordVisible),
            ),
          ),
        ),
        if (message != null) Text(message!),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  if (password.text.length < 8) {
                    setState(() => message = 'Use at least 8 characters.');
                    return;
                  }
                  setState(() => busy = true);
                  try {
                    await Supabase.instance.client.auth.updateUser(
                      UserAttributes(password: password.text),
                    );
                    widget.onDone();
                  } on AuthException catch (e) {
                    message = e.message;
                  } catch (_) {
                    message = 'Unable to connect. Please try again.';
                  }
                  if (mounted) setState(() => busy = false);
                },
          child: const Text('Save password'),
        ),
      ],
    ),
  );
}

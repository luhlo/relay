import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
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
import 'account_session_guard.dart';
import 'household_management.dart';

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
  // Keep setup fields and newly created invitation codes visible until the
  // person explicitly continues. Quiet metadata refreshes must not replace it.
  String? setupUser;
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
    if (!showLoading && uid != null && setupUser == uid) return;
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
        if (uid != loadedUser) setupUser = null;
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
          if (!wasCached) setupUser = uid;
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

  Future<void> finishHouseholdSetup() {
    setupUser = null;
    return refresh();
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
    final openingStore = store;
    final openingMember = member;
    final openingHousehold = household;
    if (openingStore == null ||
        openingMember == null ||
        openingHousehold == null ||
        client.auth.currentUser?.id != openingStore.userId) {
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AccountSessionGuard(
          client: client,
          expectedUserId: openingStore.userId,
          child: HouseholdAccount(
            member: openingMember,
            household: openingHousehold,
            store: openingStore,
            onSignOut: signOut,
          ),
        ),
      ),
    );
    if (mounted && client.auth.currentUser != null) refresh();
  }

  Future<void> openSavedTime() async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => AccountSessionGuard(
          client: client,
          expectedUserId: userId,
          child: PersonalTimeHistoryPage(
            service: HouseholdManagementService(client, userId),
          ),
        ),
      ),
    );
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
        client: client,
        onDone: finishHouseholdSetup,
        onSignOut: signOut,
        onDeleteAccount: openAccountDeletion,
        onViewSavedTime: openSavedTime,
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
        () => message = reset || resend ? 'Enter a valid email address.' : 'Enter an email address and a password with at least 8 characters.',
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
    this.client,
    this.onViewSavedTime,
  });
  final Future<void> Function() onDone, onSignOut;
  final VoidCallback? onDeleteAccount;
  final SupabaseClient? client;
  final VoidCallback? onViewSavedTime;
  @override
  State<HouseholdSetup> createState() => _HouseholdSetupState();
}

class _HouseholdSetupState extends State<HouseholdSetup> {
  SupabaseClient get client => widget.client ?? Supabase.instance.client;
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
        await client.rpc(
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
        await client.rpc(
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
            final invitation = await client.rpc(
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
              if (widget.onViewSavedTime != null)
                OutlinedButton.icon(
                  onPressed: busy ? null : widget.onViewSavedTime,
                  icon: const Icon(Icons.history),
                  label: const Text('Your saved time'),
                ),
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
    this.managementService,
  });
  final Map<String, dynamic> member, household;
  final CloudStore store;
  final Future<void> Function() onSignOut;
  final HouseholdManagementService? managementService;
  @override
  State<HouseholdAccount> createState() => _HouseholdAccountState();
}

/// A read-only observation, not a live projection of another person's timer.
/// Refresh is explicit and never writes another person's records to this device.
class FamilyMemberInsightsPage extends StatefulWidget {
  const FamilyMemberInsightsPage({
    super.key,
    required this.displayName,
    required this.initialRecords,
    required this.initialObservedAt,
    required this.loadRecords,
    this.clock = DateTime.now,
  });

  final String displayName;
  final RelayState initialRecords;
  final DateTime initialObservedAt;
  final Future<RelayState> Function() loadRecords;
  final DateTime Function() clock;

  @override
  State<FamilyMemberInsightsPage> createState() =>
      _FamilyMemberInsightsPageState();
}

class _FamilyMemberInsightsPageState extends State<FamilyMemberInsightsPage> {
  late RelayState records = RelayState.fromJson(widget.initialRecords.toJson());
  late DateTime observedAt = widget.initialObservedAt;
  int generation = 0;
  bool refreshing = false;
  String? error;

  Future<void> refresh() async {
    if (refreshing) return;
    setState(() {
      refreshing = true;
      error = null;
    });
    try {
      final latest = await widget.loadRecords();
      if (!mounted) return;
      setState(() {
        records = RelayState.fromJson(latest.toJson());
        observedAt = widget.clock();
        generation++;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          error = 'Could not refresh. Showing the last snapshot. Check your connection and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('${widget.displayName} · Insights')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Snapshot · ${DateFormat.yMMMd().add_jm().format(observedAt)}\nRefresh to see new activity.',
                  key: const ValueKey('family-insights-snapshot-time'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                tooltip: 'Refresh family Insights',
                onPressed: refreshing ? null : refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (refreshing) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: RelayHome(
            key: ValueKey('family-insights-$generation'),
            store: ReadOnlyStore(records),
            readOnly: true,
            observationTime: observedAt,
          ),
        ),
      ],
    ),
  );
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
  late final childNames = [
    for (var index = 0; index < 8; index++)
      TextEditingController(
        text: index < householdChildren(widget.household).length
            ? householdChildren(widget.household)[index]
            : '',
      ),
  ];
  late int childCount = householdChildren(widget.household).length;
  late final management =
      widget.managementService ??
      HouseholdManagementService(widget.store.client, widget.store.userId);
  bool get isOwner => widget.member['role'] == 'owner';
  bool busy = false;
  bool loadingMembers = false, loadingInvitations = false;
  String? invitationError, invitationEmail, memberError;
  List<HouseholdInvitation> pendingInvitations = [];
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
    if (isOwner) loadInvitations();
  }

  @override
  void dispose() {
    email.dispose();
    familyName.dispose();
    for (final controller in childNames) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> saveFamilyName() async {
    final name = familyName.text.trim();
    if (name.isEmpty || name.length > 80) {
      setState(() => message = 'Enter a family name up to 80 characters.');
      return;
    }
    await run(() async {
      await widget.store.client.rpc(
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
    if (loadingMembers) return;
    setState(() => loadingMembers = true);
    try {
      final rows = await widget.store.client
          .from('household_members')
          .select()
          .eq('household_id', widget.household['id'])
          .eq('is_active', true)
          .timeout(const Duration(seconds: 8));
      final owner = rows.cast<Map<String, dynamic>>().where(
        (row) => row['role'] == 'owner',
      );
      if (mounted) {
        setState(() {
          members = rows;
          memberError = null;
        });
      }
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
          memberError = 'Could not refresh family members. Showing the last loaded list. Your own tracking stays available.';
        });
      }
    } finally {
      if (mounted) setState(() => loadingMembers = false);
    }
  }

  Future<void> loadInvitations() async {
    if (!isOwner || loadingInvitations) return;
    setState(() => loadingInvitations = true);
    try {
      final rows = await management.invitations();
      if (!mounted) return;
      setState(() {
        pendingInvitations = rows;
        invitationError = null;
        if (invitation != null && !rows.any((row) => row.code == invitation)) {
          invitation = null;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          invitationError = 'Could not refresh invitations. Showing the last loaded list. Refresh before creating or changing another invitation.';
        });
      }
    } finally {
      if (mounted) setState(() => loadingInvitations = false);
    }
  }

  Future<void> refreshHouseholdLists() async {
    await Future.wait([loadMembers(), if (isOwner) loadInvitations()]);
  }

  bool get sameAccount =>
      widget.store.client.auth.currentUser?.id == widget.store.userId;

  Future<bool> confirmManagement({
    required String title,
    required String description,
    required String button,
  }) async {
    if (!sameAccount || busy) return false;
    BuildContext? dialogContext;
    var accountChanged = false;
    final subscription = widget.store.client.auth.onAuthStateChange.listen((_) {
      if (sameAccount) return;
      accountChanged = true;
      final currentDialog = dialogContext;
      if (currentDialog != null &&
          currentDialog.mounted &&
          ModalRoute.of(currentDialog)?.isCurrent == true) {
        Navigator.pop(currentDialog, false);
      }
    });
    try {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) {
          dialogContext = context;
          if (accountChanged || !sameAccount) {
            return AlertDialog(
              title: const Text('Account changed'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Close'),
                ),
              ],
            );
          }
          return AlertDialog(
            title: Text(title),
            content: Text(description),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(button),
              ),
            ],
          );
        },
      );
      return approved == true && sameAccount && !accountChanged;
    } finally {
      unawaited(subscription.cancel());
    }
  }

  Future<void> saveChildren() => run(() async {
    final names = await management.updateChildren([
      for (final controller in childNames.take(childCount)) controller.text,
    ]);
    if (!mounted) return;
    widget.household['child_names'] = List<String>.of(names);
    widget.household['child_one'] = names.first;
    widget.household['child_two'] = names.length > 1 ? names[1] : 'Baby 2';
    widget.store.childNames
      ..clear()
      ..addAll(names);
    for (final entry in names.indexed) {
      childNames[entry.$1].text = entry.$2;
    }
    message = 'Children updated for your household.';
    // The server save is already confirmed. Optional device/widget refreshes
    // cannot turn it into a failed save or trigger another management write.
    unawaited(() async {
      try {
        final cached = CachedAccountContext.fromRows(
          userId: widget.store.userId,
          member: widget.member,
          household: widget.household,
        );
        if (cached != null) await const AccountContextCache().save(cached);
        if (!sameAccount) return;
        final records = await widget.store.load();
        if (!sameAccount) return;
        await RelayHomeWidget.instance
            .sync(records, 'cloud:${widget.store.userId}', DateTime.now())
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // Returning to Today reloads the confirmed household metadata.
      }
    }());
  });

  Future<void> inviteMember() => run(() async {
    final address = email.text.trim();
    final code = await management.inviteMember(address, inviteRole);
    if (!mounted) return;
    invitation = code;
    invitationEmail = address;
    email.clear();
    message = 'Invitation ready. Share its code with that family member.';
    await loadInvitations();
  });

  Future<void> revokeInvitation(HouseholdInvitation row) async {
    final approved = await confirmManagement(
      title: 'Revoke this invitation?',
      description:
          'The invitation for ${row.email} will stop working. They will need a new code to join your household.',
      button: 'Revoke invitation',
    );
    if (!approved || !mounted) return;
    await run(() async {
      await management.revokeInvitation(row.code);
      if (!mounted) return;
      pendingInvitations.removeWhere((value) => value.code == row.code);
      if (invitation == row.code) invitation = null;
      message = 'Invitation revoked.';
      await loadInvitations();
    });
  }

  Future<void> removeFamilyMember(Map<String, dynamic> member) async {
    if (!isOwner ||
        member['role'] == 'owner' ||
        member['user_id'] == widget.store.userId) {
      return;
    }
    final approved = await confirmManagement(
      title: 'Remove ${member['display_name']}?',
      description: 'They will lose access to this household. Their personal time records are kept. Previously saved data on their device isn’t erased.',
      button: 'Remove member',
    );
    if (!approved || !mounted) return;
    await run(() async {
      await management.removeMember(member['user_id'] as String);
      if (!mounted) return;
      members.removeWhere((row) => row['user_id'] == member['user_id']);
      message =
          '${member['display_name']} was removed. Their own time records were kept privately.';
      await loadMembers();
    });
  }

  Future<void> copyInvitation(String code) async {
    try {
      await Clipboard.setData(ClipboardData(text: code));
      if (mounted) setState(() => message = 'Invitation code copied.');
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              message = 'Could not copy. Select the code and copy it manually.',
        );
      }
    }
  }

  Future<void> openPersonalHistory() => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => AccountSessionGuard(
        client: widget.store.client,
        expectedUserId: widget.store.userId,
        child: PersonalTimeHistoryPage(service: management),
      ),
    ),
  );

  Future<RelayState> readFamilyMemberRecords(String userId) async {
    if (userId == widget.store.userId) return widget.store.load();
    // Shared household views are read-only and online-only. They must never
    // populate another person's private offline cache on this account.
    final row = await widget.store.client
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
    if (busy) return;
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
    } on HouseholdManagementException catch (e) {
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
          email: widget.store.client.auth.currentUser?.email,
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
          ExpansionTile(
            title: const Text('Children'),
            subtitle: Text(householdChildren(widget.household).join(' · ')),
            childrenPadding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('How many children?'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var count = 1; count <= 8; count++)
                    ChoiceChip(
                      label: Text('$count'),
                      selected: childCount == count,
                      onSelected: busy
                          ? null
                          : (_) => setState(() => childCount = count),
                    ),
                ],
              ),
              for (final entry in childNames.take(childCount).indexed)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: TextField(
                    controller: entry.$2,
                    maxLength: 40,
                    enabled: !busy,
                    decoration: InputDecoration(
                      labelText: 'Child ${entry.$1 + 1} name (optional)',
                    ),
                  ),
                ),
              const Text(
                'Blank names become Baby 1, Baby 2 and so on. Keep each child in the same numbered position.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Names apply to past Baby Time. Reducing the count hides children from selection without deleting recorded time.',
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : saveChildren,
                child: const Text('Save children'),
              ),
            ],
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
                    builder: (_) => AccountSessionGuard(
                      client: widget.store.client,
                      expectedUserId: widget.store.userId,
                      child: WidgetAppearance(store: widget.store),
                    ),
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
        OutlinedButton.icon(
          onPressed: busy || loadingMembers || loadingInvitations
              ? null
              : refreshHouseholdLists,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh household'),
        ),
        if (loadingMembers) const LinearProgressIndicator(),
        if (memberError != null) Text(memberError!),
        for (final member in members)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        final records = await readFamilyMemberRecords(
                          member['user_id'] as String,
                        );
                        final observedAt = DateTime.now();
                        if (!context.mounted) return;
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AccountSessionGuard(
                              client: widget.store.client,
                              expectedUserId: widget.store.userId,
                              child: FamilyMemberInsightsPage(
                                displayName: member['display_name'] as String,
                                initialRecords: records,
                                initialObservedAt: observedAt,
                                loadRecords: () => readFamilyMemberRecords(
                                  member['user_id'] as String,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                child: Text(
                  'View ${member['display_name']}’s Insights · ${member['role'] == 'caregiver' ? 'Caregiver' : 'Parent'}',
                ),
              ),
              if (isOwner &&
                  member['role'] != 'owner' &&
                  member['user_id'] != widget.store.userId)
                TextButton.icon(
                  onPressed: busy || loadingMembers
                      ? null
                      : () => removeFamilyMember(member),
                  icon: const Icon(Icons.person_remove_outlined),
                  label: Text('Remove ${member['display_name']}'),
                ),
            ],
          ),
        if (widget.member['role'] == 'owner') ...[
          const Divider(),
          TextField(
            controller: email,
            enabled: !busy,
            maxLength: 254,
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
            onPressed: busy || loadingInvitations ? null : inviteMember,
            child: const Text('Add family member'),
          ),
          if (invitation != null && invitationError != null) ...[
            Text('Invitation for ${invitationEmail ?? 'your family member'}'),
            SelectableText(invitation!),
            const Text(
              'Share this code with that family member. It expires after 7 days and works only for the email you entered. They create an account, verify that email, and choose “I have an invitation code.”',
            ),
            OutlinedButton(
              onPressed: () => copyInvitation(invitation!),
              child: const Text('Copy invitation code'),
            ),
          ],
          const Text(
            'Pending invitations',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(
            'These codes were pending at the last refresh. Refresh to check for accepted or expired invitations. Share each code only with the email shown.',
          ),
          if (loadingInvitations) const LinearProgressIndicator(),
          if (invitationError != null) Text(invitationError!),
          if (!loadingInvitations &&
              invitationError == null &&
              pendingInvitations.isEmpty)
            const Text('No pending invitations.'),
          for (final row in pendingInvitations)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      row.email,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${row.role == 'parent' ? 'Parent' : 'Caregiver'} · Expires ${DateFormat.yMMMd().add_jm().format(row.expiresAt.toLocal())}',
                    ),
                    const SizedBox(height: 10),
                    SelectableText(row.code),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: busy
                              ? null
                              : () => copyInvitation(row.code),
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy code'),
                        ),
                        TextButton.icon(
                          onPressed: busy || loadingInvitations
                              ? null
                              : () => revokeInvitation(row),
                          icon: const Icon(Icons.link_off),
                          label: const Text('Revoke invitation'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
        const Divider(),
        OutlinedButton.icon(
          onPressed: busy ? null : openPersonalHistory,
          icon: const Icon(Icons.history),
          label: const Text('Your saved time'),
        ),
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

/// Previous-household copies are private, fixed observations. They are never
/// loaded through a writable CloudStore or imported into a newly joined family.
class PersonalTimeHistoryPage extends StatefulWidget {
  const PersonalTimeHistoryPage({super.key, required this.service, this.cache});
  final HouseholdManagementService service;
  final CloudCache? cache;

  @override
  State<PersonalTimeHistoryPage> createState() =>
      _PersonalTimeHistoryPageState();
}

class _PersonalTimeHistoryPageState extends State<PersonalTimeHistoryPage> {
  List<PersonalTimeArchive> snapshots = [];
  String? selectedId, error;
  RelayState? records;
  bool loading = false;
  int revision = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  List<String> snapshotNames(Map<String, dynamic> payload) {
    final names = payload['childNames'];
    return names is List &&
            names.isNotEmpty &&
            names.length <= 8 &&
            names.every((name) => name is String)
        ? List<String>.from(names)
        : ['Baby 1', 'Baby 2'];
  }

  Future<List<PersonalTimeArchive>> deviceSnapshots() async {
    final envelope = await (widget.cache ?? defaultCloudCache).read(
      widget.service.expectedUserId,
    );
    if (envelope == null) return [];
    final observedAt = DateTime.now();
    final result = <PersonalTimeArchive>[];
    final current = envelope['current'];
    if (current is Map) {
      final payload = Map<String, dynamic>.from(current);
      result.add(
        PersonalTimeArchive(
          id: 'device-current',
          householdName: 'This device · latest saved copy',
          childNames: snapshotNames(payload),
          payload: payload,
          archivedAt: observedAt,
          fromDevice: true,
        ),
      );
    }
    final backups = envelope['backups'];
    if (backups is List) {
      for (final entry in backups.indexed) {
        final value = entry.$2;
        if (value is! Map || value['payload'] is! Map) continue;
        final payload = Map<String, dynamic>.from(value['payload'] as Map);
        result.add(
          PersonalTimeArchive(
            id: 'device-backup-${entry.$1}-${value['id'] ?? ''}',
            householdName: value['label'] as String? ?? 'Device recovery copy',
            childNames: snapshotNames(payload),
            payload: payload,
            archivedAt:
                DateTime.tryParse(value['createdAt']?.toString() ?? '') ??
                observedAt,
            fromDevice: true,
          ),
        );
      }
    }
    return result;
  }

  Future<void> load() async {
    if (loading) return;
    setState(() => loading = true);
    var local = <PersonalTimeArchive>[];
    var cloud = <PersonalTimeArchive>[];
    var localFailed = false, cloudFailed = false;
    await Future.wait([
      () async {
        try {
          local = await deviceSnapshots();
          if (mounted && local.isNotEmpty) {
            setState(() {
              snapshots = [
                ...local,
                ...snapshots.where((copy) => !copy.fromDevice),
              ];
              selectSnapshot(
                snapshots.any((copy) => copy.id == selectedId)
                    ? selectedId
                    : snapshots.first.id,
              );
            });
          }
        } catch (_) {
          localFailed = true;
        }
      }(),
      () async {
        try {
          cloud = await widget.service.personalArchives();
        } catch (_) {
          cloudFailed = true;
        }
      }(),
    ]);
    if (!mounted) return;
    if (localFailed) {
      local = snapshots.where((copy) => copy.fromDevice).toList();
    }
    if (cloudFailed) {
      cloud = snapshots.where((copy) => !copy.fromDevice).toList();
    }
    setState(() {
      snapshots = [...local, ...cloud];
      loading = false;
      error = cloudFailed
          ? snapshots.isEmpty
                ? 'Could not load your cloud saved time. Reconnect and tap Refresh.'
                : 'Could not refresh your cloud saved time. Showing saved copies. Reconnect and tap Refresh.'
          : localFailed
          ? 'Could not read this device’s copies. Cloud snapshots are still available. Tap Refresh to retry.'
          : null;
      selectSnapshot(
        snapshots.any((copy) => copy.id == selectedId)
            ? selectedId
            : snapshots.firstOrNull?.id,
      );
    });
  }

  void selectSnapshot(String? id) {
    selectedId = id;
    final selected = snapshots.where((copy) => copy.id == id).firstOrNull;
    records = null;
    if (selected != null) {
      try {
        final state = RelayState.fromJson(selected.payload);
        state.childNames = List<String>.of(selected.childNames);
        records = state;
      } catch (_) {
        error = 'This saved copy could not be read. Choose another copy or refresh.';
      }
    }
    revision++;
  }

  @override
  Widget build(BuildContext context) {
    final selected = snapshots
        .where((copy) => copy.id == selectedId)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your saved time'),
        actions: [
          IconButton(
            tooltip: 'Refresh your saved time',
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .45,
              ),
              child: SingleChildScrollView(
                primary: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Private copies of your own time. Viewing a copy does not add it to another household.',
                      ),
                      if (snapshots.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          key: ValueKey('saved-time-selector-$selectedId'),
                          initialValue: selectedId,
                          isExpanded: true,
                          itemHeight: null,
                          decoration: const InputDecoration(
                            labelText: 'Saved copy',
                          ),
                          items: [
                            for (final copy in snapshots)
                              DropdownMenuItem(
                                value: copy.id,
                                child: Text(
                                  '${copy.householdName} · ${DateFormat.yMMMd().add_jm().format(copy.archivedAt.toLocal())}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) =>
                              setState(() => selectSnapshot(value)),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          selected?.fromDevice == true
                              ? 'Device snapshot · May include changes that have not synced.'
                              : 'Cloud snapshot · Saved when your household access ended.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (loading)
              const LinearProgressIndicator(
                key: ValueKey('saved-time-loading'),
              ),
            if (!loading && snapshots.isEmpty && error == null)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No previous-household snapshots yet. Your current household time is available in Today and Insights.',
                    ),
                  ),
                ),
              )
            else if (records != null && selected != null)
              Expanded(
                child: RelayHome(
                  key: ValueKey('saved-time-$selectedId-$revision'),
                  store: ReadOnlyStore(records!),
                  readOnly: true,
                  observationTime: selected.archivedAt.toLocal(),
                ),
              )
            else
              const Spacer(),
          ],
        ),
      ),
    );
  }
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

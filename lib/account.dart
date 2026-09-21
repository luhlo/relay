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

String get authRedirect => kIsWeb
    ? '${Uri.base.origin}${Uri.base.path}'
    : 'app.relay.relay://login-callback';

List<String> householdChildren(Map<String, dynamic> household) {
  final names = household['child_names'];
  if (names is List && names.isNotEmpty) return List<String>.from(names);
  return [
    household['child_one'] ?? 'Baby 1',
    household['child_two'] ?? 'Baby 2',
  ];
}

class AccountGate extends StatefulWidget {
  const AccountGate({super.key});
  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> {
  final client = Supabase.instance.client;
  final localStore = RelayStore();
  StreamSubscription<AuthState>? subscription;
  Map<String, dynamic>? member, household;
  CloudStore? store;
  bool local = false, loading = true, recovery = false;
  String? error;
  String? loadedUser;
  int localRevision = 0;
  @override
  void initState() {
    super.initState();
    subscription = client.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.passwordRecovery) {
        setState(() => recovery = true);
      }
      if (event.session?.user.id != loadedUser) refresh();
    });
    refresh();
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    final uid = client.auth.currentUser?.id;
    setState(() {
      loading = true;
      error = null;
      member = null;
      household = null;
      store = null;
      loadedUser = uid;
    });
    try {
      if (uid != null) {
        final row = await client
            .from('household_members')
            .select()
            .eq('user_id', uid)
            .maybeSingle();
        if (row != null) {
          final home = await client
              .from('households')
              .select()
              .eq('id', row['household_id'])
              .single();
          if (!mounted || client.auth.currentUser?.id != uid) return;
          member = row;
          household = home;
          store = CloudStore(client, uid, householdChildren(home));
        }
      }
    } catch (_) {
      error =
          'Could not load your household. Check your connection and try again.';
    }
    if (mounted && client.auth.currentUser?.id == uid) {
      setState(() => loading = false);
    }
  }

  Future<void> signOut() async {
    // Local sign-out also works offline and clears the saved Supabase session.
    await client.auth.signOut(scope: SignOutScope.local);
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
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => LocalAccountSettings(
          store: localStore,
          initialChildNames: state.childNames,
          onSignIn: () {
            Navigator.pop(context, false);
            setState(() => local = false);
          },
        ),
      ),
    );
    if (changed == true && mounted) {
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
      return AuthForm(onLocal: () => setState(() => local = true));
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
            TextButton(onPressed: signOut, child: const Text('Sign out')),
          ],
        ),
        body: FormPage(
          title: 'Let’s reconnect',
          children: [
            Text(error!),
            FilledButton(onPressed: refresh, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (member == null) {
      return HouseholdSetup(onDone: refresh, onSignOut: signOut);
    }
    return RelayHome(
      key: ObjectKey(store),
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
    required this.onSignIn,
  });
  final RelayStore store;
  final List<String> initialChildNames;
  final VoidCallback onSignIn;

  @override
  State<LocalAccountSettings> createState() => _LocalAccountSettingsState();
}

class _LocalAccountSettingsState extends State<LocalAccountSettings> {
  late final List<TextEditingController> childNames = [
    for (final name in widget.initialChildNames)
      TextEditingController(text: name),
  ];
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
    appBar: AppBar(title: const Text('Account & family')),
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
        if (message != null) Text(message!),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? 'Saving…' : 'Save child settings'),
        ),
        const Divider(),
        OutlinedButton(
          onPressed: busy ? null : widget.onSignIn,
          child: const Text('Sign in or create an account'),
        ),
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
  const AuthForm({super.key, required this.onLocal});
  final VoidCallback onLocal;
  @override
  State<AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<AuthForm> {
  final email = TextEditingController(), password = TextEditingController();
  bool create = false, busy = false;
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
      title: create ? 'Create your Relay account' : 'Welcome to Relay',
      children: [
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
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          autofillHints: [
            create ? AutofillHints.newPassword : AutofillHints.password,
          ],
          decoration: const InputDecoration(
            labelText: 'Password (8+ characters)',
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
        const Divider(),
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
  });
  final Future<void> Function() onDone, onSignOut;
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
              'Could not create a code for ${failedInvites.join(', ')}. You can add them later from Household.';
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
        TextButton(
          onPressed: busy ? null : widget.onSignOut,
          child: const Text('Sign out'),
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
                  'You count as one. Add relatives, partners, nannies, or other caregivers now, or add them later from Household.',
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

class _HouseholdAccountState extends State<HouseholdAccount> {
  final email = TextEditingController();
  late final TextEditingController familyName = TextEditingController(
    text: widget.household['name'] as String,
  );
  bool busy = false;
  String inviteRole = 'caregiver';
  String? message, invitation;
  List<Map<String, dynamic>> members = [];
  @override
  void initState() {
    super.initState();
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

  Future<void> loadMembers() async {
    try {
      final rows = await Supabase.instance.client
          .from('household_members')
          .select()
          .eq('household_id', widget.household['id']);
      if (mounted) setState(() => members = rows);
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Could not load family members. Reopen this page to retry.',
        );
      }
    }
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
    message = 'Device history copied to your account. Your original device records are unchanged.';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Household')),
    body: FormPage(
      title: widget.household['name'],
      children: [
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
          'Cloud changes require a connection. Use Refresh to load changes made on another device.',
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
                    final records = await CloudStore(
                      Supabase.instance.client,
                      member['user_id'],
                      householdChildren(widget.household),
                    ).load();
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
                  await widget.onSignOut();
                  if (context.mounted) Navigator.pop(context);
                },
          child: const Text('Sign out'),
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
  bool busy = false;
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
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'New password (8+ characters)',
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

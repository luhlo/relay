import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_theme.dart';
import 'diagnostics.dart';
import 'release_notes.dart';
import 'support_dashboard.dart';
import 'support_service.dart';

const relayPublicUrl = 'https://relay.luhlo.com/';
const relayPlayUrl =
    'https://play.google.com/store/apps/details?id=app.relay.relay';
const relaySupportEmail = 'luhlostudios@gmail.com';
const relayShareMessage =
    'Make room for work, care and yourself with Relay. Track focus and Baby Time, plan handoffs, and see where your time goes. $relayPublicUrl';

typedef RelayFeedbackSender = Future<void> Function({
  required String category,
  required String message,
  String? replyEmail,
});

Future<void> _sendSupportFeedback({
  required String category,
  required String message,
  String? replyEmail,
}) => RelaySupportService.instance.sendFeedback(
  category: category,
  message: message,
  replyEmail: replyEmail,
  platform: diagnosticPlatform,
);

bool get _nativeAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Intro and announcement preferences are device preferences, independent of
/// timer records. They are deliberately not included in household sync.
class RelayExperiencePreferences {
  RelayExperiencePreferences(this.preferences);
  static const introductionKey = 'relay.experience.introduction.v1';
  static const announcementKey = 'relay.experience.feature-release.v1';
  final SharedPreferences preferences;

  bool get introductionComplete =>
      preferences.getBool(introductionKey) ?? false;
  bool hasSeenRelease(String id) =>
      preferences.getString(announcementKey) == id;

  Future<void> completeIntroduction() async {
    if (!await preferences.setBool(introductionKey, true)) {
      throw StateError('Could not save introduction preference.');
    }
  }

  Future<void> markReleaseSeen(String id) async {
    if (!await preferences.setString(announcementKey, id)) {
      throw StateError('Could not save announcement preference.');
    }
  }
}

/// Place below MaterialApp. Existing users receive a small notification; an
/// active timer is never covered by an automatically opened release dialog.
class RelayExperienceHost extends StatefulWidget {
  const RelayExperienceHost({
    super.key,
    required this.child,
    this.hasExistingActivity,
    this.preferences,
  });
  final Widget child;
  final Future<bool> Function()? hasExistingActivity;
  final SharedPreferences? preferences;

  @override
  State<RelayExperienceHost> createState() => _RelayExperienceHostState();
}

class _RelayExperienceHostState extends State<RelayExperienceHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _introduce());
  }

  Future<void> _introduce() async {
    try {
      final preferences = RelayExperiencePreferences(
        widget.preferences ?? await SharedPreferences.getInstance(),
      );
      final existing = await widget.hasExistingActivity?.call() ?? false;
      if (!mounted) return;
      if (!preferences.introductionComplete && !existing) {
        await showRelayIntroduction(context);
        if (!mounted) return;
        await preferences.completeIntroduction();
        // New users have just learned the features. Avoid a second prompt.
        await preferences.markReleaseSeen(relayFeatureReleaseId);
        return;
      }
      if (!preferences.introductionComplete) {
        await preferences.completeIntroduction();
      }
      if (!mounted || preferences.hasSeenRelease(relayFeatureReleaseId)) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.showSnackBar(
        SnackBar(
          content: const Text('What’s new in Relay'),
          duration: const Duration(seconds: 12),
          showCloseIcon: true,
          action: SnackBarAction(
            label: 'View',
            onPressed: () {
              if (mounted) showRelayWhatsNew(context);
            },
          ),
        ),
      );
      await preferences.markReleaseSeen(relayFeatureReleaseId);
    } catch (_) {
      // An unavailable device preference must never block access to a timer.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<void> showRelayIntroduction(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const RelayIntroductionDialog(),
);

class RelayIntroductionDialog extends StatefulWidget {
  const RelayIntroductionDialog({super.key, this.androidSupported});
  final bool? androidSupported;

  @override
  State<RelayIntroductionDialog> createState() =>
      _RelayIntroductionDialogState();
}

class _RelayIntroductionDialogState extends State<RelayIntroductionDialog> {
  int page = 0;

  @override
  Widget build(BuildContext context) {
    final android = widget.androidSupported ?? _nativeAndroid;
    final pages = [
      (
        Icons.center_focus_strong,
        'Make room for your time',
        'Start Focus for work or personal time. Tap Interruption when something comes up, then Resume when you’re ready. Relay keeps focused and interrupted time separate.',
      ),
      (
        Icons.child_care,
        'Care for your people',
        'Start Baby Time and choose a child or All children. Add names in Settings, or leave them blank to use Baby 1, Baby 2 and so on. Plan handoffs together in Schedule.',
      ),
      (
        android ? Icons.widgets_outlined : Icons.insights_outlined,
        android ? 'Keep the controls close' : 'See your daily rhythm',
        android
            ? 'Add Relay’s home-screen widget for quick timer controls. Enable the lock-screen timer in Settings to interrupt, resume or end without opening the app. Insights shows your work, interruptions and childcare over time.'
            : 'Open Insights to compare work, interruptions and childcare across dates. Sign in to save household records across devices, or keep using Relay on this device. Android widgets and lock-screen controls are available in the native Android app.',
      ),
    ];
    final current = pages[page];
    return AlertDialog(
      constraints: const BoxConstraints(maxWidth: 488),
      scrollable: true,
      title: Text(current.$2),
      content: SizedBox(
        key: const ValueKey('relay-introduction-content'),
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              current.$1,
              size: 46,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 20),
            Text(current.$3, style: const TextStyle(height: 1.6)),
            const SizedBox(height: 20),
            Text(
              '${page + 1} of ${pages.length}',
              semanticsLabel:
                  'Introduction page ${page + 1} of ${pages.length}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Skip'),
        ),
        if (page > 0)
          TextButton(
            onPressed: () => setState(() => page--),
            child: const Text('Back'),
          ),
        FilledButton(
          onPressed: () => page == pages.length - 1
              ? Navigator.pop(context)
              : setState(() => page++),
          child: Text(page == pages.length - 1 ? 'Get started' : 'Next'),
        ),
      ],
    );
  }
}

Future<void> showRelayWhatsNew(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const RelayWhatsNewDialog(),
);

class RelayWhatsNewDialog extends StatelessWidget {
  const RelayWhatsNewDialog({super.key, this.androidSupported});
  final bool? androidSupported;

  @override
  Widget build(BuildContext context) => AlertDialog(
    constraints: const BoxConstraints(maxWidth: 488),
    scrollable: true,
    title: const Text('What’s new in Relay'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Version $relayFeatureReleaseVersion'),
          const SizedBox(height: 8),
          for (final note in relayReleaseNotes)
            if (!note.androidOnly || (androidSupported ?? _nativeAndroid))
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    Text(note.detail, style: const TextStyle(height: 1.5)),
                  ],
                ),
              ),
        ],
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Got it'),
      ),
    ],
  );
}

class RelayExperienceSettings extends StatefulWidget {
  const RelayExperienceSettings({
    super.key,
    this.sendFeedback,
    this.canViewReports,
    this.openUrl,
    this.share,
  });
  final RelayFeedbackSender? sendFeedback;
  final Future<bool> Function()? canViewReports;
  final Future<bool> Function(Uri)? openUrl;
  final Future<void> Function()? share;

  @override
  State<RelayExperienceSettings> createState() =>
      _RelayExperienceSettingsState();
}

class _RelayExperienceSettingsState extends State<RelayExperienceSettings> {
  bool canViewReports = false;
  bool changingDiagnostics = false;

  @override
  void initState() {
    super.initState();
    _loadAccess();
  }

  Future<void> _loadAccess() async {
    try {
      final allowed =
          await (widget.canViewReports ??
              RelaySupportService.instance.canViewReports)();
      if (mounted) setState(() => canViewReports = allowed);
    } catch (_) {
      // Standard settings remain available without administrator access.
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _changeTheme(ThemeMode mode) async {
    try {
      await RelayThemeController.instance.setMode(mode);
    } catch (_) {
      _message('Could not save your appearance choice. Please try again.');
    }
  }

  Future<void> _changeDiagnostics(bool enabled) async {
    setState(() => changingDiagnostics = true);
    try {
      await RelayDiagnostics.instance.setEnabled(enabled);
    } catch (_) {
      _message(
        'Could not save the technical-report setting. Please try again.',
      );
    } finally {
      if (mounted) setState(() => changingDiagnostics = false);
    }
  }

  Future<void> _rate() async {
    try {
      final opened =
          await (widget.openUrl ??
              (uri) => launchUrl(uri, mode: LaunchMode.externalApplication))(
            Uri.parse(relayPlayUrl),
          );
      if (!opened) throw StateError('Could not open Google Play.');
    } catch (_) {
      _message('Could not open Google Play. Please try again when connected.');
    }
  }

  Future<void> _share(BuildContext buttonContext) async {
    try {
      if (widget.share != null) {
        await widget.share!();
        return;
      }
      final box = buttonContext.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          text: relayShareMessage,
          title: 'Share Relay',
          subject: 'Relay: make room for work and care',
          sharePositionOrigin: box == null || !box.hasSize
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      // Some browsers cannot open a share sheet. Copying remains explicit.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Sharing is unavailable here. You can copy the link.',
          ),
          action: SnackBarAction(label: 'Copy link', onPressed: _copyLink),
        ),
      );
    }
  }

  Future<void> _copyLink() async {
    try {
      await Clipboard.setData(const ClipboardData(text: relayPublicUrl));
      _message('Relay link copied.');
    } catch (_) {
      _message('Could not copy the link. Open relay.luhlo.com to share Relay.');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      RelayThemeController.instance,
      RelayDiagnostics.instance,
    ]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Appearance & help')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const ListTile(
            title: Text('Make Relay feel like yours'),
            subtitle: Text(
              'App appearance, guidance and ways to get in touch.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: DropdownButtonFormField<ThemeMode>(
              initialValue: RelayThemeController.instance.mode,
              decoration: const InputDecoration(
                labelText: 'App appearance',
                prefixIcon: Icon(Icons.palette_outlined),
              ),
              items: const [
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: Text('Follow System'),
                ),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
              onChanged: (mode) {
                if (mode != null) _changeTheme(mode);
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Widget colors are customized separately in Widget appearance.',
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('Help & FAQ'),
            subtitle: const Text('Timers, family sharing, widgets and more'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => const RelayHelpPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.explore_outlined),
            title: const Text('Replay introduction'),
            onTap: () => showRelayIntroduction(context),
          ),
          ListTile(
            leading: const Icon(Icons.lightbulb_outline),
            title: const Text('What’s new'),
            subtitle: const Text('Version $relayFeatureReleaseVersion'),
            onTap: () => showRelayWhatsNew(context),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.rate_review_outlined),
            title: const Text('Rate Relay on Google Play'),
            subtitle: const Text(
              'Opens Google Play; access depends on the release and your tester access.',
            ),
            onTap: _rate,
          ),
          Builder(
            builder: (buttonContext) => ListTile(
              leading: const Icon(Icons.ios_share_outlined),
              title: const Text('Share Relay'),
              subtitle: const Text('Send the app’s link to someone'),
              onTap: () => _share(buttonContext),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Copy app link'),
            onTap: _copyLink,
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('Send feedback'),
            subtitle: const Text(
              'Report a problem, suggest a feature or ask a question',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    RelayFeedbackPage(sendFeedback: widget.sendFeedback),
              ),
            ),
          ),
          const Divider(),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.health_and_safety_outlined),
            title: const Text('Help improve reliability'),
            subtitle: const Text(
              'Send technical errors and slow-operation reports. Off until you enable it. No family names, emails, timer records or usage analytics are included. Turning this off clears unsent reports.',
            ),
            value: RelayDiagnostics.instance.enabled,
            onChanged: changingDiagnostics ? null : _changeDiagnostics,
          ),
          if (canViewReports)
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Support dashboard'),
              subtitle: const Text('Private feedback and technical reports'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(builder: (_) => const SupportDashboardPage()),
              ),
            ),
        ],
      ),
    ),
  );
}

const _relayFaqs = [
  (
    'What is counted as focused time?',
    'Start Focus when you want work or personal time. Interruption pauses actual focus and starts a separate interruption timer. Resume returns to focus. Total work is actual focus plus interrupted time.',
  ),
  (
    'How do I track more than one child?',
    'Open Settings to set the number of children and their names. Blank names become Baby 1, Baby 2 and so on. Start Baby Time, then choose a child or All children. Shared care appears in each child’s totals, while total childcare counts the elapsed time once.',
  ),
  (
    'Do I need an account?',
    'You can use Relay on this device without an account. Sign in to save records across devices and join a household. Local records stay on the device; signing in does not automatically merge them with existing cloud history.',
  ),
  (
    'How do I invite a parent or caregiver?',
    'Open household Settings and add a family member or caregiver. Give them the invitation code so they can join the same household with their own Relay login. Each person tracks their own time.',
  ),
  (
    'How do I use the Android widget?',
    'Install the native Android app and open it once. Long-press your home screen, choose Widgets, and add Relay’s 4 × 1 or 2 × 1 widget. Resize it by long-pressing and dragging its handles. Work Time, Baby Time, Interruption, Resume and End work from the widget. Once your account and household have loaded, tracking works offline and syncs when a connection returns.',
  ),
  (
    'How do lock-screen controls work?',
    'In the native Android app, enable Lock-screen timer in Settings and allow Relay notifications. Start a timer to see its ongoing notification. Android controls its placement and visibility, and may require unlocking for some actions. These controls are not part of the browser-installed PWA or the iPhone web app.',
  ),
  (
    'Why did my timer stop?',
    'Relay checks in every three hours. Respond within 15 minutes to keep tracking. An unanswered check-in stops the timer; a 12-hour no-response limit and an absolute 20-hour session limit also apply. If Android delays a notification or a cloud connection is unavailable, Relay applies the recorded deadline when it can next run and save.',
  ),
  (
    'Does an interruption move my schedule?',
    'An interruption records lost focus time. Use Push 15 Mins to move the current schedule block forward by 15 minutes when you want to adjust the handoff.',
  ),
  (
    'Does Google Calendar sync both ways?',
    'Calendar export opens a draft for you to save to Google Calendar. Changes made in Google Calendar do not automatically update Relay.',
  ),
  (
    'How do date ranges and Insights work?',
    'Open Insights and choose Today, Yesterday, All time or Choose dates. Use the arrows to move between dates. Charts separate total work, actual focus, interruptions and childcare, including active sessions.',
  ),
  (
    'Does Relay calculate the personal-time bank?',
    'Settings includes an optional daily personal-time agreement with editable hours. It explains how your household can share extra time; automatic time-bank credits and balances are not calculated.',
  ),
  (
    'Can I track time without internet?',
    'Yes. Timers and schedules save on this device first, including when signed in after your account and household have loaded online once. Reconnect to sync; on the web, keep Relay open or reopen it. Tap the sync status to review competing changes and saved copies. Signing out keeps pending records private for the same account. Clearing app or browser storage removes unsynced records and saved copies.',
  ),
  (
    'How can I delete my account?',
    'Open Settings and choose the account deletion option. You can also visit relay.luhlo.com/delete-account/ for deletion instructions and the web flow.',
  ),
];

class RelayHelpPage extends StatelessWidget {
  const RelayHelpPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Help & FAQ')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        for (final faq in _relayFaqs)
          ExpansionTile(
            title: Text(faq.$1),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(faq.$2, style: const TextStyle(height: 1.6))],
          ),
        const SizedBox(height: 24),
        const ListTile(
          leading: Icon(Icons.mail_outline),
          title: Text('Need more help?'),
          subtitle: SelectableText(relaySupportEmail),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => const RelayFeedbackPage()),
          ),
          icon: const Icon(Icons.chat_bubble_outline),
          label: const Text('Contact Relay support'),
        ),
      ],
    ),
  );
}

class RelayFeedbackPage extends StatefulWidget {
  const RelayFeedbackPage({super.key, this.sendFeedback});
  final RelayFeedbackSender? sendFeedback;

  @override
  State<RelayFeedbackPage> createState() => _RelayFeedbackPageState();
}

class _RelayFeedbackPageState extends State<RelayFeedbackPage> {
  final formKey = GlobalKey<FormState>();
  final messageController = TextEditingController();
  final emailController = TextEditingController();
  String category = 'problem';
  String? error;
  bool sending = false, sent = false;

  @override
  void dispose() {
    messageController.dispose();
    emailController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (sending || !formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await (widget.sendFeedback ?? _sendSupportFeedback)(
        category: category,
        message: messageController.text.trim(),
        replyEmail: emailController.text.trim().isEmpty
            ? null
            : emailController.text.trim(),
      );
      if (mounted) setState(() => sent = true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not confirm that your feedback was sent. Your message is still here. Check your connection and try again, or contact $relaySupportEmail.',
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Send feedback')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: sent
            ? ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 48,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Thanks for helping improve Relay.',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  const Text('Your feedback was sent to Relay support.'),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ],
              )
            : Form(
                key: formKey,
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const Text(
                      'Tell us what would make Relay work better for you.',
                    ),
                    const SizedBox(height: 20),
                    DropdownButtonFormField<String>(
                      initialValue: category,
                      decoration: const InputDecoration(
                        labelText: 'What would you like to send?',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'problem',
                          child: Text('Report a problem'),
                        ),
                        DropdownMenuItem(
                          value: 'idea',
                          child: Text('Suggest a feature'),
                        ),
                        DropdownMenuItem(
                          value: 'question',
                          child: Text('Ask a question'),
                        ),
                      ],
                      onChanged: sending
                          ? null
                          : (value) => setState(() => category = value!),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: messageController,
                      decoration: const InputDecoration(
                        labelText: 'Your message',
                        alignLabelWithHint: true,
                      ),
                      minLines: 5,
                      maxLines: 10,
                      maxLength: 2000,
                      enabled: !sending,
                      validator: (value) => (value?.trim().length ?? 0) < 10
                          ? 'Please add at least 10 characters.'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: emailController,
                      decoration: const InputDecoration(
                        labelText: 'Reply email (optional)',
                        helperText: 'Add an email if you would like a reply.',
                      ),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      maxLength: 254,
                      enabled: !sending,
                      validator: (value) {
                        final email = value?.trim() ?? '';
                        return email.isNotEmpty &&
                                !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                    .hasMatch(email)
                            ? 'Enter a valid email address, or leave this blank.'
                            : null;
                      },
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Your message and optional email are sent to Relay support. Please leave out passwords and private family details.',
                    ),
                    const SizedBox(height: 20),
                    if (error != null) ...[
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    FilledButton.icon(
                      onPressed: sending ? null : _send,
                      icon: Icon(
                        sending ? Icons.hourglass_top : Icons.send_outlined,
                      ),
                      label: Text(sending ? 'Sending…' : 'Send feedback'),
                    ),
                  ],
                ),
              ),
      ),
    ),
  );
}

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'alerts.dart';
import 'model.dart';
import 'storage.dart';
import 'time_pies.dart';
import 'trends.dart';
import 'account.dart';
import 'cloud.dart';

import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

const ink = Color(0xFF24232C),
    muted = Color(0xFF73727C),
    paper = Color(0xFFF7F7F2);
const violet = Color(0xFF6450CA),
    paleViolet = Color(0xFFEEEBFC),
    green = Color(0xFFDDEAAD),
    amber = Color(0xFFF3C879);
String clockText(int seconds) =>
    '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${((seconds ~/ 60) % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
String durationText(int seconds) => seconds < 60
    ? '${seconds}s'
    : seconds < 3600
    ? '${seconds ~/ 60}m'
    : '${seconds ~/ 3600}h ${seconds ~/ 60 % 60}m';
String timeText(DateTime d) => DateFormat.jm().format(d);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: relaySupabaseUrl,
    publishableKey: relayPublishableKey,
  );
  runApp(const RelayApp());
}

class RelayApp extends StatelessWidget {
  const RelayApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Relay • A little more balance',
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Manrope',
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(seedColor: violet, surface: paper),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: ink, fontSize: 14),
        bodyLarge: TextStyle(color: ink),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    home: const AccountGate(),
  );
}

class RelayHome extends StatefulWidget {
  const RelayHome({
    super.key,
    this.store,
    this.alerts,
    this.readOnly = false,
    this.onMenu,
  });
  final bool readOnly;
  final RelayStore? store;
  final ShiftAlerts? alerts;
  final VoidCallback? onMenu;
  @override
  State<RelayHome> createState() => _RelayHomeState();
}

class _RelayHomeState extends State<RelayHome> with WidgetsBindingObserver {
  late final store = widget.store ?? RelayStore();
  late final alerts = widget.alerts ?? ShiftAlerts();
  RelayState data = RelayState();
  bool loading = true, busy = false, loadFailed = false;
  String? error;
  int page = 0;
  DateTime now = DateTime.now(), selectedDay = dayStart(DateTime.now());
  DateTimeRange? insightsRange;
  bool insightsAllTime = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => now = DateTime.now());
    });
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      loadFailed = false;
      error = null;
    });
    try {
      data = await store.load();
    } catch (_) {
      loadFailed = true;
      error = 'Could not load your saved data. Your existing data has not been changed.';
    }
    if (!loadFailed && !widget.readOnly) {
      try {
        await alerts.initialize();
        await alerts.sync(data);
      } catch (_) {
        error = 'Your data is saved. Enable shift alerts again to restore reminders.';
      }
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => now = DateTime.now());
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void toast(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> change(void Function() mutate, {String? message}) async {
    if (busy || loadFailed || widget.readOnly) return;
    setState(() => busy = true);
    final backup = data.toJson();
    try {
      mutate();
      await store.save(data);
    } catch (e) {
      data = RelayState.fromJson(backup);
      if (mounted) setState(() => busy = false);
      toast(
        e is CloudSaveException
            ? e.message
            : e is ArgumentError
            ? e.message.toString()
            : 'Could not save this change. Please try again.',
      );
      return;
    }
    try {
      await alerts.sync(data);
    } catch (_) {
      toast(
        'Saved. Reminders need attention: check notification and exact alarm permissions.',
      );
    }
    HapticFeedback.lightImpact();
    if (mounted) {
      setState(() {
        busy = false;
        now = DateTime.now();
      });
    }
    if (message != null) toast(message);
  }

  Future<void> enableAlerts() async {
    if (!alerts.supported) {
      toast(
        'Shift alerts work in the Android app. Browser preview supports tracking and planning.',
      );
      return;
    }
    try {
      if (data.alerts) {
        await change(
          () => data.alerts = false,
          message: 'Shift alerts turned off.',
        );
        return;
      }
      if (await alerts.enable()) {
        await change(
          () => data.alerts = true,
          message: 'Alerts set for 10 minutes before and at each handoff.',
        );
      } else {
        toast('Allow notifications and exact alarms to enable shift alerts.');
      }
    } catch (_) {
      toast('Could not enable alerts. Check Android notification settings.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 950;
    return Scaffold(
      body: SafeArea(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : loadFailed
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error!),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: load,
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              )
            : Row(
                children: [
                  if (wide && !widget.readOnly) sidebar(),
                  Expanded(
                    child: Column(
                      children: [
                        if (!widget.readOnly) topbar(wide),
                        if (store is CloudStore)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Flexible(
                                child: Text(
                                  'Cloud records · connection required',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: busy ? null : load,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Refresh'),
                              ),
                            ],
                          ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: EdgeInsets.all(wide ? 36 : 20),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 1180,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (error != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 20,
                                        ),
                                        child: Text(
                                          error!,
                                          style: const TextStyle(
                                            color: Colors.red,
                                          ),
                                        ),
                                      ),
                                    if (widget.readOnly)
                                      metrics()
                                    else if (page == 0)
                                      dashboard(wide)
                                    else if (page == 1)
                                      schedule()
                                    else
                                      metrics(),
                                    const SizedBox(height: 24),
                                    Text(
                                      'MADE FOR REAL LIFE, TOGETHER.',
                                      style: TextStyle(
                                        fontSize: 10,
                                        letterSpacing: 2,
                                        color: muted.withValues(alpha: .75),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      bottomNavigationBar: wide || widget.readOnly
          ? null
          : NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (i) => setState(() => page = i),
              backgroundColor: Colors.white,
              indicatorColor: paleViolet,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.space_dashboard_outlined),
                  selectedIcon: Icon(Icons.space_dashboard_rounded),
                  label: 'Today',
                ),
                NavigationDestination(
                  icon: Icon(Icons.calendar_today_outlined),
                  label: 'Schedule',
                ),
                NavigationDestination(
                  icon: Icon(Icons.bar_chart_rounded),
                  label: 'Insights',
                ),
              ],
            ),
    );
  }

  Widget logo() => Row(
    children: [
      Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: violet,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.swap_calls_rounded,
          color: Colors.white,
          size: 27,
        ),
      ),
      const SizedBox(width: 10),
      const Text(
        'relay',
        style: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w800,
          letterSpacing: -1.5,
        ),
      ),
    ],
  );
  Widget sidebar() => Container(
    width: 214,
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: Color(0xFFE8E8E2))),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        logo(),
        const SizedBox(height: 9),
        const Text(
          'A little more balance.',
          style: TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 52),
        for (final entry in [
          (Icons.space_dashboard_outlined, 'Today'),
          (Icons.calendar_today_outlined, 'Schedule'),
          (Icons.bar_chart_rounded, 'Insights'),
        ].indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: page == entry.$1 ? paleViolet : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => page = entry.$1),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 17,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        entry.$2.$1,
                        size: 21,
                        color: page == entry.$1 ? violet : muted,
                      ),
                      const SizedBox(width: 13),
                      Text(
                        entry.$2.$2,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: page == entry.$1 ? violet : muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: paper,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.favorite_outline, color: violet, size: 22),
              SizedBox(height: 12),
              Text(
                'You’re a team.',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 6),
              Text(
                'One shift at a time.\nYou’ve got this.',
                style: TextStyle(color: muted, fontSize: 12, height: 1.7),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            const Icon(Icons.lock_outline, size: 14, color: muted),
            const SizedBox(width: 7),
            Text(
              kIsWeb ? 'Saved in this browser' : 'Saved on this device',
              style: const TextStyle(color: muted, fontSize: 10),
            ),
          ],
        ),
      ],
    ),
  );
  Widget topbar(bool wide) => Container(
    padding: EdgeInsets.symmetric(horizontal: wide ? 36 : 20, vertical: 18),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xFFE8E8E2))),
    ),
    child: Row(
      children: [
        if (!wide)
          logo()
        else
          Text(
            [
              'YOUR DAILY RHYTHM',
              'ROOM FOR EVERYTHING',
              'PROGRESS, NOT PERFECTION',
            ][page],
            style: const TextStyle(
              color: muted,
              letterSpacing: 1.6,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        const Spacer(),
        if (wide)
          Text(
            DateFormat('EEEE, MMMM d').format(now),
            style: const TextStyle(fontSize: 12, color: muted),
          ),
        const SizedBox(width: 18),
        IconButton(
          onPressed: busy ? null : enableAlerts,
          tooltip: data.alerts ? 'Disable shift alerts' : 'Enable shift alerts',
          style: IconButton.styleFrom(backgroundColor: Colors.white),
          icon: Icon(
            data.alerts
                ? Icons.notifications_active_outlined
                : Icons.notifications_none_rounded,
            color: violet,
          ),
        ),
        if (widget.onMenu != null) ...[
          const SizedBox(width: 8),
          IconButton(
            onPressed: widget.onMenu,
            tooltip: 'Open account menu',
            style: IconButton.styleFrom(backgroundColor: Colors.white),
            icon: const Icon(Icons.menu_rounded, color: ink),
          ),
        ],
      ],
    ),
  );
  Widget heading(
    String eyebrow,
    String title,
    String subtitle, {
    Widget? trailing,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 26),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: const TextStyle(
            color: violet,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 32,
                  height: 1.2,
                  letterSpacing: -1.2,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 10),
        Text(
          subtitle,
          style: const TextStyle(color: muted, fontSize: 14, height: 1.6),
        ),
      ],
    ),
  );
  Widget dashboard(bool wide) {
    final active = data.active;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (active == null || wide)
          heading(
            DateFormat('EEEE, MMMM d').format(now).toUpperCase(),
            active == null
                ? 'Find your rhythm.'
                : active.kind == ShiftKind.focus
                ? 'Space to do your thing.'
                : 'Little moments. Full attention.',
            'Work, care, and everything in between. Make room for both.',
          ),
        LayoutBuilder(
          builder: (context, box) {
            final split = box.maxWidth > 760;
            final left = Column(
              children: [
                statusCard(),
                const SizedBox(height: 18),
                if (active?.kind == ShiftKind.focus) ...[
                  focusActions(),
                  const SizedBox(height: 18),
                ],
                modeButtons(),
                const SizedBox(height: 24),
                todaySummary(),
              ],
            );
            final right = Column(
              children: [
                timelineCard(),
                const SizedBox(height: 18),
                reminderCard(),
              ],
            );
            return split
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 7, child: left),
                      const SizedBox(width: 24),
                      Expanded(flex: 4, child: right),
                    ],
                  )
                : Column(children: [left, const SizedBox(height: 24), right]);
          },
        ),
      ],
    );
  }

  Widget statusCard() {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final s = data.active, block = data.activeShift;
    final interrupted = s?.interruption != null,
        focus = s?.kind == ShiftKind.focus;
    final color = interrupted
        ? amber
        : s == null || focus
        ? violet
        : green;
    final fg = interrupted || (s != null && !focus) ? ink : Colors.white;
    final seconds = interrupted
        ? now.difference(s!.interruption!.start).inSeconds
        : data.sessionSeconds(now);
    final due = block != null && !block.end.isAfter(now);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 20 : 28),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                interrupted
                    ? 'LIFE HAPPENS'
                    : s == null
                    ? 'A FRESH START'
                    : 'CURRENT SHIFT',
                style: TextStyle(
                  color: fg.withValues(alpha: .85),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.8,
                ),
              ),
              const Spacer(),
              Icon(
                interrupted
                    ? Icons.pause_circle_outline
                    : focus
                    ? Icons.do_not_disturb_on_outlined
                    : s == null
                    ? Icons.wb_sunny_outlined
                    : Icons.child_care,
                color: fg,
                size: 24,
              ),
            ],
          ),
          SizedBox(height: compact ? 12 : 22),
          Text(
            interrupted
                ? 'Interrupted'
                : s == null
                ? 'Ready when you are.'
                : focus
                ? 'Focus mode'
                : s.baby == null
                ? 'Baby Time'
                : data.babyName(s.baby!),
            style: TextStyle(
              color: fg,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
            ),
          ),
          SizedBox(height: compact ? 5 : 8),
          Text(
            interrupted
                ? 'Take care of what matters. We’ll keep track.'
                : s == null
                ? 'Choose your shift. We’ll take care of the clock.'
                : focus
                ? 'Your time to focus. Please do not disturb.'
                : s.baby == null
                ? 'Choose who you are caring for using Baby Time below.'
                : 'Taking care of ${data.babyName(s.baby!)}. Be here, fully.',
            style: TextStyle(
              color: fg.withValues(alpha: .85),
              height: 1.5,
              fontSize: compact ? 12 : 13,
            ),
          ),
          SizedBox(height: compact ? 16 : 26),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              clockText(max(0, seconds)),
              style: TextStyle(
                color: fg,
                fontSize: compact ? 52 : 62,
                fontWeight: FontWeight.w600,
                letterSpacing: -2,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Text(
            interrupted
                ? 'interruption time'
                : s == null
                ? 'a little time for what matters'
                : focus
                ? 'actual focus'
                : 'baby time',
            style: TextStyle(color: fg.withValues(alpha: .8), fontSize: 12),
          ),
          if (focus && s != null) ...[
            const SizedBox(height: 12),
            Text(
              'Total work ${durationText(max(0, now.difference(s.start).inSeconds))}  ·  Actual focus ${durationText(data.sessionSeconds(now))}  ·  Interrupted ${durationText(max(0, now.difference(s.start).inSeconds - data.sessionSeconds(now)))}',
              style: TextStyle(
                color: fg,
                fontSize: compact ? 11 : 12,
                height: 1.5,
              ),
            ),
          ],
          SizedBox(height: compact ? 10 : 26),
          Divider(color: fg.withValues(alpha: .2)),
          SizedBox(height: compact ? 4 : 12),
          Row(
            children: [
              Icon(Icons.schedule, color: fg, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  block == null
                      ? 'No rush. Start with one shift.'
                      : due
                      ? 'Handoff due · choose your next shift'
                      : 'Next handoff at ${timeText(block.end)}',
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (s != null)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => change(
                          () => data.finish(DateTime.now()),
                          message: 'Shift complete. Your time is saved.',
                        ),
                  style: TextButton.styleFrom(
                    foregroundColor: fg,
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text('End shift'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget modeButtons() => Row(
    children: [
      Expanded(child: modeButton(ShiftKind.focus)),
      const SizedBox(width: 14),
      Expanded(child: modeButton(ShiftKind.point)),
    ],
  );
  Widget modeButton(ShiftKind kind) {
    final current = data.active?.kind == kind, focus = kind == ShiftKind.focus;
    return Material(
      color: focus ? paleViolet : green,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: busy || (current && focus)
            ? null
            : focus
            ? () => change(() => data.start(kind, DateTime.now()))
            : chooseBaby,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          constraints: const BoxConstraints(minHeight: 112),
          padding: const EdgeInsets.all(19),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    focus
                        ? Icons.center_focus_strong_rounded
                        : Icons.child_care_rounded,
                    color: focus ? violet : ink,
                    size: 25,
                  ),
                  const Spacer(),
                  Icon(
                    current ? Icons.check_circle_outline : Icons.arrow_outward,
                    color: focus ? violet : ink,
                    size: 19,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                current
                    ? (focus ? 'Focus active' : 'Baby Time')
                    : (focus ? 'Start Focus' : 'Baby Time'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: focus ? violet : ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> chooseBaby() async {
    final baby = await showModalBottomSheet<Baby>(
      context: context,
      showDragHandle: true,
      backgroundColor: paper,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Who are you taking care of?',
                  style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                Text(
                  data.childNames.length == 1
                      ? 'Baby Time starts when you choose ${data.childNames.first}.'
                      : 'Choose one child or All children.',
                  style: const TextStyle(color: muted),
                ),
                const SizedBox(height: 24),
                for (final baby in data.availableBabies)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, baby),
                      style: FilledButton.styleFrom(
                        backgroundColor: green,
                        foregroundColor: ink,
                        minimumSize: const Size(0, 84),
                      ),
                      icon: const Icon(Icons.child_care, size: 28),
                      label: Text(
                        data.babyName(baby),
                        style: const TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (baby != null && mounted) {
      await change(
        () => data.start(ShiftKind.point, DateTime.now(), baby: baby),
      );
    }
  }

  Widget focusActions() {
    final interrupted = data.active!.interruption != null;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: busy
                ? null
                : () => change(() => data.toggleInterruption(DateTime.now())),
            icon: Icon(
              interrupted ? Icons.play_arrow_rounded : Icons.pause_rounded,
              size: 29,
            ),
            label: Text(
              interrupted ? 'Resume Focus' : 'Interruption',
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: interrupted ? violet : amber,
              foregroundColor: interrupted ? Colors.white : ink,
              minimumSize: const Size(0, 88),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => change(
                    data.push,
                    message: 'Added 15 minutes. Overlapping blocks and reminders moved with you.',
                  ),
            icon: const Icon(Icons.more_time),
            label: const Text(
              'Push 15 Mins',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 64),
              foregroundColor: ink,
              side: const BorderSide(color: Color(0xFFDAD8E2)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget card({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFFE8E8E2)),
    ),
    child: child,
  );
  Widget todaySummary() => card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Every bit counts.',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: stat(
                durationText(data.totalWorkSeconds(now, now)),
                'Total work',
                violet,
              ),
            ),
            Expanded(
              child: stat(
                durationText(data.actualSeconds(now, now)),
                'Actual focus',
                violet,
              ),
            ),
            Expanded(
              child: stat(
                durationText(data.lostSeconds(now, now)),
                'Interrupted',
                const Color(0xFF9D6616),
              ),
            ),
          ],
        ),
        const SizedBox(height: 15),
        TextButton(
          onPressed: () => setState(() => page = 2),
          child: const Text('See your insights  →'),
        ),
      ],
    ),
  );
  Widget stat(String value, String label, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w800,
          color: color,
          letterSpacing: -.7,
        ),
      ),
      const SizedBox(height: 5),
      Text(label, style: const TextStyle(color: muted, fontSize: 11)),
    ],
  );
  Widget timelineCard() {
    final shifts = data.onDay(now);
    return card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'The plan for today',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                onPressed: () => editShift(day: now),
                tooltip: 'Add a shift',
                icon: const Icon(Icons.add, color: violet),
              ),
            ],
          ),
          const Text(
            'A rhythm, not a rigid routine.',
            style: TextStyle(fontSize: 12, color: muted),
          ),
          const SizedBox(height: 24),
          if (shifts.isEmpty) ...[
            Container(
              height: 82,
              width: double.infinity,
              decoration: BoxDecoration(
                color: paper,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.wb_twilight_rounded,
                color: violet,
                size: 36,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Your day is a blank canvas.',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Map out a shift, or start one now. There’s no perfect plan.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.7),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => editShift(day: now),
              child: const Text('Plan your first shift  →'),
            ),
          ] else ...[
            for (final s in shifts.take(5)) shiftTile(s),
            if (shifts.length > 5)
              TextButton(
                onPressed: () => setState(() => page = 1),
                child: Text('View all ${shifts.length} shifts'),
              ),
          ],
        ],
      ),
    );
  }

  Widget shiftTile(Shift s) {
    final isActive = data.active?.shiftId == s.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: isActive ? paleViolet : paper,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () => editShift(shift: s),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 48,
                  decoration: BoxDecoration(
                    color: s.kind == ShiftKind.focus
                        ? violet
                        : const Color(0xFF7C993D),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${timeText(s.start)} – ${timeText(s.end)}',
                        style: const TextStyle(color: muted, fontSize: 10),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        s.kind == ShiftKind.focus ? 'Focus time' : 'Baby Time',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isActive)
                  const Icon(
                    Icons.radio_button_checked,
                    color: violet,
                    size: 17,
                  )
                else
                  Icon(
                    s.kind == ShiftKind.focus
                        ? Icons.center_focus_strong
                        : Icons.child_care,
                    size: 20,
                    color: muted,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget reminderCard() => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: const Color(0xFFEEEFE6),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.notifications_none_rounded, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                data.alerts
                    ? 'We’ll give you a heads-up.'
                    : 'One less thing to remember.',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'A nudge 10 minutes before your shift ends, and another when it’s time to hand off.',
          style: TextStyle(fontSize: 12, color: muted, height: 1.7),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: busy ? null : enableAlerts,
          child: Text(
            data.alerts
                ? 'Shift alerts enabled  ✓'
                : kIsWeb
                ? 'About Android alerts  →'
                : 'Enable shift alerts  →',
          ),
        ),
      ],
    ),
  );
  Widget dayPicker() => Row(
    children: [
      IconButton(
        tooltip: 'Previous day',
        onPressed: () => setState(
          () => selectedDay = DateTime(
            selectedDay.year,
            selectedDay.month,
            selectedDay.day - 1,
          ),
        ),
        icon: const Icon(Icons.chevron_left),
      ),
      Expanded(
        child: TextButton(
          onPressed: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: selectedDay,
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (d != null) setState(() => selectedDay = d);
          },
          child: Text(
            DateFormat('EEE, MMM d, yyyy').format(selectedDay),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ),
      IconButton(
        tooltip: 'Next day',
        onPressed: () => setState(
          () => selectedDay = DateTime(
            selectedDay.year,
            selectedDay.month,
            selectedDay.day + 1,
          ),
        ),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
  Widget schedule() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      heading(
        'YOUR SHARED RHYTHM',
        'Give your day some shape.',
        'Plan focus and childcare blocks. Leave a little room for life.',
      ),
      dayPicker(),
      const SizedBox(height: 20),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: busy ? null : () => editShift(day: selectedDay),
          icon: const Icon(Icons.add),
          label: const Text('Add a shift'),
        ),
      ),
      const SizedBox(height: 22),
      if (data.onDay(selectedDay).isEmpty)
        card(
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Column(
              children: [
                Icon(Icons.calendar_month_outlined, size: 45, color: violet),
                SizedBox(height: 18),
                Text(
                  'A little space to plan.',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 8),
                Text(
                  'Add your first focus or childcare block.',
                  style: TextStyle(color: muted),
                ),
              ],
            ),
          ),
        )
      else
        ...data.onDay(selectedDay).map(shiftTile),
      const SizedBox(height: 16),
      const Text(
        'Tap a block to edit it or add it to Google Calendar. Calendar export opens a draft for you to save; it is not two-way sync.',
        style: TextStyle(color: muted, fontSize: 12, height: 1.7),
      ),
    ],
  );
  Widget metrics() {
    final earliest = [
      ...data.sessions.map((s) => s.start),
      ...data.shifts.map((s) => s.start),
      now,
    ].reduce((a, b) => a.isBefore(b) ? a : b);
    final from = insightsAllTime
        ? dayStart(earliest)
        : insightsRange?.start ?? dayStart(now);
    final through = insightsAllTime
        ? dayStart(now)
        : insightsRange?.end ?? dayStart(now);
    final until = nextDay(through);
    final interruptions = data.sessions
        .expand((s) => s.interruptions)
        .where((i) => i.start.isBefore(until) && (i.end ?? now).isAfter(from))
        .toList();
    final planned = data.scheduledSeconds(from, endDay: through),
        actual = data.actualSeconds(from, now, endDay: through),
        lost = data.lostSeconds(from, now, endDay: through),
        total = data.totalWorkSeconds(from, now, endDay: through),
        babyTotal = data.babySeconds(from, now, endDay: through),
        unassigned = data.babySeconds(
          from,
          now,
          unassignedOnly: true,
          endDay: through,
        );
    final largest = max(60, max(planned, total));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading(
          'SMALL WINS ADD UP',
          'See where your time goes.',
          'An honest picture of your time. No scores, no pressure.',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Today'),
              selected: !insightsAllTime && insightsRange == null,
              onSelected: (_) => setState(() {
                insightsAllTime = false;
                insightsRange = null;
              }),
            ),
            ChoiceChip(
              label: const Text('All time'),
              selected: insightsAllTime,
              onSelected: (_) => setState(() => insightsAllTime = true),
            ),
            ActionChip(
              label: const Text('Choose dates'),
              avatar: const Icon(Icons.date_range, size: 18),
              onPressed: () async {
                final range = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(min(1900, earliest.year)),
                  lastDate: dayStart(now),
                  initialDateRange: DateTimeRange(start: from, end: through),
                  helpText: 'Choose Insights dates',
                );
                if (range != null && mounted) {
                  setState(() {
                    insightsRange = range;
                    insightsAllTime = false;
                  });
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${DateFormat.yMMMd().format(from)} – ${DateFormat.yMMMd().format(through)}',
          style: const TextStyle(color: muted),
        ),
        const SizedBox(height: 22),
        TimePies(data: data, day: from, endDay: through, now: now),
        const SizedBox(height: 20),
        card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Focus, planned & lived',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Total work = actual focus + interrupted time.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 32),
              chartBar(
                'Scheduled focus time',
                planned,
                largest,
                const Color(0xFFC8BFF3),
              ),
              const SizedBox(height: 25),
              chartBar('Total work time', total, largest, ink),
              const SizedBox(height: 25),
              chartBar('Actual focus', actual, largest, violet),
              const SizedBox(height: 25),
              chartBar('Interrupted time', lost, largest, amber),
              const SizedBox(height: 24),
              const Text(
                'Actual time includes active sessions and updates live.',
                style: TextStyle(color: muted, fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        card(
          child: Row(
            children: [
              Expanded(
                child: stat(durationText(actual), 'Actual focus', violet),
              ),
              Expanded(
                child: stat(
                  durationText(lost),
                  'Interrupted',
                  const Color(0xFF9D6616),
                ),
              ),
              Expanded(child: stat(durationText(total), 'Total work', ink)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Baby Time',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                'Total childcare: ${durationText(babyTotal)}',
                style: const TextStyle(color: muted),
              ),
              const SizedBox(height: 24),
              for (final baby in data.availableBabies) ...[
                chartBar(
                  data.babyName(baby),
                  data.babySeconds(from, now, baby: baby, endDay: through),
                  max(60, babyTotal),
                  const Color(0xFF789638),
                ),
                const SizedBox(height: 20),
              ],
              const Text(
                '“All children” counts once in total childcare and also appears in each child’s individual time.',
                style: TextStyle(color: muted, fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 12),
              if (unassigned > 0)
                Text(
                  'Earlier childcare (child not recorded): ${durationText(unassigned)}',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Interruption log',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        if (interruptions.isEmpty)
          const Text(
            'No interruptions logged for this period.',
            style: TextStyle(color: muted),
          )
        else
          ...interruptions.map(
            (i) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFFAEBCD),
                child: Icon(Icons.pause, color: ink),
              ),
              title: Text(
                '${DateFormat.MMMd().format(i.start)} · ${timeText(i.start)} – ${i.end == null ? 'in progress' : timeText(i.end!)}',
              ),
              trailing: Text(
                durationText(
                  overlapSeconds(i.start, i.end ?? now, from, until),
                ),
              ),
            ),
          ),
        const SizedBox(height: 28),
        TrendsCard(data: data, starting: from, ending: through, now: now),
      ],
    );
  }

  Widget chartBar(String label, int value, int largest, Color color) =>
      Semantics(
        label: '$label: ${durationText(value)}',
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  durationText(value),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: LinearProgressIndicator(
                value: value / largest,
                minHeight: 38,
                backgroundColor: paper,
                color: color,
              ),
            ),
          ],
        ),
      );
  Future<void> editShift({Shift? shift, DateTime? day}) async {
    final base = dayStart(day ?? shift?.start ?? now);
    var start =
        shift?.start ??
        DateTime(
          base.year,
          base.month,
          base.day,
          base == dayStart(now) ? min(now.hour + 1, 23) : 9,
        );
    var end = shift?.end ?? start.add(const Duration(hours: 1));
    var kind = shift?.kind ?? ShiftKind.focus;
    final active = shift != null && data.active?.shiftId == shift.id;
    String? validation;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: paper,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, update) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                8,
                24,
                24 + MediaQuery.viewInsetsOf(sheetContext).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shift == null ? 'Make a little room.' : 'Your shift',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    DateFormat('EEEE, MMMM d').format(base),
                    style: const TextStyle(color: muted),
                  ),
                  const SizedBox(height: 24),
                  SegmentedButton<ShiftKind>(
                    segments: const [
                      ButtonSegment(
                        value: ShiftKind.focus,
                        icon: Icon(Icons.center_focus_strong),
                        label: Text('Focus'),
                      ),
                      ButtonSegment(
                        value: ShiftKind.point,
                        icon: Icon(Icons.child_care),
                        label: Text('Baby Time'),
                      ),
                    ],
                    selected: {kind},
                    onSelectionChanged: active
                        ? null
                        : (v) => update(() => kind = v.first),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: active
                              ? null
                              : () async {
                                  final t = await showTimePicker(
                                    context: sheetContext,
                                    initialTime: TimeOfDay.fromDateTime(start),
                                  );
                                  if (t != null) {
                                    update(
                                      () => start = DateTime(
                                        base.year,
                                        base.month,
                                        base.day,
                                        t.hour,
                                        t.minute,
                                      ),
                                    );
                                  }
                                },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              'Start\n${timeText(start)}',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: active
                              ? null
                              : () async {
                                  final t = await showTimePicker(
                                    context: sheetContext,
                                    initialTime: TimeOfDay.fromDateTime(end),
                                  );
                                  if (t != null) {
                                    update(() {
                                      end = DateTime(
                                        base.year,
                                        base.month,
                                        base.day,
                                        t.hour,
                                        t.minute,
                                      );
                                      if (!end.isAfter(start)) {
                                        end = DateTime(
                                          base.year,
                                          base.month,
                                          base.day + 1,
                                          t.hour,
                                          t.minute,
                                        );
                                      }
                                    });
                                  }
                                },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              'End\n${timeText(end)}${dayStart(end) != base ? ' (+1 day)' : ''}',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (active)
                    const Padding(
                      padding: EdgeInsets.only(top: 15),
                      child: Text(
                        'This shift is active. Use Push 15 Mins to extend it, or end it before editing.',
                        style: TextStyle(color: muted),
                      ),
                    ),
                  if (validation != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        validation!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  const SizedBox(height: 24),
                  if (!active)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () async {
                          final candidate = Shift(
                            id: shift?.id ?? data.nextId,
                            kind: kind,
                            start: start,
                            end: end,
                          );
                          try {
                            final check = RelayState.fromJson(data.toJson());
                            check.putShift(candidate);
                          } catch (e) {
                            update(
                              () => validation = (e as ArgumentError).message
                                  .toString(),
                            );
                            return;
                          }
                          Navigator.pop(sheetContext);
                          await change(
                            () => data.putShift(candidate),
                            message:
                                'Shift saved. A little more shape to your day.',
                          );
                        },
                        child: Text(
                          shift == null ? 'Add shift' : 'Save changes',
                        ),
                      ),
                    ),
                  if (shift != null) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => exportCalendar(shift),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('Add to Google Calendar'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 52),
                        ),
                      ),
                    ),
                    if (!active)
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            change(
                              () => data.shifts.removeWhere(
                                (s) => s.id == shift.id,
                              ),
                              message: 'Schedule block removed. Logged time is kept.',
                            );
                          },
                          child: const Text(
                            'Delete shift',
                            style: TextStyle(color: Color(0xFFAD423A)),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> exportCalendar(Shift shift) async {
    final format = DateFormat("yyyyMMdd'T'HHmmss'Z'");
    final uri = Uri.https('calendar.google.com', '/calendar/render', {
      'action': 'TEMPLATE',
      'text':
          'Relay · ${shift.kind == ShiftKind.focus ? 'Focus time' : 'Baby Time'}',
      'dates':
          '${format.format(shift.start.toUtc())}/${format.format(shift.end.toUtc())}',
      'details':
          'Planned with Relay. Changes in Relay are not synced to this event.',
    });
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        toast('Could not open Google Calendar.');
      }
    } catch (_) {
      toast('Could not open Google Calendar.');
    }
  }
}

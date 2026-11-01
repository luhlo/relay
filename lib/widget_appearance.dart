import 'package:flutter/material.dart';

import 'cloud.dart';
import 'home_widget.dart';
import 'model.dart';
import 'storage.dart';

const widgetColorChoices = <String, int>{
  'Violet': 0xFF6450CA,
  'Green': 0xFFDDEAAD,
  'Yellow': 0xFFF3C879,
  'Blue': 0xFF2762B2,
  'Rose': 0xFFE9A7BD,
  'Orange': 0xFFE49A58,
  'Slate': 0xFF454857,
};

enum _WidgetRole {
  work('Work Time'),
  baby('Baby Time'),
  interruption('Interruption'),
  resume('Resume'),
  end('End');

  const _WidgetRole(this.label);
  final String label;
}

class WidgetAppearance extends StatefulWidget {
  const WidgetAppearance({super.key, required this.store, this.homeWidget});

  final RelayStore store;
  final RelayHomeWidget? homeWidget;

  @override
  State<WidgetAppearance> createState() => _WidgetAppearanceState();
}

class _WidgetAppearanceState extends State<WidgetAppearance> {
  WidgetColors colors = const WidgetColors();
  _WidgetRole selectedRole = _WidgetRole.work;
  bool loading = true, busy = false, loadFailed = false;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      loadFailed = false;
      error = null;
    });
    try {
      final state = await widget.store.load();
      if (mounted) setState(() => colors = state.widgetColors);
    } catch (_) {
      loadFailed = true;
      error =
          'Could not load your colors. Check your connection and try again.';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      // Tracking can change while this page is open. Preserve the latest time,
      // child names, receipts, and agreement; update only the appearance.
      final state = await widget.store.load();
      state.widgetColors = colors;
      await widget.store.save(state);
      try {
        final bridge = widget.homeWidget ?? RelayHomeWidget.instance;
        final source = widget.store is CloudStore
            ? 'cloud:${(widget.store as CloudStore).userId}'
            : 'local';
        final ownsCloud =
            widget.store is! CloudStore ||
            (widget.store as CloudStore).client.auth.currentUser?.id ==
                (widget.store as CloudStore).userId;
        // Account changes may happen while the save acknowledgement is in
        // flight. Never repopulate a widget that has since been cleared or
        // rebound to someone else's account.
        final ownsWidget =
            !bridge.supported || await bridge.currentContext() == source;
        if (ownsCloud && ownsWidget) {
          await bridge.sync(state, source, DateTime.now());
        }
      } catch (_) {
        // The data is already saved. A launcher refresh cannot undo that save.
      }
      if (mounted) Navigator.pop(context, true);
    } on CloudSaveException catch (exception) {
      if (mounted) setState(() => error = exception.message);
    } on LocalSaveConflict catch (exception) {
      if (mounted) setState(() => error = exception.message);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not save your colors. Please try again.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  int colorFor(_WidgetRole role) => switch (role) {
    _WidgetRole.work => colors.work,
    _WidgetRole.baby => colors.baby,
    _WidgetRole.interruption => colors.interruption,
    _WidgetRole.resume => colors.resume,
    _WidgetRole.end => colors.end,
  };

  void chooseColor(int color) => setState(() {
    colors = switch (selectedRole) {
      _WidgetRole.work => colors.copyWith(work: color),
      _WidgetRole.baby => colors.copyWith(baby: color),
      _WidgetRole.interruption => colors.copyWith(interruption: color),
      _WidgetRole.resume => colors.copyWith(resume: color),
      _WidgetRole.end => colors.copyWith(end: color),
    };
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Widget appearance')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Choose the colors for your Android home-screen widget.',
              ),
              const SizedBox(height: 20),
              const Text(
                'Preview',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              WidgetAppearancePreview(
                colors: colors,
                interrupted: selectedRole == _WidgetRole.resume,
              ),
              const SizedBox(height: 20),
              for (final role in _WidgetRole.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(role.label),
                  selected: role == selectedRole,
                  leading: Icon(
                    role == selectedRole
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  trailing: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Color(colorFor(role)),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF777777)),
                    ),
                  ),
                  onTap: busy
                      ? null
                      : () => setState(() => selectedRole = role),
                ),
              const SizedBox(height: 16),
              Text(
                '${selectedRole.label} color',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final choice in widgetColorChoices.entries)
                    Semantics(
                      selected: colorFor(selectedRole) == choice.value,
                      button: true,
                      label: '${selectedRole.label}: ${choice.key}',
                      child: Tooltip(
                        message: '${selectedRole.label}: ${choice.key}',
                        child: InkWell(
                          key: ValueKey(
                            'widget-color-${selectedRole.name}-${choice.key}',
                          ),
                          onTap: busy ? null : () => chooseColor(choice.value),
                          borderRadius: BorderRadius.circular(24),
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: Color(choice.value),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF777777),
                              ),
                            ),
                            child: colorFor(selectedRole) == choice.value
                                ? Icon(
                                    Icons.check,
                                    color: _textColor(choice.value),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => setState(() => colors = const WidgetColors()),
                icon: const Icon(Icons.restore),
                label: const Text('Restore default colors'),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!, style: const TextStyle(color: Color(0xFF9D3424))),
                TextButton(
                  onPressed: busy ? null : load,
                  child: const Text('Reload colors'),
                ),
              ],
            ],
          ),
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: FilledButton(
        onPressed: loading || busy || loadFailed ? null : save,
        child: Text(busy ? 'Saving…' : 'Save widget colors'),
      ),
    ),
  );
}

class WidgetAppearancePreview extends StatelessWidget {
  const WidgetAppearancePreview({
    super.key,
    required this.colors,
    this.interrupted = false,
  });
  final WidgetColors colors;
  final bool interrupted;

  Widget half(String label, int color) => Expanded(
    child: ColoredBox(
      color: Color(color),
      child: SizedBox(
        height: 48,
        child: Center(
          child: Text(label, style: TextStyle(color: _textColor(color))),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          half('Work Time', colors.work),
          half('Baby Time', colors.baby),
        ],
      ),
      const SizedBox(height: 12),
      ColoredBox(
        color: Color(interrupted ? colors.interruption : colors.work),
        child: Center(
          child: Text(
            '00:12:34',
            style: TextStyle(
              fontSize: 14,
              color: _textColor(
                interrupted ? colors.interruption : colors.work,
              ),
            ),
          ),
        ),
      ),
      Row(
        children: [
          half(
            interrupted ? 'Resume' : 'Interruption',
            interrupted ? colors.resume : colors.interruption,
          ),
          half('End', colors.end),
        ],
      ),
    ],
  );
}

Color _textColor(int value) => Color(value).computeLuminance() > 0.22
    ? const Color(0xFF24232C)
    : Colors.white;

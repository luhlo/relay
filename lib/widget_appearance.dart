import 'package:flutter/material.dart';

import 'cloud.dart';
import 'home_widget.dart';
import 'model.dart';
import 'storage.dart';

/// Relay's existing app palette. The editor also accepts every RGB color.
const widgetColorChoices = <String, int>{
  'Violet': 0xFF6450CA,
  'Light green': 0xFFDDEAAD,
  'Yellow': 0xFFFFCC33,
  'Amber': 0xFFF3C879,
  'Lilac': 0xFFEEEBFC,
  'Cream': 0xFFF7F7F2,
  'Ink': 0xFF24232C,
  'White': 0xFFFFFFFF,
};

class WidgetAppearance extends StatefulWidget {
  const WidgetAppearance({super.key, required this.store, this.homeWidget});
  final RelayStore store;
  final RelayHomeWidget? homeWidget;

  @override
  State<WidgetAppearance> createState() => _WidgetAppearanceState();
}

class _WidgetAppearanceState extends State<WidgetAppearance> {
  WidgetColors colors = const WidgetColors();
  List<String> childNames = ['Baby 1', 'Baby 2'];
  String part = 'work';
  bool editingText = false;
  bool loading = true, busy = false, loadFailed = false, hexDirty = false;
  String? error, hexError;
  final hex = TextEditingController();
  final partField = GlobalKey<FormFieldState<String>>();

  Map<String, String> get parts => {
    'work': 'Work Time',
    'baby': 'Baby Time',
    'changeBaby': 'Change baby',
    'interruption': 'Interruption',
    'resume': 'Resume',
    'end': 'End',
    'timer': 'Timer bar',
    'allBabies': 'All babies',
    'navigation': 'Picker arrows and Cancel',
    'notice': 'Messages',
    for (var index = 0; index < childNames.length; index++)
      'child$index': '${childNames[index]} button',
  };

  int get selectedColor =>
      editingText ? colors.foregroundFor(part) : colors.backgroundFor(part);

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    hex.dispose();
    super.dispose();
  }

  void refreshHex() {
    hex.text =
        '#${(selectedColor & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    hexDirty = false;
    hexError = null;
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      loadFailed = false;
      error = null;
    });
    try {
      final state = await widget.store.load();
      if (!mounted) return;
      setState(() {
        colors = state.widgetColors;
        childNames = state.childNames.take(8).toList();
        if (!parts.containsKey(part)) part = 'work';
        refreshHex();
      });
    } catch (_) {
      loadFailed = true;
      error =
          'Could not load your colors. Check your connection and try again.';
    }
    if (mounted) setState(() => loading = false);
  }

  void chooseColor(int color) => setState(() {
    colors = editingText
        ? colors.withText(part, color)
        : colors.withBackground(part, color);
    refreshHex();
  });

  bool applyHexDraft() {
    if (!hexDirty) return true;
    final value = hex.text.trim();
    if (!RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(value)) {
      setState(() => hexError = 'Enter six hex digits, for example #6450CA.');
      return false;
    }
    chooseColor(0xFF000000 | int.parse(value.replaceFirst('#', ''), radix: 16));
    return true;
  }

  Future<void> save() async {
    if (!applyHexDraft()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      // Only replace appearance after a fresh load, preserving tracking,
      // receipts, names, and settings changed while this editor was open.
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
        final ownsWidget =
            !bridge.supported || await bridge.currentContext() == source;
        if (ownsCloud && ownsWidget) {
          await bridge.sync(state, source, DateTime.now());
        }
      } catch (_) {
        // A launcher refresh failure cannot undo confirmed saved colors.
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

  Widget channelSlider(String name, int shift) {
    final value = (selectedColor >> shift) & 255;
    return Row(
      children: [
        SizedBox(width: 56, child: Text(name)),
        Expanded(
          child: Slider(
            key: ValueKey('widget-${name.toLowerCase()}'),
            semanticFormatterCallback: (value) => '$name ${value.round()}',
            value: value.toDouble(),
            min: 0,
            max: 255,
            divisions: 255,
            label: '$value',
            onChanged: busy
                ? null
                : (next) => chooseColor(
                    (selectedColor & ~(255 << shift)) | (next.round() << shift),
                  ),
          ),
        ),
        SizedBox(width: 36, child: Text('$value', textAlign: TextAlign.end)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Widget appearance')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Choose any color for each part of your Android widget.',
                ),
                const SizedBox(height: 16),
                WidgetAppearancePreview(
                  colors: colors,
                  part: part,
                  interrupted: part == 'resume' || part == 'interruption',
                  childNames: childNames,
                ),
                const SizedBox(height: 24),
                KeyedSubtree(
                  key: const ValueKey('widget-part'),
                  child: DropdownButtonFormField<String>(
                    key: partField,
                    initialValue: part,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Widget part'),
                    items: [
                      for (final entry in parts.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(
                            entry.value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value == null) return;
                            if (!applyHexDraft()) {
                              partField.currentState?.didChange(part);
                              return;
                            }
                            setState(() {
                              part = value;
                              refreshHex();
                            });
                          },
                  ),
                ),
                const SizedBox(height: 16),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Background')),
                    ButtonSegment(value: true, label: Text('Text')),
                  ],
                  selected: {editingText},
                  onSelectionChanged: busy
                      ? null
                      : (value) {
                          if (!applyHexDraft()) return;
                          setState(() {
                            editingText = value.single;
                            refreshHex();
                          });
                        },
                ),
                if (editingText) ...[
                  const SizedBox(height: 12),
                  FilterChip(
                    label: const Text('Automatic text contrast'),
                    selected: colors.usesAutomaticText(part),
                    onSelected: busy
                        ? null
                        : (automatic) => setState(() {
                            colors = colors.withText(
                              part,
                              automatic ? null : colors.foregroundFor(part),
                            );
                            refreshHex();
                          }),
                  ),
                  const Text('Choose a color below to set the text yourself.'),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Relay palette',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final choice in widgetColorChoices.entries)
                      Semantics(
                        selected: selectedColor == choice.value,
                        button: true,
                        label:
                            '${parts[part]} ${editingText ? 'text' : 'background'}: ${choice.key}',
                        child: Tooltip(
                          message:
                              '${parts[part]} ${editingText ? 'text' : 'background'}: ${choice.key}',
                          child: InkWell(
                            onTap: busy
                                ? null
                                : () => chooseColor(choice.value),
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
                              child: selectedColor == choice.value
                                  ? Icon(
                                      Icons.check,
                                      color:
                                          Color(choice.value)
                                                  .computeLuminance() >
                                              0.22
                                          ? const Color(0xFF24232C)
                                          : Colors.white,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  key: const ValueKey('widget-hex'),
                  controller: hex,
                  enabled: !busy,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'Hex color',
                    hintText: '#RRGGBB',
                    errorText: hexError,
                    suffixIcon: IconButton(
                      tooltip: 'Apply hex color',
                      onPressed: busy ? null : applyHexDraft,
                      icon: const Icon(Icons.check),
                    ),
                  ),
                  onChanged: (_) => setState(() {
                    hexDirty = true;
                    hexError = null;
                  }),
                  onSubmitted: (_) => applyHexDraft(),
                ),
                const SizedBox(height: 12),
                channelSlider('Red', 16),
                channelSlider('Green', 8),
                channelSlider('Blue', 0),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          colors = const WidgetColors();
                          refreshHex();
                        }),
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore default colors'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    style: const TextStyle(color: Color(0xFF9D3424)),
                  ),
                  TextButton(
                    onPressed: busy ? null : load,
                    child: const Text('Reload colors'),
                  ),
                ],
              ],
            ),
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
    this.part = 'work',
    this.childNames = const ['Baby 1', 'Baby 2'],
  });
  final WidgetColors colors;
  final bool interrupted;
  final String part;
  final List<String> childNames;

  Widget tile(String label, String role, {double height = 48}) => ColoredBox(
    key: ValueKey('preview-$role'),
    color: Color(colors.backgroundFor(role)),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Center(
          child: Text(
            label,
            maxLines: role == 'timer' ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(colors.foregroundFor(role))),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final selectingBaby =
        part.startsWith('child') || part == 'allBabies' || part == 'navigation';
    final child = int.tryParse(part.replaceFirst('child', '')) ?? 0;
    final childIndex = child.clamp(
      0,
      childNames.isEmpty ? 0 : childNames.length - 1,
    );
    final name = childNames.isEmpty ? 'Baby 1' : childNames[childIndex];
    final babyTime = selectingBaby || part == 'baby' || part == 'changeBaby';
    final timerLabel = interrupted
        ? 'Interruption time'
        : part == 'allBabies'
        ? 'All babies time'
        : babyTime
        ? '$name time'
        : 'Work time';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: tile('Work Time', 'work')),
            Expanded(child: tile('Baby Time', 'baby')),
          ],
        ),
        const SizedBox(height: 12),
        tile('$timerLabel · 00:12:34', 'timer', height: 24),
        Row(
          children: [
            Expanded(
              child: tile(
                interrupted
                    ? 'Resume'
                    : babyTime
                    ? 'Change baby'
                    : 'Interruption',
                interrupted
                    ? 'resume'
                    : babyTime
                    ? 'changeBaby'
                    : 'interruption',
              ),
            ),
            Expanded(child: tile('End', 'end')),
          ],
        ),
        if (selectingBaby) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(width: 42, child: tile('‹', 'navigation')),
              Expanded(child: tile(name, 'child$childIndex')),
              SizedBox(
                width: 42,
                child: ColoredBox(
                  color: Color(colors.backgroundFor('navigation')),
                  child: SizedBox(
                    height: 48,
                    child: Center(
                      child: Text(
                        '›',
                        style: TextStyle(
                          color: Color(colors.foregroundFor('navigation')),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          tile('All babies', 'allBabies'),
        ],
        if (part == 'notice') ...[
          const SizedBox(height: 12),
          tile('Saved · ready for your next shift', 'notice', height: 32),
        ],
      ],
    );
  }
}

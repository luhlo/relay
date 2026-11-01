import 'dart:math';

DateTime nextDay(DateTime day) => DateTime(day.year, day.month, day.day + 1);

enum ShiftKind { focus, point }

// The first two values keep their original names so existing saved sessions
// continue to decode. New households can configure up to eight children.
enum Baby { chloe, luca, child3, child4, child5, child6, child7, child8, both }

extension BabyLabel on Baby {
  String get label => switch (this) {
    Baby.chloe => 'Chloe',
    Baby.luca => 'Luca',
    Baby.child3 => 'Baby 3',
    Baby.child4 => 'Baby 4',
    Baby.child5 => 'Baby 5',
    Baby.child6 => 'Baby 6',
    Baby.child7 => 'Baby 7',
    Baby.child8 => 'Baby 8',
    Baby.both => 'Both',
  };
}

const childChoices = [
  Baby.chloe,
  Baby.luca,
  Baby.child3,
  Baby.child4,
  Baby.child5,
  Baby.child6,
  Baby.child7,
  Baby.child8,
];

class Shift {
  Shift({
    required this.id,
    required this.kind,
    required this.start,
    required this.end,
  });
  final int id;
  ShiftKind kind;
  DateTime start, end;
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
  };
  factory Shift.fromJson(Map<String, dynamic> j) => Shift(
    id: j['id'],
    kind: ShiftKind.values.byName(j['kind']),
    start: DateTime.parse(j['start']).toLocal(),
    end: DateTime.parse(j['end']).toLocal(),
  );
}

class Interruption {
  Interruption(this.start, [this.end]);
  DateTime start;
  DateTime? end;
  Map<String, dynamic> toJson() => {
    'start': start.toUtc().toIso8601String(),
    'end': end?.toUtc().toIso8601String(),
  };
  factory Interruption.fromJson(Map<String, dynamic> j) => Interruption(
    DateTime.parse(j['start']).toLocal(),
    j['end'] == null ? null : DateTime.parse(j['end']).toLocal(),
  );
}

class Session {
  Session({
    required this.shiftId,
    required this.kind,
    required this.start,
    this.end,
    this.baby,
    this.lastConfirmedAt,
    this.firstUnansweredCheckIn,
    this.lastReminderAt,
    this.autoStopReason,
    List<Interruption>? interruptions,
  }) : interruptions = interruptions ?? [];
  final Baby? baby;
  final int shiftId;
  final ShiftKind kind;
  final DateTime start;
  DateTime? end;
  DateTime? lastConfirmedAt, firstUnansweredCheckIn, lastReminderAt;
  String? autoStopReason;
  final List<Interruption> interruptions;
  Interruption? get interruption =>
      interruptions.isNotEmpty && interruptions.last.end == null
      ? interruptions.last
      : null;
  Map<String, dynamic> toJson() => {
    'shiftId': shiftId,
    'baby': baby?.name,
    'kind': kind.name,
    'start': start.toUtc().toIso8601String(),
    'end': end?.toUtc().toIso8601String(),
    'interruptions': interruptions.map((e) => e.toJson()).toList(),
    'lastConfirmedAt': lastConfirmedAt?.toUtc().toIso8601String(),
    'firstUnansweredCheckIn': firstUnansweredCheckIn?.toUtc().toIso8601String(),
    'lastReminderAt': lastReminderAt?.toUtc().toIso8601String(),
    'autoStopReason': autoStopReason,
  };
  factory Session.fromJson(Map<String, dynamic> j) => Session(
    shiftId: j['shiftId'],
    baby: j['baby'] == null ? null : Baby.values.byName(j['baby']),
    kind: ShiftKind.values.byName(j['kind']),
    start: DateTime.parse(j['start']).toLocal(),
    end: j['end'] == null ? null : DateTime.parse(j['end']).toLocal(),
    lastConfirmedAt: j['lastConfirmedAt'] == null
        ? null
        : DateTime.parse(j['lastConfirmedAt']).toLocal(),
    firstUnansweredCheckIn: j['firstUnansweredCheckIn'] == null
        ? null
        : DateTime.parse(j['firstUnansweredCheckIn']).toLocal(),
    lastReminderAt: j['lastReminderAt'] == null
        ? null
        : DateTime.parse(j['lastReminderAt']).toLocal(),
    autoStopReason: j['autoStopReason'] as String?,
    interruptions: (j['interruptions'] as List)
        .map((e) => Interruption.fromJson(e))
        .toList(),
  );
}

int overlapSeconds(DateTime a, DateTime b, DateTime from, DateTime to) =>
    max(
      0,
      min(b.millisecondsSinceEpoch, to.millisecondsSinceEpoch) -
          max(a.millisecondsSinceEpoch, from.millisecondsSinceEpoch),
    ) ~/
    1000;
DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

/// Colors for every visible part of the Android widget. Missing text overrides
/// use the higher-contrast choice of Relay ink and white.
class WidgetColors {
  const WidgetColors({
    this.work = 0xFF6450CA,
    this.baby = 0xFFDDEAAD,
    this.interruption = 0xFFFFCC33,
    this.resume = 0xFF6450CA,
    this.end = 0xFFDDEAAD,
    this.changeBaby = 0xFF6450CA,
    this.timer = 0xFFEEEBFC,
    this.allBabies = 0xFF6450CA,
    this.navigation = 0xFFEEEBFC,
    this.notice = 0xFFEEEBFC,
    this.childColors = const {},
    this.textColors = const {},
  });

  static const backgroundRoles = <String>[
    'work',
    'baby',
    'interruption',
    'resume',
    'end',
    'changeBaby',
    'timer',
    'allBabies',
    'navigation',
    'notice',
    'child0',
    'child1',
    'child2',
    'child3',
    'child4',
    'child5',
    'child6',
    'child7',
  ];
  static const _childDefaults = <int>[0xFFDDEAAD, 0xFFEEEBFC, 0xFFF3C879];
  static const _legacyDefaults = <String, int>{
    'work': 0xFF6450CA,
    'baby': 0xFFDDEAAD,
    'interruption': 0xFFF3C879,
    'resume': 0xFF2762B2,
    'end': 0xFF6450CA,
  };

  final int work, baby, interruption, resume, end, changeBaby;
  final int timer, allBabies, navigation, notice;
  final Map<int, int> childColors;
  final Map<String, int> textColors;

  static int _opaque(int color) => 0xFF000000 | (color & 0x00FFFFFF);

  int backgroundFor(String role) {
    switch (role) {
      case 'work':
        return work;
      case 'baby':
        return baby;
      case 'interruption':
        return interruption;
      case 'resume':
        return resume;
      case 'end':
        return end;
      case 'changeBaby':
        return changeBaby;
      case 'timer':
        return timer;
      case 'allBabies':
        return allBabies;
      case 'navigation':
        return navigation;
      case 'notice':
        return notice;
    }
    final index = role.startsWith('child')
        ? int.tryParse(role.substring(5))
        : null;
    if (index != null && index >= 0 && index < 8 && role == 'child$index') {
      return childColors[index] ??
          _childDefaults[index % _childDefaults.length];
    }
    throw ArgumentError.value(role, 'role', 'Unknown widget part');
  }

  bool usesAutomaticText(String role) => !textColors.containsKey(role);

  int foregroundFor(String role) =>
      textColors[role] ?? widgetForegroundColor(backgroundFor(role));

  WidgetColors copyWith({
    int? work,
    int? baby,
    int? interruption,
    int? resume,
    int? end,
    int? changeBaby,
    int? timer,
    int? allBabies,
    int? navigation,
    int? notice,
    Map<int, int>? childColors,
    Map<String, int>? textColors,
  }) => WidgetColors(
    work: work ?? this.work,
    baby: baby ?? this.baby,
    interruption: interruption ?? this.interruption,
    resume: resume ?? this.resume,
    end: end ?? this.end,
    changeBaby: changeBaby ?? this.changeBaby,
    timer: timer ?? this.timer,
    allBabies: allBabies ?? this.allBabies,
    navigation: navigation ?? this.navigation,
    notice: notice ?? this.notice,
    childColors: childColors == null
        ? this.childColors
        : Map.unmodifiable(childColors),
    textColors: textColors == null
        ? this.textColors
        : Map.unmodifiable(textColors),
  );

  WidgetColors withBackground(String role, int color) {
    final value = _opaque(color);
    switch (role) {
      case 'work':
        return copyWith(work: value);
      case 'baby':
        return copyWith(baby: value);
      case 'interruption':
        return copyWith(interruption: value);
      case 'resume':
        return copyWith(resume: value);
      case 'end':
        return copyWith(end: value);
      case 'changeBaby':
        return copyWith(changeBaby: value);
      case 'timer':
        return copyWith(timer: value);
      case 'allBabies':
        return copyWith(allBabies: value);
      case 'navigation':
        return copyWith(navigation: value);
      case 'notice':
        return copyWith(notice: value);
    }
    backgroundFor(role); // Validate before changing a child color.
    final index = int.parse(role.substring(5));
    return copyWith(childColors: {...childColors, index: value});
  }

  WidgetColors withText(String role, int? color) {
    backgroundFor(role);
    final updated = Map<String, int>.of(textColors);
    if (color == null) {
      updated.remove(role);
    } else {
      updated[role] = _opaque(color);
    }
    return copyWith(textColors: updated);
  }

  Map<String, dynamic> toJson() => {
    'version': 3,
    for (final role in backgroundRoles) role: _opaque(backgroundFor(role)),
    'text': {
      for (final entry in textColors.entries)
        if (backgroundRoles.contains(entry.key))
          entry.key: _opaque(entry.value),
    },
  };

  factory WidgetColors.fromJson(Object? value) {
    if (value is! Map) return const WidgetColors();
    final version = value['version'];
    final legacy = version == null || (version is int && version < 2);
    final untouched = _legacyDefaults.entries.every(
      (entry) => value[entry.key] is int && value[entry.key] == entry.value,
    );
    final extended =
        value.containsKey('text') ||
        backgroundRoles.any(
          (role) =>
              !_legacyDefaults.containsKey(role) && value.containsKey(role),
        );
    // Upgrade the old shipped palette, while keeping every deliberately
    // customized old palette. Partial/malformed maps are parsed field by field.
    if (legacy && untouched && !extended) return const WidgetColors();

    int? validColor(Object? raw) =>
        raw is int && raw >= 0 && raw <= 0xFFFFFFFF ? _opaque(raw) : null;
    const defaults = WidgetColors();
    int color(String role) {
      // Version 2 shipped the softer app amber. Upgrade that default without
      // replacing a deliberately different interruption color.
      if (version == 2 && role == 'interruption' && value[role] == 0xFFF3C879) {
        return defaults.interruption;
      }
      return validColor(value[role]) ?? defaults.backgroundFor(role);
    }

    final texts = value['text'];
    return WidgetColors(
      work: color('work'),
      baby: color('baby'),
      interruption: color('interruption'),
      resume: color('resume'),
      end: color('end'),
      changeBaby: color('changeBaby'),
      timer: color('timer'),
      allBabies: color('allBabies'),
      navigation: color('navigation'),
      notice: color('notice'),
      childColors: Map.unmodifiable({
        for (var index = 0; index < 8; index++)
          if (validColor(value['child$index']) case final int color)
            index: color,
      }),
      textColors: Map.unmodifiable({
        if (texts is Map)
          for (final role in backgroundRoles)
            if (validColor(texts[role]) case final int color) role: color,
      }),
    );
  }
}

/// WCAG relative luminance, shared with native widget text defaults.
int widgetForegroundColor(int background) {
  double linear(int channel) {
    final srgb = channel / 255.0;
    return srgb <= 0.04045
        ? srgb / 12.92
        : pow((srgb + 0.055) / 1.055, 2.4).toDouble();
  }

  double luminance(int color) =>
      0.2126 * linear((color >> 16) & 255) +
      0.7152 * linear((color >> 8) & 255) +
      0.0722 * linear(color & 255);
  const ink = 0xFF24232C;
  final light = luminance(background);
  final dark = luminance(ink);
  final inkContrast = (max(light, dark) + 0.05) / (min(light, dark) + 0.05);
  final whiteContrast = 1.05 / (light + 0.05);
  return inkContrast >= whiteContrast ? ink : 0xFFFFFFFF;
}

class RelayState {
  RelayState({
    List<Shift>? shifts,
    List<Session>? sessions,
    this.alerts = false,
    this.personalTimeEnabled = false,
    this.dailyPersonalHours = 3,
    this.lastWidgetRequestId,
    this.widgetColors = const WidgetColors(),
    List<String>? childNames,
    String? childOne,
    String? childTwo,
  }) : shifts = shifts ?? [],
       sessions = sessions ?? [],
       childNames = childNames ?? [childOne ?? 'Baby 1', childTwo ?? 'Baby 2'];
  final List<Shift> shifts;
  final List<Session> sessions;
  bool alerts;
  bool personalTimeEnabled;
  int dailyPersonalHours;
  String? lastWidgetRequestId;
  WidgetColors widgetColors;
  List<String> childNames;
  String get childOne => childNames.first;
  set childOne(String value) => childNames[0] = value;
  String get childTwo => childNames.length > 1 ? childNames[1] : 'Baby 2';
  set childTwo(String value) {
    if (childNames.length == 1) {
      childNames.add(value);
    } else {
      childNames[1] = value;
    }
  }

  List<Baby> get availableBabies => [
    ...childChoices.take(childNames.length),
    if (childNames.length > 1) Baby.both,
  ];
  String babyName(Baby baby) {
    if (baby == Baby.both) return 'All children';
    final index = childChoices.indexOf(baby);
    return index >= 0 && index < childNames.length
        ? childNames[index]
        : 'Baby ${index + 1}';
  }

  Session? get active =>
      sessions.isNotEmpty && sessions.last.end == null ? sessions.last : null;
  Shift? get activeShift {
    final id = active?.shiftId;
    for (final s in shifts) {
      if (s.id == id) return s;
    }
    return null;
  }

  int get nextId => shifts.fold(0, (v, s) => max(v, s.id)) + 1;
  void start(ShiftKind kind, DateTime now, {Baby? baby}) {
    final selectedBaby = kind == ShiftKind.point ? baby : null;
    if (active?.kind == kind && active?.baby == selectedBaby) return;
    finish(now);
    Shift? block;
    for (final s in shifts) {
      if (!s.start.isAfter(now) && s.end.isAfter(now)) {
        block = s;
        break;
      }
    }
    if (block == null) {
      var end = now.add(const Duration(hours: 1));
      for (final s in shifts) {
        if (s.start.isAfter(now) && s.start.isBefore(end)) end = s.start;
      }
      block = Shift(id: nextId, kind: kind, start: now, end: end);
      shifts.add(block);
      sort();
    }
    sessions.add(
      Session(shiftId: block.id, kind: kind, start: now, baby: selectedBaby),
    );
  }

  void finish(DateTime now, {String? reason}) {
    final s = active;
    if (s == null) return;
    s.interruption?.end = now;
    s.end = now;
    s.autoStopReason = reason;
  }

  void toggleInterruption(DateTime now) {
    final s = active;
    if (s == null || s.kind != ShiftKind.focus) return;
    s.lastConfirmedAt = now;
    s.firstUnansweredCheckIn = null;
    s.lastReminderAt = null;
    if (s.interruption != null) {
      s.interruption!.end = now;
    } else {
      s.interruptions.add(Interruption(now));
    }
  }

  void push() {
    final block = activeShift;
    if (block == null) return;
    block.end = block.end.add(const Duration(minutes: 15));
    sort();
    var edge = block.end;
    for (final s in shifts.skip(shifts.indexOf(block) + 1)) {
      if (s.start.isBefore(edge)) {
        final delta = edge.difference(s.start);
        s.start = s.start.add(delta);
        s.end = s.end.add(delta);
      }
      edge = s.end;
    }
  }

  void sort() => shifts.sort((a, b) => a.start.compareTo(b.start));
  void putShift(Shift shift) {
    if (!shift.end.isAfter(shift.start)) {
      throw ArgumentError('End time must be after start time.');
    }
    if (shifts.any(
      (s) =>
          s.id != shift.id &&
          shift.start.isBefore(s.end) &&
          shift.end.isAfter(s.start),
    )) {
      throw ArgumentError(
        'That block overlaps another shift. Choose a free time.',
      );
    }
    shifts.removeWhere((s) => s.id == shift.id);
    shifts.add(shift);
    sort();
  }

  List<Shift> onDay(DateTime day) {
    final from = dayStart(day), to = DateTime(day.year, day.month, day.day + 1);
    return shifts
        .where((s) => s.start.isBefore(to) && s.end.isAfter(from))
        .toList();
  }

  int scheduledSeconds(DateTime day, {DateTime? endDay}) => shifts
      .where((s) => s.kind == ShiftKind.focus)
      .fold(
        0,
        (v, s) =>
            v +
            overlapSeconds(
              s.start,
              s.end,
              dayStart(day),
              nextDay(endDay ?? day),
            ),
      );
  int lostSeconds(DateTime day, DateTime now, {DateTime? endDay}) =>
      sessions.fold(
        0,
        (v, s) =>
            v +
            s.interruptions.fold(
              0,
              (n, i) =>
                  n +
                  overlapSeconds(
                    i.start,
                    i.end ?? now,
                    dayStart(day),
                    nextDay(endDay ?? day),
                  ),
            ),
      );
  int actualSeconds(DateTime day, DateTime now, {DateTime? endDay}) {
    final from = dayStart(day), to = nextDay(endDay ?? day);
    return sessions
        .where((s) => s.kind == ShiftKind.focus)
        .fold(
          0,
          (v, s) =>
              v +
              max(
                0,
                overlapSeconds(s.start, s.end ?? now, from, to) -
                    s.interruptions.fold(
                      0,
                      (n, i) =>
                          n + overlapSeconds(i.start, i.end ?? now, from, to),
                    ),
              ),
        );
  }

  int totalWorkSeconds(DateTime day, DateTime now, {DateTime? endDay}) =>
      actualSeconds(day, now, endDay: endDay) +
      lostSeconds(day, now, endDay: endDay);

  int babySeconds(
    DateTime day,
    DateTime now, {
    Baby? baby,
    bool unassignedOnly = false,
    DateTime? endDay,
  }) {
    final from = dayStart(day), to = nextDay(endDay ?? day);
    return sessions
        .where(
          (s) =>
              s.kind == ShiftKind.point &&
              (unassignedOnly
                  ? s.baby == null
                  : baby == null ||
                        s.baby == baby ||
                        (baby != Baby.both && s.baby == Baby.both)),
        )
        .fold(
          0,
          (sum, s) => sum + overlapSeconds(s.start, s.end ?? now, from, to),
        );
  }

  int sessionSeconds(DateTime now) {
    final s = active;
    if (s == null) return 0;
    return max(
      0,
      now.difference(s.start).inSeconds -
          s.interruptions.fold(
            0,
            (v, i) => v + (i.end ?? now).difference(i.start).inSeconds,
          ),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 4,
    'childNames': childNames,
    'childOne': childOne,
    'childTwo': childTwo,
    'alerts': alerts,
    'personalTimeEnabled': personalTimeEnabled,
    'dailyPersonalHours': dailyPersonalHours,
    'lastWidgetRequestId': lastWidgetRequestId,
    'widgetColors': widgetColors.toJson(),
    'shifts': shifts.map((s) => s.toJson()).toList(),
    'sessions': sessions.map((s) => s.toJson()).toList(),
  };
  factory RelayState.fromJson(Map<String, dynamic> j) => RelayState(
    childNames: j['childNames'] == null
        ? [j['childOne'] ?? 'Baby 1', j['childTwo'] ?? 'Baby 2']
        : List<String>.from(j['childNames']),
    alerts: j['alerts'] ?? false,
    personalTimeEnabled: j['personalTimeEnabled'] ?? false,
    dailyPersonalHours: (j['dailyPersonalHours'] as num?)?.toInt() ?? 3,
    lastWidgetRequestId: j['lastWidgetRequestId'] as String?,
    widgetColors: WidgetColors.fromJson(j['widgetColors']),
    shifts: (j['shifts'] as List).map((e) => Shift.fromJson(e)).toList(),
    sessions: (j['sessions'] as List).map((e) => Session.fromJson(e)).toList(),
  );
}

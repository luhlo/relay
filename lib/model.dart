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
    List<Interruption>? interruptions,
  }) : interruptions = interruptions ?? [];
  final Baby? baby;
  final int shiftId;
  final ShiftKind kind;
  final DateTime start;
  DateTime? end;
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
  };
  factory Session.fromJson(Map<String, dynamic> j) => Session(
    shiftId: j['shiftId'],
    baby: j['baby'] == null ? null : Baby.values.byName(j['baby']),
    kind: ShiftKind.values.byName(j['kind']),
    start: DateTime.parse(j['start']).toLocal(),
    end: j['end'] == null ? null : DateTime.parse(j['end']).toLocal(),
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

class RelayState {
  RelayState({
    List<Shift>? shifts,
    List<Session>? sessions,
    this.alerts = false,
    List<String>? childNames,
    String? childOne,
    String? childTwo,
  }) : shifts = shifts ?? [],
       sessions = sessions ?? [],
       childNames = childNames ?? [childOne ?? 'Baby 1', childTwo ?? 'Baby 2'];
  final List<Shift> shifts;
  final List<Session> sessions;
  bool alerts;
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

  void finish(DateTime now) {
    final s = active;
    if (s == null) return;
    s.interruption?.end = now;
    s.end = now;
  }

  void toggleInterruption(DateTime now) {
    final s = active;
    if (s == null || s.kind != ShiftKind.focus) return;
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
    'version': 3,
    'childNames': childNames,
    'childOne': childOne,
    'childTwo': childTwo,
    'alerts': alerts,
    'shifts': shifts.map((s) => s.toJson()).toList(),
    'sessions': sessions.map((s) => s.toJson()).toList(),
  };
  factory RelayState.fromJson(Map<String, dynamic> j) => RelayState(
    childNames: j['childNames'] == null
        ? [j['childOne'] ?? 'Baby 1', j['childTwo'] ?? 'Baby 2']
        : List<String>.from(j['childNames']),
    alerts: j['alerts'] ?? false,
    shifts: (j['shifts'] as List).map((e) => Shift.fromJson(e)).toList(),
    sessions: (j['sessions'] as List).map((e) => Session.fromJson(e)).toList(),
  );
}

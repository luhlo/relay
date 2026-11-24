import 'dart:math';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import 'model.dart';

class TrendDay {
  TrendDay(this.day, RelayState data, DateTime now)
    : total = data.totalWorkSeconds(day, now),
      actual = data.actualSeconds(day, now),
      lost = data.lostSeconds(day, now),
      baby = data.babySeconds(day, now),
      care = {
        for (final child in data.availableBabies)
          child: data.babySeconds(day, now, baby: child),
      },
      interruptions = data.sessions
          .expand((s) => s.interruptions)
          .where((i) => dayStart(i.start) == day)
          .length,
      hasWork = _recorded(data, day, now, ShiftKind.focus),
      hasBaby = _recorded(data, day, now, ShiftKind.point);
  TrendDay._(this.day, _TrendTotals totals)
    : actual = totals.actual,
      lost = totals.lost,
      total = totals.actual + totals.lost,
      baby = totals.baby,
      care = Map.unmodifiable(totals.care),
      interruptions = totals.interruptions,
      hasWork = totals.hasWork,
      hasBaby = totals.hasBaby;
  final DateTime day;
  final int total, actual, lost, baby, interruptions;
  final Map<Baby, int> care;
  final bool hasWork, hasBaby;
  static bool _recorded(
    RelayState data,
    DateTime day,
    DateTime now,
    ShiftKind kind,
  ) {
    final end = DateTime(day.year, day.month, day.day + 1);
    return data.sessions.any(
      (s) =>
          s.kind == kind &&
          s.start.isBefore(end) &&
          (s.end ?? now).isAfter(day),
    );
  }
}

class _TrendTotals {
  _TrendTotals(Iterable<Baby> children)
    : care = {for (final child in children) child: 0};
  int actual = 0, lost = 0, baby = 0, interruptions = 0;
  bool hasWork = false, hasBaby = false;
  final Map<Baby, int> care;
}

List<TrendDay> dailyTrends(
  RelayState data,
  DateTime ending,
  int days,
  DateTime now,
) {
  if (days <= 0) return const [];
  final end = dayStart(ending.isAfter(now) ? now : ending);
  final from = DateTime(end.year, end.month, end.day - days + 1);
  final until = nextDay(end);
  final children = data.availableBabies;
  final totals = <DateTime, _TrendTotals>{
    for (var day = from; day.isBefore(until); day = nextDay(day))
      day: _TrendTotals(children),
  };

  // Index only the calendar days touched by each record. The previous version
  // scanned every saved session for every selected day (including empty years).
  void overlapDays(
    DateTime start,
    DateTime finish,
    void Function(DateTime) visit,
  ) {
    var day = dayStart(start);
    if (day.isBefore(from)) day = from;
    while (day.isBefore(until) && day.isBefore(finish)) {
      visit(day);
      day = nextDay(day);
    }
  }

  for (final session in data.sessions) {
    final interrupted = <DateTime, int>{};
    for (final interruption in session.interruptions) {
      final countDay = totals[dayStart(interruption.start)];
      if (countDay != null) countDay.interruptions++;
      final finish = interruption.end ?? now;
      overlapDays(interruption.start, finish, (day) {
        final seconds = overlapSeconds(
          interruption.start,
          finish,
          day,
          nextDay(day),
        );
        totals[day]!.lost += seconds;
        interrupted[day] = (interrupted[day] ?? 0) + seconds;
      });
    }
    final finish = session.end ?? now;
    overlapDays(session.start, finish, (day) {
      final value = totals[day]!;
      final seconds = overlapSeconds(session.start, finish, day, nextDay(day));
      if (session.kind == ShiftKind.focus) {
        value.hasWork = true;
        value.actual += max(0, seconds - (interrupted[day] ?? 0));
      } else {
        value.hasBaby = true;
        value.baby += seconds;
        for (final child in children) {
          if (session.caresFor(child)) {
            value.care[child] = value.care[child]! + seconds;
          }
        }
      }
    });
  }
  return List.unmodifiable(
    totals.entries.map((entry) => TrendDay._(entry.key, entry.value)),
  );
}

/// Reuse completed history; only an active timer's current day changes with the
/// clock. The serialized record fingerprint also catches in-place mutations.
class DailyTrendsCache {
  String? _fingerprint;
  DateTime? _ending, _sampledAt;
  int? _days;
  List<TrendDay>? _points;

  List<TrendDay> read(
    RelayState data,
    DateTime ending,
    int days,
    DateTime now,
  ) {
    final fingerprint = jsonEncode({
      'children': data.childNames,
      'sessions': data.sessions.map((session) => session.toJson()).toList(),
    });
    final end = dayStart(ending.isAfter(now) ? now : ending);
    if (_points == null ||
        _fingerprint != fingerprint ||
        _ending != end ||
        _days != days ||
        dayStart(_sampledAt!) != dayStart(now)) {
      _points = dailyTrends(data, end, days, now);
      _fingerprint = fingerprint;
      _ending = end;
      _days = days;
    } else if (_sampledAt != now &&
        data.active != null &&
        _points!.isNotEmpty) {
      final today = dayStart(now);
      final first = _points!.first.day;
      final index = DateTime.utc(
        today.year,
        today.month,
        today.day,
      ).difference(DateTime.utc(first.year, first.month, first.day)).inDays;
      if (index >= 0 && index < _points!.length) {
        _points = List.unmodifiable([
          ..._points!.take(index),
          TrendDay(today, data, now),
          ..._points!.skip(index + 1),
        ]);
      }
    }
    _sampledAt = now;
    return _points!;
  }
}

class TrendsCard extends StatefulWidget {
  const TrendsCard({
    super.key,
    required this.data,
    required this.ending,
    required this.now,
    this.starting,
  });
  final RelayState data;
  final DateTime ending, now;
  final DateTime? starting;
  @override
  State<TrendsCard> createState() => _TrendsCardState();
}

class _TrendsCardState extends State<TrendsCard> {
  int days = 7, mode = 0;
  DateTime? selected;
  final _dailyCache = DailyTrendsCache();
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final start = widget.starting;
    final countDays = start == null
        ? days
        : DateTime.utc(
                    widget.ending.year,
                    widget.ending.month,
                    widget.ending.day,
                  )
                  .difference(DateTime.utc(start.year, start.month, start.day))
                  .inDays +
              1;
    final points = _dailyCache.read(
      widget.data,
      widget.ending,
      countDays,
      widget.now,
    );
    var index = selected == null
        ? points.length - 1
        : points.indexWhere((p) => p.day == selected);
    if (index < 0) index = points.length - 1;
    final point = points[index];
    final series = mode == 0
        ? [
            _Series(
              'Total work',
              colors.onSurface,
              points.map((p) => p.hasWork ? p.total / 60 : null).toList(),
            ),
            _Series(
              'Actual focus',
              colors.primary,
              points.map((p) => p.hasWork ? p.actual / 60 : null).toList(),
            ),
            _Series(
              'Interrupted',
              dark ? const Color(0xFFF3C879) : const Color(0xFF985E00),
              points.map((p) => p.hasWork ? p.lost / 60 : null).toList(),
            ),
          ]
        : mode == 1
        ? [
            _Series(
              'Interruption count',
              dark ? const Color(0xFFF3C879) : const Color(0xFF985E00),
              points
                  .map((p) => p.hasWork ? p.interruptions.toDouble() : null)
                  .toList(),
            ),
          ]
        : [
            _Series(
              'Total Baby Time',
              colors.onSurface,
              points.map((p) => p.hasBaby ? p.baby / 60 : null).toList(),
            ),
            for (final entry in widget.data.availableBabies.indexed)
              _Series(
                widget.data.babyName(entry.$2),
                (dark ? _darkCareColors : _careColors)[entry.$1 %
                    _careColors.length],
                points
                    .map((p) => p.hasBaby ? (p.care[entry.$2] ?? 0) / 60 : null)
                    .toList(),
              ),
          ];
    final hasData = series.any((s) => s.values.any((v) => v != null));
    final total = points.fold(0, (n, p) => n + p.total);
    final lost = points.fold(0, (n, p) => n + p.lost);
    final count = points.fold(0, (n, p) => n + p.interruptions);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your rhythm over time',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'See how focus, interruptions, and care change day by day.',
            style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 16),
          if (start == null)
            Wrap(
              spacing: 10,
              children: [
                for (final n in [7, 30])
                  ChoiceChip(
                    label: Text('$n days'),
                    selected: days == n,
                    onSelected: (_) => setState(() {
                      days = n;
                      selected = null;
                    }),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Text(
            '${DateFormat.MMMd().format(points.first.day)} – ${DateFormat.yMMMd().format(points.last.day)}',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final entry in [
                'Work time',
                'Interruptions',
                'Baby Time',
              ].indexed)
                ChoiceChip(
                  label: Text(entry.$2),
                  selected: mode == entry.$1,
                  onSelected: (_) => setState(() => mode = entry.$1),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            mode == 1 ? 'INTERRUPTIONS / DAY' : 'MINUTES / DAY',
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) => Semantics(
              label: 'Daily trend graph. Use the previous and next day buttons below to read exact values.',
              child: GestureDetector(
                onTapDown: (details) => setState(() {
                  final n =
                      ((details.localPosition.dx - 40) /
                              max(1, constraints.maxWidth - 50) *
                              (points.length - 1))
                          .round()
                          .clamp(0, points.length - 1);
                  selected = points[n].day;
                }),
                child: SizedBox(
                  height: 220,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _TrendPainter(
                      points,
                      series,
                      index,
                      labelColor: colors.onSurfaceVariant,
                      gridColor: colors.outlineVariant,
                      highlightColor: colors.primary,
                      pointCenterColor: colors.surfaceContainerLow,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (!hasData)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'No sessions in this range yet. Your first session will add a point; more days will reveal the trend.',
              ),
            ),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              for (final s in series)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: s.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        s.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous trend day',
                      onPressed: index == 0
                          ? null
                          : () => setState(
                              () => selected = points[index - 1].day,
                            ),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Text(
                        '${DateFormat.MMMd().format(point.day)}${point.day == dayStart(widget.now) ? ' · today so far' : ''}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Next trend day',
                      onPressed: index == points.length - 1
                          ? null
                          : () => setState(
                              () => selected = points[index + 1].day,
                            ),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                for (final s in series)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '${s.label}: ${s.values[index] == null
                          ? 'not recorded'
                          : mode == 1
                          ? s.values[index]!.round().toString()
                          : '${s.values[index]!.toStringAsFixed(1)} min'}',
                      style: TextStyle(
                        color: s.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (mode != 2 && total > 0) ...[
            const SizedBox(height: 16),
            Text(
              'This range: ${(lost / total * 100).toStringAsFixed(1)}% of work time interrupted · ${(count / (total / 3600)).toStringAsFixed(1)} interruptions per work hour.',
              style: const TextStyle(fontSize: 12, height: 1.6),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Tap a day to inspect it. Gaps mean no sessions recorded, not zero activity. Today is incomplete. Interruption counts use the day each interruption started.',
            style: TextStyle(
              fontSize: 11,
              height: 1.6,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Series {
  _Series(this.label, this.color, this.values);
  final String label;
  final Color color;
  final List<double?> values;
}

const _careColors = [
  Color(0xFF678025),
  Color(0xFF477FB0),
  Color(0xFF9D6616),
  Color(0xFF8A4F9E),
  Color(0xFF19847A),
  Color(0xFFC05252),
  Color(0xFF5D6B9D),
  Color(0xFF7B6544),
  Color(0xFF24232C),
];

const _darkCareColors = [
  Color(0xFFBCD88E),
  Color(0xFF90C7F4),
  Color(0xFFF3C879),
  Color(0xFFE3AEF3),
  Color(0xFF84D7CF),
  Color(0xFFFFB4AD),
  Color(0xFFBFC9FF),
  Color(0xFFDCC4A5),
  Color(0xFFF1EEF6),
];

class _TrendPainter extends CustomPainter {
  _TrendPainter(
    this.days,
    this.series,
    this.selected, {
    required this.labelColor,
    required this.gridColor,
    required this.highlightColor,
    required this.pointCenterColor,
  });
  final List<TrendDay> days;
  final List<_Series> series;
  final int selected;
  final Color labelColor, gridColor, highlightColor, pointCenterColor;
  @override
  void paint(Canvas canvas, Size size) {
    const left = 40.0, top = 10.0;
    final width = max(1.0, size.width - left - 10), height = size.height - 40;
    final high = series
        .expand((s) => s.values)
        .whereType<double>()
        .fold(0.0, max);
    final step = max(1, (high / 4).ceil());
    final maximum = step * 4.0;
    void label(String text, Offset position, {bool center = false}) {
      final p = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: labelColor, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(
        canvas,
        Offset(
          (position.dx - (center ? p.width / 2 : 0)).clamp(
            0.0,
            max(0, size.width - p.width),
          ),
          position.dy,
        ),
      );
    }

    for (var i = 0; i <= 4; i++) {
      final y = top + height - height * i / 4;
      canvas.drawLine(
        Offset(left, y),
        Offset(left + width, y),
        Paint()..color = gridColor,
      );
      label('${step * i}', Offset(0, y - 6));
    }
    double x(int i) => days.length == 1
        ? left + width / 2
        : left + width * i / (days.length - 1);
    canvas.drawLine(
      Offset(x(selected), top),
      Offset(x(selected), top + height),
      Paint()
        ..color = highlightColor
        ..strokeWidth = 1.5,
    );
    for (final i in {0, (days.length - 1) ~/ 2, days.length - 1}) {
      label(
        DateFormat('M/d').format(days[i].day),
        Offset(x(i), top + height + 10),
        center: true,
      );
    }
    for (final s in series) {
      Offset? previous;
      for (var i = 0; i < days.length; i++) {
        final value = s.values[i];
        if (value == null) {
          previous = null;
          continue;
        }
        final point = Offset(x(i), top + height * (1 - value / maximum));
        if (previous != null) {
          canvas.drawLine(
            previous,
            point,
            Paint()
              ..color = s.color
              ..strokeWidth = 2.5
              ..strokeCap = StrokeCap.round,
          );
        }
        canvas.drawCircle(
          point,
          i == selected ? 5 : 3,
          Paint()..color = s.color,
        );
        canvas.drawCircle(
          point,
          i == selected ? 2.5 : 1.2,
          Paint()..color = pointCenterColor,
        );
        previous = point;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      !identical(days, oldDelegate.days) ||
      selected != oldDelegate.selected ||
      labelColor != oldDelegate.labelColor ||
      gridColor != oldDelegate.gridColor ||
      highlightColor != oldDelegate.highlightColor ||
      pointCenterColor != oldDelegate.pointCenterColor ||
      series.length != oldDelegate.series.length ||
      series.indexed.any(
        (entry) =>
            entry.$2.label != oldDelegate.series[entry.$1].label ||
            entry.$2.color != oldDelegate.series[entry.$1].color,
      );
}

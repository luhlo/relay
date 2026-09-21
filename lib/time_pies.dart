import 'dart:math';

import 'package:flutter/material.dart';

import 'model.dart';

class TimePies extends StatelessWidget {
  const TimePies({
    super.key,
    required this.data,
    required this.day,
    required this.now,
    this.endDay,
  });
  final RelayState data;
  final DateTime day, now;
  final DateTime? endDay;

  @override
  Widget build(BuildContext context) {
    final work = data.totalWorkSeconds(day, now, endDay: endDay);
    final baby = data.babySeconds(day, now, endDay: endDay);
    final daily = _PieCard(
      title: 'Daily time',
      description: 'Share of logged time for the selected period. Untracked time is excluded.',
      empty: 'Start a work or Baby Time session to see your daily split.',
      slices: [
        _Slice('Work (including interruptions)', work, const Color(0xFF6450CA)),
        _Slice('Baby Time', baby, const Color(0xFF456B24)),
      ],
    );
    final focus = _PieCard(
      title: 'Focus time',
      description: 'Share of total work time. Baby Time is excluded.',
      empty: 'Start a focus session to see your work-time split.',
      slices: [
        _Slice(
          'Actual focus',
          data.actualSeconds(day, now, endDay: endDay),
          const Color(0xFF6450CA),
        ),
        _Slice(
          'Interrupted',
          data.lostSeconds(day, now, endDay: endDay),
          const Color(0xFFA96100),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 760
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: daily),
                const SizedBox(width: 20),
                Expanded(child: focus),
              ],
            )
          : Column(children: [daily, const SizedBox(height: 20), focus]),
    );
  }
}

class _Slice {
  const _Slice(this.label, this.seconds, this.color);
  final String label;
  final int seconds;
  final Color color;
}

String _time(int seconds) => seconds < 60
    ? '${seconds}s'
    : seconds < 3600
    ? '${seconds ~/ 60}m'
    : '${seconds ~/ 3600}h ${seconds ~/ 60 % 60}m';

class _PieCard extends StatelessWidget {
  const _PieCard({
    required this.title,
    required this.description,
    required this.empty,
    required this.slices,
  });
  final String title, description, empty;
  final List<_Slice> slices;

  @override
  Widget build(BuildContext context) {
    final total = slices.fold(0, (sum, slice) => sum + slice.seconds);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE8E8E2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(
              color: Color(0xFF73727C),
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 22),
          Center(
            child: Semantics(
              label: total == 0
                  ? '$title: no time logged'
                  : '$title pie chart. ${slices.map((s) => '${s.label}: ${(s.seconds / total * 100).toStringAsFixed(1)} percent').join('. ')}',
              child: SizedBox(
                width: 210,
                height: 210,
                child: CustomPaint(painter: _PiePainter(slices, total)),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            total == 0 ? empty : '${_time(total)} total logged',
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Color(0xFF73727C),
            ),
          ),
          const SizedBox(height: 14),
          for (final slice in slices)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: slice.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      slice.label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        total == 0
                            ? '—'
                            : '${(slice.seconds / total * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        _time(slice.seconds),
                        style: const TextStyle(
                          color: Color(0xFF73727C),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PiePainter extends CustomPainter {
  _PiePainter(this.slices, this.total);
  final List<_Slice> slices;
  final int total;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2 - 4;
    final rect = Rect.fromCircle(center: center, radius: radius);
    if (total == 0) {
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = const Color(0xFFE8E8E2),
      );
      return;
    }
    var start = -pi / 2;
    for (final slice in slices) {
      if (slice.seconds <= 0) continue;
      final fraction = slice.seconds / total;
      final sweep = fraction * 2 * pi;
      canvas.drawArc(rect, start, sweep, true, Paint()..color = slice.color);
      if (fraction >= .08) {
        final mid = start + sweep / 2;
        final at = fraction == 1
            ? center
            : center + Offset(cos(mid), sin(mid)) * radius * .62;
        final label = TextPainter(
          text: TextSpan(
            text: '${(fraction * 100).toStringAsFixed(1)}%',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, at - Offset(label.width / 2, label.height / 2));
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PiePainter oldDelegate) =>
      total != oldDelegate.total ||
      slices.asMap().entries.any(
        (e) => e.value.seconds != oldDelegate.slices[e.key].seconds,
      );
}

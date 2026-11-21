import 'cloud_cache_types.dart';
import 'model.dart';

bool cloudJsonEqual(Object? first, Object? second) {
  if (identical(first, second)) return true;
  if (first is Map && second is Map) {
    return first.length == second.length &&
        first.keys.every(
          (key) =>
              second.containsKey(key) &&
              cloudJsonEqual(first[key], second[key]),
        );
  }
  if (first is List && second is List) {
    return first.length == second.length &&
        List.generate(
          first.length,
          (index) => index,
        ).every((index) => cloudJsonEqual(first[index], second[index]));
  }
  return first == second;
}

class CloudMergeResult {
  const CloudMergeResult(this.payload, this.conflicts);
  final CloudJson? payload;
  final List<String> conflicts;
}

final _missing = Object();

/// Merge only changes whose intent is unambiguous. Timers are never resolved by
/// last-write-wins timestamps, maximum end times, or adding overlapping work.
CloudMergeResult mergeCloudPayload(
  CloudJson base,
  CloudJson local,
  CloudJson remote,
) {
  if (cloudJsonEqual(local, remote)) {
    return CloudMergeResult(copyCloudJson(local), const []);
  }
  if (cloudJsonEqual(base, local)) {
    return CloudMergeResult(copyCloudJson(remote), const []);
  }
  if (cloudJsonEqual(base, remote)) {
    return CloudMergeResult(copyCloudJson(local), const []);
  }
  final conflicts = <String>[];

  Object? merge(Object? before, Object? here, Object? there, String path) {
    if (cloudJsonEqual(here, there)) return here;
    if (cloudJsonEqual(before, here)) return there;
    if (cloudJsonEqual(before, there)) return here;
    if (path == 'lastWidgetRequestId') return here;
    if (['childNames', 'childOne', 'childTwo'].contains(path)) return there;
    if (path == 'version' && here is num && there is num) {
      return here > there ? here : there;
    }
    if (before is Map && here is Map && there is Map) {
      final merged = <String, dynamic>{};
      for (final key in {...before.keys, ...here.keys, ...there.keys}) {
        final next = merge(
          before.containsKey(key) ? before[key] : _missing,
          here.containsKey(key) ? here[key] : _missing,
          there.containsKey(key) ? there[key] : _missing,
          path.isEmpty ? '$key' : '$path.$key',
        );
        if (!identical(next, _missing)) merged[key as String] = next;
      }
      return merged;
    }
    if (before is List &&
        here is List &&
        there is List &&
        (path == 'shifts' ||
            path == 'sessions' ||
            path.endsWith('.interruptions'))) {
      String key(dynamic value) {
        if (value is! Map) throw const FormatException('Invalid record list.');
        if (path == 'shifts') return '${value['id']}';
        if (path == 'sessions') {
          return '${value['start']}|${value['shiftId']}|${value['kind']}|${value['baby']}';
        }
        return '${value['start']}';
      }

      Map<String, dynamic> index(List values) {
        final result = <String, dynamic>{};
        for (final value in values) {
          final id = key(value);
          if (result.containsKey(id)) {
            throw const FormatException('Duplicate record key.');
          }
          result[id] = value;
        }
        return result;
      }

      try {
        final old = index(before), left = index(here), right = index(there);
        final merged = <dynamic>[];
        for (final id in {...old.keys, ...left.keys, ...right.keys}) {
          final next = merge(
            old[id] ?? _missing,
            left[id] ?? _missing,
            right[id] ?? _missing,
            '$path[$id]',
          );
          if (!identical(next, _missing)) merged.add(next);
        }
        merged.sort(
          (a, b) => (a['start'] as String).compareTo(b['start'] as String),
        );
        return merged;
      } on FormatException {
        conflicts.add(path);
        return here;
      }
    }
    conflicts.add(path.isEmpty ? 'records' : path);
    return here;
  }

  final value = merge(base, local, remote, '') as CloudJson;
  if (conflicts.isNotEmpty) return CloudMergeResult(null, conflicts);
  try {
    final state = RelayState.fromJson(value);
    var active = 0;
    DateTime? previousEnd;
    for (final session in state.sessions) {
      if (previousEnd != null && session.start.isBefore(previousEnd)) {
        conflicts.add('overlapping sessions');
      }
      if (active > 0) conflicts.add('multiple or overlapping active timers');
      if (session.end == null) active++;
      if (session.end != null && session.end!.isBefore(session.start)) {
        conflicts.add('session end time');
      }
      previousEnd = session.end;
      DateTime? lastInterruptionEnd;
      var openInterruptions = 0;
      for (final interruption in session.interruptions) {
        if (openInterruptions > 0 ||
            interruption.start.isBefore(session.start) ||
            (lastInterruptionEnd != null &&
                interruption.start.isBefore(lastInterruptionEnd)) ||
            (interruption.end != null &&
                interruption.end!.isBefore(interruption.start)) ||
            (session.end != null &&
                (interruption.end == null ||
                    interruption.end!.isAfter(session.end!)))) {
          conflicts.add('interruption times');
        }
        if (interruption.end == null) openInterruptions++;
        lastInterruptionEnd = interruption.end;
      }
    }
    for (var i = 1; i < state.shifts.length; i++) {
      if (state.shifts[i].start.isBefore(state.shifts[i - 1].end)) {
        conflicts.add('overlapping schedule blocks');
      }
    }
  } catch (_) {
    conflicts.add('record format');
  }
  return CloudMergeResult(
    conflicts.isEmpty ? copyCloudJson(value) : null,
    conflicts,
  );
}

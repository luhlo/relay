import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Rating invitations are device preferences, never shared household records.
/// Callers may use separate scopes. A manual rating suppresses future invitations;
/// Google Play does not report whether a review was actually submitted.
class RelayRatingPreferences {
  RelayRatingPreferences(this.preferences, {this.scope = 'local'});

  static const minimumCompletions = 3;
  static const minimumExperience = Duration(days: 3);
  static const reminderDelay = Duration(days: 7);

  final SharedPreferences preferences;
  final String scope;

  String get storageKey => 'relay.rating.v1.${Uri.encodeComponent(scope)}';

  bool get stopped => _read().stopped;

  /// Call only after saving a manually ended session of at least one minute.
  /// The caller also excludes automatic stops and checks that no timer is active.
  /// A completion token prevents an immediately retried action being counted twice.
  Future<bool> recordCompletion(
    DateTime now, {
    required String completionId,
  }) async {
    if (completionId.isEmpty) {
      throw ArgumentError.value(
        completionId,
        'completionId',
        'Cannot be empty',
      );
    }
    final state = _read();
    if (state.stopped || state.lastCompletionId == completionId) return false;
    final next = _RatingState(
      completedCount: state.completedCount + 1,
      firstCompletedAtMillis:
          state.firstCompletedAtMillis ?? now.millisecondsSinceEpoch,
      lastCompletionId: completionId,
      nextPromptAtMillis: state.nextPromptAtMillis,
    );
    await _write(next);
    return next.completedCount >= minimumCompletions &&
        now.millisecondsSinceEpoch - next.firstCompletedAtMillis! >=
            minimumExperience.inMilliseconds &&
        (next.nextPromptAtMillis == null ||
            now.millisecondsSinceEpoch >= next.nextPromptAtMillis!);
  }

  Future<void> remindLater(DateTime now) => _snooze(now);

  /// Persist before presenting a dialog, so a dismissal, restart or reentrant
  /// completion cannot immediately produce another invitation.
  Future<void> reservePrompt(DateTime now) => _snooze(now);

  Future<void> _snooze(DateTime now) async {
    final state = _read();
    await _write(
      state.copyWith(
        nextPromptAtMillis: now.add(reminderDelay).millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> stopAsking() async {
    await _write(_read().copyWith(stopped: true));
  }

  _RatingState _read() {
    try {
      final raw = preferences.getString(storageKey);
      if (raw == null) return const _RatingState();
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return const _RatingState();
      final count = json['completedCount'];
      final first = json['firstCompletedAtMillis'];
      final last = json['lastCompletionId'];
      final next = json['nextPromptAtMillis'];
      final stopped = json['stopped'];
      if (count is! int ||
          count < 0 ||
          (first != null && first is! int) ||
          (last != null && last is! String) ||
          (next != null && next is! int) ||
          stopped is! bool ||
          (count > 0 && (first == null || last == null))) {
        return const _RatingState();
      }
      return _RatingState(
        completedCount: count,
        firstCompletedAtMillis: first as int?,
        lastCompletionId: last as String?,
        nextPromptAtMillis: next as int?,
        stopped: stopped,
      );
    } catch (_) {
      // A damaged preference must never prevent saving or using a timer.
      return const _RatingState();
    }
  }

  Future<void> _write(_RatingState state) async {
    if (!await preferences.setString(storageKey, jsonEncode(state.toJson()))) {
      throw StateError('Could not save your rating preference.');
    }
  }
}

class _RatingState {
  const _RatingState({
    this.completedCount = 0,
    this.firstCompletedAtMillis,
    this.lastCompletionId,
    this.nextPromptAtMillis,
    this.stopped = false,
  });

  final int completedCount;
  final int? firstCompletedAtMillis;
  final String? lastCompletionId;
  final int? nextPromptAtMillis;
  final bool stopped;

  _RatingState copyWith({int? nextPromptAtMillis, bool? stopped}) =>
      _RatingState(
        completedCount: completedCount,
        firstCompletedAtMillis: firstCompletedAtMillis,
        lastCompletionId: lastCompletionId,
        nextPromptAtMillis: nextPromptAtMillis ?? this.nextPromptAtMillis,
        stopped: stopped ?? this.stopped,
      );

  Map<String, dynamic> toJson() => {
    'completedCount': completedCount,
    'firstCompletedAtMillis': firstCompletedAtMillis,
    'lastCompletionId': lastCompletionId,
    'nextPromptAtMillis': nextPromptAtMillis,
    'stopped': stopped,
  };
}

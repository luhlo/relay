import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'model.dart';
import 'timer_guard.dart';

/// Foreground snapshot bridge. Widget actions are saved by a headless engine.
class RelayHomeWidget {
  RelayHomeWidget({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('app.relay.relay/widget');

  static final instance = RelayHomeWidget();
  final MethodChannel _channel;
  final _updates = StreamController<void>.broadcast();
  bool _listening = false;

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Stream<void> get updates {
    if (supported && !_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'stateChanged') _updates.add(null);
      });
    }
    return _updates.stream;
  }

  Future<String?> currentContext() async {
    if (!supported) return null;
    return _channel.invokeMethod<String>('context');
  }

  Future<void> sync(RelayState state, String context, DateTime now) async {
    if (!supported) return;
    await _channel.invokeMethod<void>(
      'update',
      widgetSnapshot(state, context, now),
    );
  }

  Future<void> clear() async {
    if (supported) await _channel.invokeMethod<void>('clear');
  }
}

Map<String, dynamic> widgetSnapshot(
  RelayState state,
  String context,
  DateTime now,
) {
  final active = state.active;
  final interrupted = active?.interruption != null;
  final baby = active?.baby;
  final interruptionSeconds = interrupted
      ? now
            .difference(active!.interruption!.start)
            .inSeconds
            .clamp(0, 0x7FFFFFFF)
      : 0;
  return {
    'context': context,
    'requestId': state.lastWidgetRequestId,
    'colors': state.widgetColors.toJson(),
    'guard': timerGuardSnapshot(state, now),
    'message': active == null && state.sessions.isNotEmpty
        ? state.sessions.last.autoStopReason
        : null,
    'status': active == null
        ? 'idle'
        : active.kind == ShiftKind.point
        ? 'baby'
        : interrupted
        ? 'interrupted'
        : 'work',
    'childNames': state.childNames,
    'elapsedSeconds': interrupted
        ? interruptionSeconds
        : state.sessionSeconds(now),
    'workSeconds': state.sessionSeconds(now),
    'running': active != null,
    'sessionStart': active?.start.toUtc().toIso8601String(),
    'subtitle': active == null
        ? 'Choose your time'
        : active.kind == ShiftKind.point
        ? baby == null
              ? 'Baby Time'
              : baby == Baby.both
              ? 'All babies'
              : state.babyName(baby)
        : interrupted
        ? 'Interruption time'
        : 'Uninterrupted work',
  };
}

/// Reject controls rendered for a different account or an old session rather
/// than toggling or ending a more recent session when the widget is stale.
void applyWidgetAction(
  RelayState state,
  Map<String, dynamic> action,
  String context,
  DateTime now,
) {
  if (action['context'] != context) {
    throw ArgumentError(
      'This widget belongs to another account. Reopen Relay.',
    );
  }
  final kind = action['action'];
  if (kind == 'interruption' || kind == 'end') {
    final current = widgetSnapshot(state, context, now);
    if (current['sessionStart'] != action['sessionStart'] ||
        current['status'] != action['expectedStatus']) {
      throw ArgumentError('Your shift changed. The widget has been refreshed.');
    }
  }
  switch (kind) {
    case 'work':
      state.start(ShiftKind.focus, now);
    case 'baby':
      final index = action['babyIndex'];
      if (index is! int ||
          index < -1 ||
          index >= state.childNames.length ||
          (index == -1 && state.childNames.length < 2)) {
        throw ArgumentError('Choose a child from the refreshed widget.');
      }
      state.start(
        ShiftKind.point,
        now,
        baby: index == -1 ? Baby.both : childChoices[index],
      );
    case 'interruption':
      if (state.active?.kind != ShiftKind.focus) {
        throw ArgumentError(
          'Start Work Time before recording an interruption.',
        );
      }
      state.toggleInterruption(now);
    case 'end':
      state.finish(now);
    default:
      throw ArgumentError('Open Relay to choose your time.');
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'model.dart';

/// Android launches the normal app for writes so local/cloud saves use the
/// same authentication, revision checks, and rollback as the main controls.
class RelayHomeWidget {
  RelayHomeWidget({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('app.relay.relay/widget');

  static final instance = RelayHomeWidget();
  final MethodChannel _channel;
  final _actions = StreamController<void>.broadcast();
  bool _listening = false;

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Stream<void> get actions {
    if (supported && !_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'actionAvailable') _actions.add(null);
      });
    }
    return _actions.stream;
  }

  Future<String?> pendingContext() async {
    if (!supported) return null;
    return _channel.invokeMethod<String>('pendingContext');
  }

  Future<Map<String, dynamic>?> takeAction() async {
    if (!supported) return null;
    final value = await _channel.invokeMapMethod<String, dynamic>('takeAction');
    return value;
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
  return {
    'context': context,
    'status': active == null
        ? 'idle'
        : active.kind == ShiftKind.point
        ? 'baby'
        : interrupted
        ? 'interrupted'
        : 'work',
    'childNames': state.childNames,
    'elapsedSeconds': state.sessionSeconds(now),
    'running': active != null && !interrupted,
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
        ? 'Work time paused'
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

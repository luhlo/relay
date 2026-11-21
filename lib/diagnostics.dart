import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support_service.dart';

const _diagnosticsEnabledKey = 'relay.diagnostics.enabled.v1';
const _diagnosticsQueueKey = 'relay.diagnostics.queue.v1';
const diagnosticCodes = {
  'FlutterError',
  'StateError',
  'TypeError',
  'RangeError',
  'ArgumentError',
  'AssertionError',
  'FormatException',
  'TimeoutException',
  'PlatformException',
  'MissingPluginException',
  'PostgrestException',
  'AuthException',
  'SocketException',
  'Exception',
  'UnknownError',
  'SlowOperation',
  'SlowFrame',
};
const diagnosticOperations = {
  'load_records',
  'save_records',
  'launch',
  'render',
};
const diagnosticPlatforms = {
  'web',
  'android',
  'ios',
  'linux',
  'macos',
  'windows',
  'fuchsia',
  'unknown',
};

bool _isSafeQueuedReport(Map<String, dynamic> report) {
  const keys = {
    'eventType',
    'code',
    'operation',
    'durationMs',
    'appVersion',
    'platform',
    'fingerprint',
    'frames',
  };
  final frames = report['frames'];
  final duration = report['durationMs'];
  return report.keys.every(keys.contains) &&
      {
        'flutter_error',
        'unhandled_error',
        'slow_operation',
        'slow_frame',
      }.contains(report['eventType']) &&
      diagnosticCodes.contains(report['code']) &&
      (!report.containsKey('operation') ||
          diagnosticOperations.contains(report['operation'])) &&
      (duration == null ||
          duration is int && duration >= 0 && duration <= 120000) &&
      report['appVersion'] is String &&
      RegExp(r'^\d+\.\d+\.\d+\+\d+$')
          .hasMatch(report['appVersion'] as String) &&
      diagnosticPlatforms.contains(report['platform']) &&
      report['fingerprint'] is String &&
      RegExp(r'^[a-f0-9]{8}$').hasMatch(report['fingerprint'] as String) &&
      frames is List &&
      frames.length <= 10 &&
      frames.every(
        (frame) =>
            frame is String &&
            RegExp(r'^package:relay/[A-Za-z0-9_./-]+\.dart:\d+:\d+$')
                .hasMatch(frame),
      );
}

String get diagnosticPlatform => kIsWeb ? 'web' : defaultTargetPlatform.name;

/// Derive a technical grouping key without serializing exception messages,
/// local paths, auth tokens, browser URLs, account data, or timer records.
Map<String, dynamic> diagnosticReport({
  required String eventType,
  Object? error,
  StackTrace? stack,
  String? operation,
  int? durationMs,
}) {
  var code =
      error?.runtimeType.toString() ??
      (eventType == 'slow_frame' ? 'SlowFrame' : 'SlowOperation');
  if (code == '_TypeError') code = 'TypeError';
  if (!diagnosticCodes.contains(code)) code = 'UnknownError';
  final frames = RegExp(r'package:relay/[A-Za-z0-9_./-]+\.dart:\d+:\d+')
      .allMatches(stack?.toString() ?? '')
      .map((match) => match.group(0)!)
      .take(10)
      .toList();
  final safeOperation = diagnosticOperations.contains(operation)
      ? operation
      : null;
  final signature =
      '$eventType|$code|${safeOperation ?? ''}|${frames.join('|')}';
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(signature)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return {
    'eventType': eventType,
    'code': code,
    'operation': ?safeOperation,
    if (durationMs != null) 'durationMs': durationMs.clamp(0, 120000),
    'appVersion': relaySupportVersion,
    'platform': diagnosticPlatform,
    'fingerprint': hash.toRadixString(16).padLeft(8, '0'),
    'frames': frames,
  };
}

class RelayDiagnostics extends ChangeNotifier {
  RelayDiagnostics._() : send = RelaySupportService.instance.sendDiagnostic;
  RelayDiagnostics.forTesting({required this.send});
  static final instance = RelayDiagnostics._();
  final Future<void> Function(Map<String, dynamic>) send;
  SharedPreferences? _preferences;
  final List<Map<String, dynamic>> _queue = [];
  final Map<String, DateTime> _recent = {};
  bool _enabled = false, _sending = false, _initialized = false;
  bool _handlersInstalled = false;
  int _sentThisLaunch = 0;
  Timer? _retry;
  Future<void> _writes = Future.value();
  bool get enabled => _enabled;
  int get pendingCount => _queue.length;

  Future<void> initialize({bool installHandlers = true}) async {
    if (!_initialized) {
      _preferences = await SharedPreferences.getInstance();
      _enabled = _preferences!.getBool(_diagnosticsEnabledKey) ?? false;
      // An offline report can survive an app restart, but only if every field
      // still satisfies the current privacy allowlist.
      if (_enabled) {
        try {
          final raw = _preferences!.getString(_diagnosticsQueueKey);
          final saved = raw == null ? null : jsonDecode(raw);
          if (saved is List) {
            _queue.addAll(
              saved
                  .whereType<Map>()
                  .map((value) => Map<String, dynamic>.from(value))
                  .where(_isSafeQueuedReport)
                  .take(20),
            );
          }
        } catch (_) {
          _queue.clear();
        }
      }
      await _persistQueue();
      _initialized = true;
    }
    if (installHandlers && !_handlersInstalled) {
      _handlersInstalled = true;
      final previousFlutterHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        captureError(
          details.exception,
          details.stack,
          eventType: 'flutter_error',
        );
        (previousFlutterHandler ?? FlutterError.presentError)(details);
      };
      final previousPlatformHandler = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (error, stack) {
        captureError(error, stack, eventType: 'unhandled_error');
        return previousPlatformHandler?.call(error, stack) ?? false;
      };
      SchedulerBinding.instance.addTimingsCallback(_observeFrames);
    }
    _retry ??= Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(flush());
    });
    unawaited(flush());
  }

  Future<void> setEnabled(bool value) async {
    if (!_initialized) {
      await initialize(installHandlers: identical(this, instance));
    }
    if (!await _preferences!.setBool(_diagnosticsEnabledKey, value)) {
      throw const RelaySupportException('Could not save this preference.');
    }
    _enabled = value;
    if (!value) {
      _queue.clear();
      _recent.clear();
      await _persistQueue();
    }
    notifyListeners();
  }

  void captureError(
    Object error,
    StackTrace? stack, {
    String eventType = 'flutter_error',
    String? operation,
  }) => _enqueue(
    diagnosticReport(
      eventType: eventType,
      error: error,
      stack: stack,
      operation: operation,
    ),
  );

  void recordSlowOperation(String operation, Duration duration) {
    if (duration.inMilliseconds < 2000 ||
        !diagnosticOperations.contains(operation)) {
      return;
    }
    _enqueue(
      diagnosticReport(
        eventType: 'slow_operation',
        operation: operation,
        durationMs: duration.inMilliseconds,
      ),
    );
  }

  void _observeFrames(List<FrameTiming> timings) {
    if (!_enabled || timings.isEmpty) return;
    final duration = timings
        .map((timing) => timing.totalSpan)
        .reduce((a, b) => a > b ? a : b);
    if (duration.inMilliseconds < 1000) return;
    _enqueue(
      diagnosticReport(
        eventType: 'slow_frame',
        operation: 'render',
        durationMs: duration.inMilliseconds,
      ),
    );
  }

  void _enqueue(Map<String, dynamic> report) {
    if (!_enabled || !_initialized || _sentThisLaunch >= 10) return;
    final fingerprint = report['fingerprint'] as String;
    final last = _recent[fingerprint];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(minutes: 10)) {
      return;
    }
    _recent[fingerprint] = now;
    _queue.add(report);
    if (_queue.length > 20) _queue.removeAt(0);
    unawaited(_persistQueue());
    unawaited(flush());
  }

  Future<void> _persistQueue() {
    _writes = _writes
        .then((_) async {
          if (_preferences == null) return;
          if (_queue.isEmpty || !_enabled) {
            await _preferences!.remove(_diagnosticsQueueKey);
          } else {
            await _preferences!.setString(
              _diagnosticsQueueKey,
              jsonEncode(_queue),
            );
          }
        })
        .catchError((Object _) {
          // Monitoring cannot prevent a timer from saving or create error loops.
        });
    return _writes;
  }

  Future<void> flush() async {
    if (!_enabled || _sending || _queue.isEmpty || _sentThisLaunch >= 10) {
      return;
    }
    _sending = true;
    try {
      while (_enabled && _queue.isNotEmpty && _sentThisLaunch < 10) {
        final report = _queue.first;
        try {
          await send(report);
        } catch (_) {
          break;
        }
        _sentThisLaunch++;
        if (_queue.isNotEmpty && identical(_queue.first, report)) {
          _queue.removeAt(0);
        }
        await _persistQueue();
      }
    } finally {
      _sending = false;
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    if (_handlersInstalled) {
      SchedulerBinding.instance.removeTimingsCallback(_observeFrames);
    }
    super.dispose();
  }
}

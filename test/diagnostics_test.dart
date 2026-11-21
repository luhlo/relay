import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:relay/diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'technical report drops messages, local paths, URLs and user records',
    () {
      final report = diagnosticReport(
        eventType: 'flutter_error',
        error: StateError('Chloe owner@example.com token=secret'),
        stack: StackTrace.fromString(
          '#0 fail (package:relay/main.dart:211:9)\n'
          '#1 /Users/owner@example.com/family/Chloe.dart:10:2\n'
          '#2 https://relay.luhlo.com/?access_token=secret\n',
        ),
      );
      final encoded = jsonEncode(report);
      expect(report['code'], 'StateError');
      expect(report['frames'], ['package:relay/main.dart:211:9']);
      for (final secret in [
        'Chloe',
        'owner@example.com',
        'token=',
        '/Users/',
        'https://',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
    },
  );

  test('report fingerprint groups code paths instead of user error text', () {
    final first = diagnosticReport(
      eventType: 'flutter_error',
      error: StateError('Alice'),
    );
    final second = diagnosticReport(
      eventType: 'flutter_error',
      error: StateError('Bob'),
    );
    expect(first['fingerprint'], second['fingerprint']);
  });

  test(
    'monitoring is off until enabled and duplicate errors are bounded',
    () async {
      final sent = <Map<String, dynamic>>[];
      final diagnostics = RelayDiagnostics.forTesting(
        send: (report) async => sent.add(report),
      );
      await diagnostics.initialize(installHandlers: false);
      addTearDown(diagnostics.dispose);
      expect(diagnostics.enabled, isFalse);
      diagnostics.captureError(StateError('private'), StackTrace.empty);
      await diagnostics.flush();
      expect(sent, isEmpty);
      await diagnostics.setEnabled(true);
      diagnostics.captureError(StateError('private'), StackTrace.empty);
      diagnostics.captureError(StateError('other private'), StackTrace.empty);
      await Future<void>.delayed(Duration.zero);
      await diagnostics.flush();
      expect(sent, hasLength(1));
    },
  );

  test('offline technical report survives restart and opt-out clears unsent reports', () async {
    final first = RelayDiagnostics.forTesting(
      send: (_) async => throw StateError('offline'),
    );
    await first.initialize(installHandlers: false);
    await first.setEnabled(true);
    first.captureError(StateError('private'), StackTrace.empty);
    await Future<void>.delayed(Duration.zero);
    await first.flush();
    expect(first.pendingCount, 1);
    first.dispose();
    final second = RelayDiagnostics.forTesting(
      send: (_) async => throw StateError('offline'),
    );
    await second.initialize(installHandlers: false);
    addTearDown(second.dispose);
    expect(second.pendingCount, 1);
    await second.setEnabled(false);
    expect(second.pendingCount, 0);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('relay.diagnostics.queue.v1'), isNull);
  });

  test('restored queues cannot introduce personal fields', () async {
    final report = diagnosticReport(
      eventType: 'flutter_error',
      error: StateError('ignored'),
    );
    SharedPreferences.setMockInitialValues({
      'relay.diagnostics.enabled.v1': true,
      'relay.diagnostics.queue.v1': jsonEncode([
        {...report, 'message': 'Chloe owner@example.com'},
        report,
      ]),
    });
    final sent = <Map<String, dynamic>>[];
    final diagnostics = RelayDiagnostics.forTesting(
      send: (report) async => sent.add(report),
    );
    await diagnostics.initialize(installHandlers: false);
    addTearDown(diagnostics.dispose);
    await Future<void>.delayed(Duration.zero);
    await diagnostics.flush();
    expect(sent, hasLength(1));
    expect(sent.single, isNot(contains('message')));
  });

  test(
    'only slow allowlisted operations generate performance reports',
    () async {
      final sent = <Map<String, dynamic>>[];
      final diagnostics = RelayDiagnostics.forTesting(
        send: (report) async => sent.add(report),
      );
      await diagnostics.initialize(installHandlers: false);
      addTearDown(diagnostics.dispose);
      await diagnostics.setEnabled(true);
      diagnostics.recordSlowOperation(
        'load_records',
        const Duration(milliseconds: 1900),
      );
      diagnostics.recordSlowOperation('Chloe', const Duration(seconds: 5));
      diagnostics.recordSlowOperation(
        'save_records',
        const Duration(seconds: 3),
      );
      await Future<void>.delayed(Duration.zero);
      await diagnostics.flush();
      expect(sent, hasLength(1));
      expect(sent.single['operation'], 'save_records');
      expect(sent.single['durationMs'], 3000);
    },
  );
}

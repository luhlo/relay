import 'package:flutter_test/flutter_test.dart';
import 'package:relay/support_service.dart';

void main() {
  test(
    'feedback sends only explicitly entered content and public app context',
    () async {
      Map<String, dynamic>? payload;
      final service = RelaySupportService.forTesting((body) async {
        payload = body;
        return {'ok': true};
      });
      await service.sendFeedback(
        category: 'idea',
        message: '  A clearer timer label  ',
        platform: 'web',
      );
      expect(payload, {
        'action': 'feedback',
        'category': 'idea',
        'message': 'A clearer timer label',
        'appVersion': relaySupportVersion,
        'platform': 'web',
      });
    },
  );

  test(
    'feedback success requires an explicit server acknowledgement',
    () async {
      final service = RelaySupportService.forTesting((_) async => {});
      await expectLater(
        service.sendFeedback(category: 'idea', message: 'A useful feature'),
        throwsA(isA<RelaySupportException>()),
      );
    },
  );

  test(
    'dashboard access is confirmed by the server and fails closed',
    () async {
      final service = RelaySupportService.forTesting(
        (_) async => throw StateError('offline'),
      );
      expect(await service.canViewReports(), isFalse);
      final allowed = RelaySupportService.forTesting(
        (_) async => {'canViewReports': true},
      );
      expect(await allowed.canViewReports(), isTrue);
    },
  );
}

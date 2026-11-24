import 'package:supabase_flutter/supabase_flutter.dart';

const relaySupportVersion = '1.19.0+24';

class RelaySupportException implements Exception {
  const RelaySupportException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef SupportRequest = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> body,
);

/// Only this API can submit support reports or read the owner's dashboard.
/// Authorization is enforced again by the server, never by a client email test.
class RelaySupportService {
  RelaySupportService.forTesting(SupportRequest request) : _request = request;
  RelaySupportService._() : _request = _invoke;
  static final instance = RelaySupportService._();
  final SupportRequest _request;

  static Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    try {
      final response = await Supabase.instance.client.functions
          .invoke('relay-support', body: body)
          .timeout(const Duration(seconds: 12));
      if (response.status < 200 ||
          response.status >= 300 ||
          response.data is! Map) {
        throw const RelaySupportException(
          'Could not confirm your report. Please try again.',
        );
      }
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      throw RelaySupportException(
        error.status == 429
            ? 'Too many reports were sent recently. Please try again later.'
            : error.status == 403 || error.status == 401
            ? 'This dashboard is available only to the authorized support account.'
            : 'Could not send your report. Check your connection and try again.',
      );
    } on RelaySupportException {
      rethrow;
    } catch (_) {
      throw const RelaySupportException(
        'Could not connect. Your report has not been confirmed. Please try again.',
      );
    }
  }

  Future<void> sendFeedback({
    required String category,
    required String message,
    String? replyEmail,
    String platform = 'unknown',
  }) async {
    final reply = replyEmail?.trim();
    final result = await _request({
      'action': 'feedback',
      'category': category,
      'message': message.trim(),
      if (reply != null && reply.isNotEmpty) 'replyEmail': reply,
      'appVersion': relaySupportVersion,
      'platform': platform,
    });
    _requireAcknowledgement(result);
  }

  Future<void> sendDiagnostic(Map<String, dynamic> report) async {
    final result = await _request({'action': 'diagnostic', ...report});
    _requireAcknowledgement(result);
  }

  void _requireAcknowledgement(Map<String, dynamic> result) {
    if (result['ok'] != true) {
      throw const RelaySupportException(
        'The report was not confirmed. Please try again.',
      );
    }
  }

  Future<bool> canViewReports() async {
    try {
      return (await _request({'action': 'capabilities'}))['canViewReports'] ==
          true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> dashboard() => _request({'action': 'dashboard'});
}

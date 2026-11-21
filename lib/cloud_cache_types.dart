import 'dart:async';
import 'dart:convert';

typedef CloudJson = Map<String, dynamic>;
CloudJson copyCloudJson(CloudJson value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

/// The callback runs inside one storage transaction, including in other tabs
/// and Flutter engines. It must stay synchronous and never perform network I/O.
abstract class CloudCache {
  Future<CloudJson?> read(String userId);
  Future<CloudJson?> update(
    String userId,
    CloudJson? Function(CloudJson? current) update,
  );
  Future<void> remove(String userId) => update(userId, (_) => null);
}

/// Shared by store instances in tests to exercise foreground/headless races.
class MemoryCloudCache extends CloudCache {
  final Map<String, CloudJson> _values = {};
  Future<void> _tail = Future.value();

  @override
  Future<CloudJson?> read(String userId) async {
    await _tail;
    final value = _values[userId];
    return value == null ? null : copyCloudJson(value);
  }

  @override
  Future<CloudJson?> update(
    String userId,
    CloudJson? Function(CloudJson? current) update,
  ) {
    final result = Completer<CloudJson?>();
    _tail = _tail.then((_) {
      try {
        final prior = _values[userId];
        final next = update(prior == null ? null : copyCloudJson(prior));
        if (next == null) {
          _values.remove(userId);
        } else {
          _values[userId] = copyCloudJson(next);
        }
        result.complete(next == null ? null : copyCloudJson(next));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }
}

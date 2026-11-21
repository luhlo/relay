import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'cloud_cache_types.dart';

CloudCache createCloudCache() => _IndexedCloudCache();

class _IndexedCloudCache extends CloudCache {
  Future<web.IDBDatabase>? _database;

  Future<web.IDBDatabase> _open() => _database ??= _initialize();
  Future<web.IDBDatabase> _initialize() {
    final result = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open('relay-cloud-records', 1);
    request.onupgradeneeded = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      database.createObjectStore('accounts');
    }).toJS;
    request.onsuccess = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      database.onversionchange = ((web.Event event) => database.close()).toJS;
      if (!result.isCompleted) result.complete(database);
    }).toJS;
    request.onerror = ((web.Event event) {
      if (!result.isCompleted) {
        result.completeError(StateError('Browser storage is unavailable.'));
      }
      _database = null;
    }).toJS;
    request.onblocked = ((web.Event event) {
      if (!result.isCompleted) {
        result.completeError(
          StateError('Close other Relay tabs and try again.'),
        );
      }
      _database = null;
    }).toJS;
    return result.future;
  }

  CloudJson? _decode(JSAny? raw) {
    final value = raw.dartify();
    return value == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(value as String) as Map);
  }

  @override
  Future<CloudJson?> read(String userId) async {
    final database = await _open();
    final transaction = database.transaction('accounts'.toJS, 'readonly');
    final request = transaction.objectStore('accounts').get(userId.toJS);
    final result = Completer<CloudJson?>();
    request.onsuccess = ((web.Event event) {
      try {
        result.complete(_decode(request.result));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }).toJS;
    request.onerror = ((web.Event event) {
      if (!result.isCompleted) {
        result.completeError(
          StateError('Could not read this device’s saved account records.'),
        );
      }
    }).toJS;
    return result.future;
  }

  @override
  Future<CloudJson?> update(
    String userId,
    CloudJson? Function(CloudJson? current) update,
  ) async {
    final database = await _open();
    final transaction = database.transaction(
      'accounts'.toJS,
      'readwrite',
      web.IDBTransactionOptions(durability: 'strict'),
    );
    final store = transaction.objectStore('accounts');
    final request = store.get(userId.toJS);
    final result = Completer<CloudJson?>();
    CloudJson? next;
    Object? callbackError;
    StackTrace? callbackStack;
    transaction.oncomplete = ((web.Event event) {
      if (!result.isCompleted) result.complete(next);
    }).toJS;
    void fail() {
      if (!result.isCompleted) {
        result.completeError(
          callbackError ??
              StateError(
                'Could not save on this browser. Storage may be full or unavailable.',
              ),
          callbackStack,
        );
      }
    }

    transaction.onerror = ((web.Event event) => fail()).toJS;
    transaction.onabort = ((web.Event event) => fail()).toJS;
    request.onsuccess = ((web.Event event) {
      try {
        // This callback and put/delete run synchronously in the SAME IndexedDB
        // readwrite transaction. Tabs cannot pass a stale read/write check.
        next = update(_decode(request.result));
        if (next == null) {
          store.delete(userId.toJS);
        } else {
          store.put(jsonEncode(next).toJS, userId.toJS);
        }
      } catch (error, stack) {
        callbackError = error;
        callbackStack = stack;
        transaction.abort();
      }
    }).toJS;
    return result.future;
  }
}

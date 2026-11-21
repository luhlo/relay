import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/storage.dart' show LocalSaveConflict;
import 'package:relay/cloud_cache_native.dart'
    show createSqliteCloudCacheForTesting;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late Database database;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'relay-cloud-cache-test-',
    );
    path = '${directory.path}/isolated.db';
    database = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, version) async {
          await database.execute(
            'CREATE TABLE app_state (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)',
          );
          await database.insert('app_state', {
            'id': 1,
            'payload': 'untouched-device-only-fixture',
          });
        },
      ),
    );
  });
  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
    await directory.delete(recursive: true);
  });

  test('actual SQLite transactions serialize account mutations from independent cache owners', () async {
    final foreground = createSqliteCloudCacheForTesting(database);
    final widget = createSqliteCloudCacheForTesting(database);
    await foreground.update('owner', (_) => {'count': 0});
    await Future.wait([
      for (var i = 0; i < 20; i++)
        (i.isEven ? foreground : widget).update(
          'owner',
          (current) => {'count': (current!['count'] as int) + 1},
        ),
    ]);
    expect((await foreground.read('owner'))!['count'], 20);
    expect(
      (await database.query('app_state')).single['payload'],
      'untouched-device-only-fixture',
    );
    expect(await database.getVersion(), 1);
  });

  test('separate SQLite connections reject a stale foreground copy after widget commit', () async {
    final secondDb = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, singleInstance: false),
    );
    addTearDown(secondDb.close);
    final first = createSqliteCloudCacheForTesting(database);
    final second = createSqliteCloudCacheForTesting(secondDb);
    await first.update('owner', (_) => {'generation': 0});
    final old = await first.read('owner');
    await second.update(
      'owner',
      (current) => {'generation': (current!['generation'] as int) + 1},
    );
    await expectLater(
      first.update('owner', (current) {
        if (current!['generation'] != old!['generation']) {
          throw const LocalSaveConflict();
        }
        return {'generation': 99};
      }),
      throwsA(isA<LocalSaveConflict>()),
    );
    expect((await second.read('owner'))!['generation'], 1);
  });

  test(
    'failed SQLite mutation rolls back before a success acknowledgement',
    () async {
      final cache = createSqliteCloudCacheForTesting(database);
      await cache.update('owner', (_) => {'count': 7});
      await expectLater(
        cache.update('owner', (current) {
          current!['count'] = 1000;
          throw StateError('Synthetic failure before commit');
        }),
        throwsStateError,
      );
      expect((await cache.read('owner'))!['count'], 7);
    },
  );

  test(
    'SQLite account outbox survives closing and reopening the database',
    () async {
      final cache = createSqliteCloudCacheForTesting(database);
      await cache.update(
        'owner',
        (_) => {
          'current': {'sessions': <dynamic>[]},
          'baseRevision': 12,
          'flight': {'id': 'synthetic-retry-id', 'revision': 12},
        },
      );
      await database.close();
      database = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(version: 1),
      );
      final restored = createSqliteCloudCacheForTesting(database);
      expect((await restored.read('owner'))!['flight'], {
        'id': 'synthetic-retry-id',
        'revision': 12,
      });
    },
  );

  test('SQLite account keys and deletion stay isolated from each other and guest data', () async {
    final cache = createSqliteCloudCacheForTesting(database);
    await cache.update('first-account', (_) => {'value': 1});
    await cache.update('second-account', (_) => {'value': 2});
    await cache.remove('first-account');
    expect(await cache.read('first-account'), isNull);
    expect((await cache.read('second-account'))!['value'], 2);
    expect(
      (await database.query('app_state')).single['payload'],
      'untouched-device-only-fixture',
    );
  });
}

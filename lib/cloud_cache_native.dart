import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'cloud_cache_types.dart';

CloudCache createCloudCache() => _SqliteCloudCache();
CloudCache createSqliteCloudCacheForTesting(Database database) =>
    _SqliteCloudCache(database: database);

class _SqliteCloudCache extends CloudCache {
  _SqliteCloudCache({Database? database}) {
    if (database != null) _database = _ensureTable(database);
  }
  Future<Database>? _database;

  Future<Database> _open() => _database ??= _initialize();
  Future<Database> _initialize() async {
    final database = await openDatabase(
      'relay.db',
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE app_state (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)',
        );
      },
    );
    return _ensureTable(database);
  }

  static Future<Database> _ensureTable(Database database) async {
    // Additive table, deliberately retaining version 1 so device-only storage
    // and already-installed native widget readers keep opening the same DB.
    await database.execute(
      'CREATE TABLE IF NOT EXISTS cloud_records '
      '(user_id TEXT PRIMARY KEY NOT NULL, envelope TEXT NOT NULL)',
    );
    return database;
  }

  CloudJson? _decode(List<Map<String, Object?>> rows) => rows.isEmpty
      ? null
      : Map<String, dynamic>.from(
          jsonDecode(rows.single['envelope'] as String) as Map,
        );

  @override
  Future<CloudJson?> read(String userId) async => _decode(
    await (await _open()).query(
      'cloud_records',
      where: 'user_id = ?',
      whereArgs: [userId],
    ),
  );

  @override
  Future<CloudJson?> update(
    String userId,
    CloudJson? Function(CloudJson? current) update,
  ) async => (await _open()).transaction((transaction) async {
    final current = _decode(
      await transaction.query(
        'cloud_records',
        where: 'user_id = ?',
        whereArgs: [userId],
      ),
    );
    final next = update(current);
    if (next == null) {
      await transaction.delete(
        'cloud_records',
        where: 'user_id = ?',
        whereArgs: [userId],
      );
    } else {
      await transaction.insert('cloud_records', {
        'user_id': userId,
        'envelope': jsonEncode(next),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return next;
  });
}

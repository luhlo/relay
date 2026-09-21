import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'model.dart';

class RelayStore {
  Database? _db;
  SharedPreferences? _prefs;
  Future<RelayState> load() async {
    String? raw;
    if (kIsWeb) {
      _prefs = await SharedPreferences.getInstance();
      raw = _prefs!.getString('relay.state.v1');
    } else {
      _db = await openDatabase(
        'relay.db',
        version: 1,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE app_state (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)',
          );
        },
      );
      final rows = await _db!.query(
        'app_state',
        where: 'id = ?',
        whereArgs: [1],
      );
      raw = rows.isEmpty ? null : rows.first['payload'] as String;
    }
    return raw == null ? RelayState() : RelayState.fromJson(jsonDecode(raw));
  }

  Future<void> save(RelayState state) async {
    final raw = jsonEncode(state.toJson());
    if (kIsWeb) {
      if (!await _prefs!.setString('relay.state.v1', raw)) {
        throw StateError('Could not save on this browser.');
      }
    } else {
      await _db!.insert('app_state', {
        'id': 1,
        'payload': raw,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'model.dart';

class LocalSaveConflict implements Exception {
  const LocalSaveConflict();
  final message = 'The widget changed your time. Refresh before trying again.';
}

class RelayStore {
  Database? _db;
  SharedPreferences? _prefs;
  String? _expectedPayload;
  bool _loaded = false;
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
    _expectedPayload = raw;
    _loaded = true;
    return raw == null ? RelayState() : RelayState.fromJson(jsonDecode(raw));
  }

  Future<void> save(RelayState state) async {
    if (!_loaded) throw StateError('Load records before saving.');
    final raw = jsonEncode(state.toJson());
    if (kIsWeb) {
      if (!await _prefs!.setString('relay.state.v1', raw)) {
        throw StateError('Could not save on this browser.');
      }
    } else {
      // Foreground UI and the headless widget engine can both be active.
      // Compare and write atomically so neither silently replaces newer time.
      await _db!.transaction((txn) async {
        final rows = await txn.query(
          'app_state',
          where: 'id = ?',
          whereArgs: [1],
        );
        final current = rows.isEmpty ? null : rows.first['payload'] as String;
        if (current != _expectedPayload) throw const LocalSaveConflict();
        await txn.insert('app_state', {
          'id': 1,
          'payload': raw,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
    }
    _expectedPayload = raw;
  }
}

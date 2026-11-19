import 'dart:convert';

import '../models/assigned_task.dart';
import '../utils/app_logger.dart';
import 'prefs_manager.dart';

class AssignedTaskStore {
  // Scope task state to a radio identity so assignments do not leak between devices.
  static const String _keyPrefix = 'assigned_tasks_';

  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length >= 10 ? value.substring(0, 10) : '';

  String get keyFor => '$_keyPrefix$publicKeyHex';

  Future<List<AssignedTask>> loadTasks() async {
    // Skip individual malformed records while preserving valid saved tasks.
    if (publicKeyHex.isEmpty) {
      throw StateError('Public key hex is required to load assigned tasks.');
    }

    final jsonString = PrefsManager.instance.getString(keyFor);
    if (jsonString == null || jsonString.isEmpty) return [];

    final decoded = jsonDecode(jsonString);
    if (decoded is! List) {
      throw const FormatException('Stored assigned tasks must be a JSON list.');
    }

    final tasks = <AssignedTask>[];
    for (final entry in decoded) {
      try {
        tasks.add(AssignedTask.fromJson(entry as Map<String, dynamic>));
      } catch (error) {
        appLogger.warn('Skipping malformed assigned task: $error');
      }
    }
    return tasks;
  }

  Future<void> saveTasks(List<AssignedTask> tasks) async {
    if (publicKeyHex.isEmpty) {
      throw StateError('Public key hex is required to save assigned tasks.');
    }

    final encoded = jsonEncode(tasks.map((task) => task.toJson()).toList());
    final saved = await PrefsManager.instance.setString(keyFor, encoded);
    if (!saved) {
      throw StateError('Failed to save assigned tasks.');
    }
  }
}

import 'dart:convert';

import 'package:characters/characters.dart';

import '../models/assigned_task.dart';

class TaskMessageProtocol {
  // Tasks use a dedicated wire prefix so direct messages and channel messages
  // can be filtered before application-specific parsing.
  static const String _prefix = 'MCTASK1';
  static const int _assignmentChunkLength = 64;
  static const int _maxTaskUpdateChunkLength = 56;
  static const int _taskNameMaxBytes = 17;

  static bool isProtocolMessage(String text) => text.startsWith('$_prefix|');

  // Assignment payloads are base64url JSON split into bounded text chunks.
  static List<String> encodeAssignment(AssignedTask task) {
    _validateTaskId(task.id);
    final encoded = base64Url
        .encode(utf8.encode(jsonEncode(task.toJson())))
        .replaceAll('=', '');
    final total = (encoded.length / _assignmentChunkLength).ceil();
    return List.generate(total, (index) {
      final start = index * _assignmentChunkLength;
      final end = (start + _assignmentChunkLength).clamp(0, encoded.length);
      return '$_prefix|A|${task.id}|${index + 1}|$total|'
          '${encoded.substring(start, end)}';
    });
  }

  static AssignmentPart? parseAssignmentPart(String text) {
    final fields = text.split('|');
    if (fields.length != 6 || fields[0] != _prefix || fields[1] != 'A') {
      return null;
    }
    final index = int.tryParse(fields[3]);
    final total = int.tryParse(fields[4]);
    if (!_isValidTaskId(fields[2]) ||
        fields[5].isEmpty ||
        index == null ||
        total == null ||
        total < 1 ||
        total > 256 ||
        index < 1 ||
        index > total ||
        fields[5].length > _assignmentChunkLength) {
      return null;
    }
    return AssignmentPart(
      taskId: fields[2],
      index: index,
      total: total,
      payload: fields[5],
    );
  }

  static AssignedTask? decodeAssignment(String payload) {
    // Decoding is intentionally total: malformed wire data is ignored rather
    // than allowed to create partially initialized task state.
    try {
      final padded = payload.padRight((payload.length + 3) ~/ 4 * 4, '=');
      final decoded = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (decoded is! Map<String, dynamic>) return null;
      final task = AssignedTask.fromJson(decoded);
      if (task.id.isEmpty ||
          task.id.length > 64 ||
          task.id.contains('|') ||
          task.taskName.trim().isEmpty ||
          utf8.encode(task.taskName).length > _taskNameMaxBytes ||
          task.description.characters.length > 500 ||
          task.channelName.isEmpty ||
          utf8.encode(task.channelName).length > 31 ||
          !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(task.channelPskHex) ||
          task.expectedRecipientCount < 0 ||
          (task.dueMode == AssignedTaskDueMode.longTerm &&
              task.dueAt == null)) {
        return null;
      }
      return task;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static String encodeReceipt(String taskId) {
    // Receipts acknowledge a complete assignment to the assigning contact.
    _validateTaskId(taskId);
    return '$_prefix|R|$taskId';
  }

  static String? parseReceipt(String text) {
    final fields = text.split('|');
    if (fields.length != 3 || fields[0] != _prefix || fields[1] != 'R') {
      return null;
    }
    final taskId = fields[2];
    if (!_isValidTaskId(taskId)) return null;
    return taskId;
  }

  static String encodeStatusUpdate(
    String taskId,
    AssignedTaskStatus status,
    DateTime updatedAt,
  ) {
    _validateTaskId(taskId);
    return '$_prefix|S|$taskId|${status.name}|'
        '${updatedAt.toUtc().millisecondsSinceEpoch}';
  }

  static TaskStatusUpdate? parseStatusUpdate(String text) {
    final fields = text.split('|');
    if (fields.length != 5 || fields[0] != _prefix || fields[1] != 'S') {
      return null;
    }
    final status = AssignedTaskStatus.values.where(
      (value) => value.name == fields[3],
    );
    final timestamp = int.tryParse(fields[4]);
    if (!_isValidTaskId(fields[2]) ||
        status.isEmpty ||
        timestamp == null ||
        timestamp < 0) {
      return null;
    }
    return TaskStatusUpdate(
      taskId: fields[2],
      status: status.first,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true),
    );
  }

  static List<String> encodeTaskUpdate(AssignedTask task) {
    // Snapshot updates omit recipient tracking and local channel UI state,
    // while embedding updatedAt so stale snapshots can be rejected on decode.
    if (task.id.isEmpty || task.id.length > 64 || task.id.contains('|')) {
      throw StateError('Task identifier cannot be encoded for sharing.');
    }
    final snapshot = Map<String, dynamic>.from(task.toJson())
      ..['expected_recipient_keys'] = const <String>[]
      ..['received_recipient_keys'] = const <String>[]
      ..['channel_index'] = null
      ..['channel_opened'] = false
      ..['automatic_resend_enabled'] = false;
    final encoded = base64Url
        .encode(utf8.encode(jsonEncode(snapshot)))
        .replaceAll('=', '');
    final chunkLength = _taskUpdateChunkLengthFor(task.id);
    final total = (encoded.length / chunkLength).ceil();
    if (total > 256) {
      throw StateError('Task update exceeds the supported number of parts.');
    }
    final updatedAt = task.updatedAt.toUtc().millisecondsSinceEpoch;
    return List.generate(total, (index) {
      final start = index * chunkLength;
      final end = (start + chunkLength).clamp(0, encoded.length);
      return '$_prefix|U|${task.id}|$updatedAt|${index + 1}|$total|'
          '${encoded.substring(start, end)}';
    });
  }

  static TaskUpdatePart? parseTaskUpdatePart(String text) {
    final fields = text.split('|');
    if (fields.length != 7 || fields[0] != _prefix || fields[1] != 'U') {
      return null;
    }
    final updatedAt = int.tryParse(fields[3]);
    final index = int.tryParse(fields[4]);
    final total = int.tryParse(fields[5]);
    if (fields[2].isEmpty ||
        updatedAt == null ||
        index == null ||
        total == null ||
        total < 1 ||
        total > 256 ||
        index < 1 ||
        index > total ||
        fields[2].length > 64 ||
        fields[2].contains('|') ||
        updatedAt < 0 ||
        fields[6].length > _taskUpdateChunkLengthFor(fields[2])) {
      return null;
    }
    return TaskUpdatePart(
      taskId: fields[2],
      updatedAtMilliseconds: updatedAt,
      index: index,
      total: total,
      payload: fields[6],
    );
  }

  static AssignedTask? decodeTaskUpdate(
    String payload, {
    required String taskId,
    required int updatedAtMilliseconds,
  }) {
    final task = decodeAssignment(payload);
    if (task == null ||
        task.id != taskId ||
        task.updatedAt.toUtc().millisecondsSinceEpoch !=
            updatedAtMilliseconds) {
      return null;
    }
    return task;
  }

  static int _taskUpdateChunkLengthFor(String taskId) {
    final channelLimit = 127 - 33 - taskId.length;
    return channelLimit < _maxTaskUpdateChunkLength
        ? channelLimit
        : _maxTaskUpdateChunkLength;
  }

  static bool _isValidTaskId(String taskId) =>
      taskId.isNotEmpty && taskId.length <= 64 && !taskId.contains('|');

  static void _validateTaskId(String taskId) {
    if (!_isValidTaskId(taskId)) {
      throw StateError('Task identifier cannot be encoded for sharing.');
    }
  }
}

class AssignmentPart {
  const AssignmentPart({
    required this.taskId,
    required this.index,
    required this.total,
    required this.payload,
  });

  final String taskId;
  final int index;
  final int total;
  final String payload;
}

class TaskStatusUpdate {
  const TaskStatusUpdate({
    required this.taskId,
    required this.status,
    required this.updatedAt,
  });

  final String taskId;
  final AssignedTaskStatus status;
  final DateTime updatedAt;
}

class TaskUpdatePart {
  const TaskUpdatePart({
    required this.taskId,
    required this.updatedAtMilliseconds,
    required this.index,
    required this.total,
    required this.payload,
  });

  final String taskId;
  final int updatedAtMilliseconds;
  final int index;
  final int total;
  final String payload;
}

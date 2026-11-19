import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshusf/connector/meshcore_protocol.dart';
import 'package:meshusf/models/assigned_task.dart';
import 'package:meshusf/services/task_message_protocol.dart';

void main() {
  test('receipt and status encoders reject invalid task identifiers', () {
    expect(
      () => TaskMessageProtocol.encodeReceipt('bad|task'),
      throwsStateError,
    );
    expect(
      () => TaskMessageProtocol.encodeStatusUpdate(
        'bad|task',
        AssignedTaskStatus.working,
        DateTime.utc(2026),
      ),
      throwsStateError,
    );
  });

  test('receipt and status parsers reject malformed task metadata', () {
    expect(TaskMessageProtocol.parseReceipt('MCTASK1|R|${'x' * 65}'), isNull);
    expect(TaskMessageProtocol.parseReceipt('MCTASK1|R|bad|task'), isNull);
    expect(
      TaskMessageProtocol.parseAssignmentPart(
        'MCTASK1|A|${'x' * 65}|1|1|payload',
      ),
      isNull,
    );
    expect(
      TaskMessageProtocol.parseAssignmentPart('MCTASK1|A|bad|1|1|'),
      isNull,
    );
    expect(
      TaskMessageProtocol.parseStatusUpdate('MCTASK1|S|bad|working|-1'),
      isNull,
    );
    expect(
      TaskMessageProtocol.parseStatusUpdate('MCTASK1|S|${'x' * 65}|working|0'),
      isNull,
    );
  });

  test('assignment messages stay within the radio text payload limit', () {
    final task = AssignedTask(
      id: 'task-123',
      taskName: 'Check supply kit',
      description: '🧰' * 500,
      recipientKeys: const ['everyone'],
      recipientLabels: const ['Everyone'],
      expectedRecipientKeys: const ['recipient-key'],
      assignedByKey: 'sender-key',
      assignedByName: 'Jordan',
      channelName: 'Task-task123',
      channelPskHex: '0123456789abcdef0123456789abcdef',
      dueMode: AssignedTaskDueMode.none,
      dueAt: null,
      assignedAt: DateTime.utc(2026, 11, 18),
      automaticResendEnabled: true,
    );

    final messages = TaskMessageProtocol.encodeAssignment(task);

    expect(messages.length, greaterThan(1));
    for (final message in messages) {
      expect(
        utf8.encode(message).length,
        lessThanOrEqualTo(maxTextPayloadBytes),
      );
    }

    final parts = messages
        .map(TaskMessageProtocol.parseAssignmentPart)
        .whereType<AssignmentPart>()
        .toList();
    expect(parts, hasLength(messages.length));
    final payload = List.generate(
      parts.first.total,
      (index) => parts.firstWhere((part) => part.index == index + 1).payload,
    ).join();
    final decoded = TaskMessageProtocol.decodeAssignment(payload);
    final wireTask =
        jsonDecode(
              utf8.decode(
                base64Url.decode(
                  payload.padRight((payload.length + 3) ~/ 4 * 4, '='),
                ),
              ),
            )
            as Map<String, dynamic>;

    expect(decoded?.id, task.id);
    expect(decoded?.taskName, task.taskName);
    expect(decoded?.description, task.description);
    expect(decoded?.channelPskHex, task.channelPskHex);
    expect(wireTask['task_name'], task.taskName);
    expect(wireTask.containsKey('summary'), isFalse);
  });

  test('receipt and status messages round-trip and reject malformed input', () {
    final receipt = TaskMessageProtocol.encodeReceipt('task-123');
    expect(TaskMessageProtocol.parseReceipt(receipt), 'task-123');
    expect(TaskMessageProtocol.parseReceipt('MCTASK1|R|'), isNull);

    final timestamp = DateTime.utc(2026, 11, 18, 14, 30);
    final statusMessage = TaskMessageProtocol.encodeStatusUpdate(
      'task-123',
      AssignedTaskStatus.working,
      timestamp,
    );
    final status = TaskMessageProtocol.parseStatusUpdate(statusMessage);
    expect(status?.taskId, 'task-123');
    expect(status?.status, AssignedTaskStatus.working);
    expect(status?.updatedAt, timestamp);
    expect(
      TaskMessageProtocol.parseStatusUpdate('MCTASK1|S|task-123|unknown|0'),
      isNull,
    );
  });

  test('task updates are chunked and retain a versioned task snapshot', () {
    final updatedAt = DateTime.utc(2026, 11, 18, 14, 30);
    final task = AssignedTask(
      id: 'task-123',
      taskName: 'Check supply kit',
      description: '🧰' * 500,
      recipientKeys: const ['everyone'],
      recipientLabels: const ['Everyone'],
      expectedRecipientKeys: const ['recipient-key'],
      assignedByKey: 'sender-key',
      assignedByName: 'Jordan',
      channelName: 'Task-task123',
      channelPskHex: '0123456789abcdef0123456789abcdef',
      dueMode: AssignedTaskDueMode.none,
      dueAt: null,
      assignedAt: DateTime.utc(2026, 11, 18),
      updatedAt: updatedAt,
      automaticResendEnabled: true,
    );

    final messages = TaskMessageProtocol.encodeTaskUpdate(task);
    final parts = messages
        .map(TaskMessageProtocol.parseTaskUpdatePart)
        .whereType<TaskUpdatePart>()
        .toList();
    final payload = List.generate(
      parts.first.total,
      (index) => parts.firstWhere((part) => part.index == index + 1).payload,
    ).join();

    expect(messages.length, greaterThan(1));
    expect(
      messages.every((message) => utf8.encode(message).length <= 127),
      isTrue,
    );
    final decoded = TaskMessageProtocol.decodeTaskUpdate(
      payload,
      taskId: task.id,
      updatedAtMilliseconds: updatedAt.millisecondsSinceEpoch,
    );
    expect(decoded?.description, task.description);
    expect(decoded?.expectedRecipientKeys, isEmpty);
    expect(decoded?.receivedRecipientKeys, isEmpty);
    expect(
      TaskMessageProtocol.decodeTaskUpdate(
        payload,
        taskId: task.id,
        updatedAtMilliseconds: updatedAt.millisecondsSinceEpoch + 1,
      ),
      isNull,
    );
    expect(
      TaskMessageProtocol.parseTaskUpdatePart('MCTASK1|U|bad|x|1|1|'),
      isNull,
    );
  });
}

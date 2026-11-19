import 'package:flutter_test/flutter_test.dart';
import 'package:meshusf/models/assigned_task.dart';
import 'package:meshusf/storage/assigned_task_store.dart';
import 'package:meshusf/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('copyWith updates recipient metadata', () {
    final task = AssignedTask(
      id: 'task-copy',
      taskName: 'Copy task',
      description: '',
      recipientKeys: const [],
      recipientLabels: const [],
      expectedRecipientCount: 2,
      dueMode: AssignedTaskDueMode.none,
      dueAt: null,
      assignedAt: DateTime(2026),
      automaticResendEnabled: true,
    );

    expect(task.copyWith(expectedRecipientCount: 5).expectedRecipientCount, 5);
  });

  test('store accepts a ten character radio scope key', () async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();

    final task = AssignedTask(
      id: 'task-scope',
      taskName: 'Scope task',
      description: '',
      recipientKeys: const [],
      recipientLabels: const [],
      dueMode: AssignedTaskDueMode.none,
      dueAt: null,
      assignedAt: DateTime(2026),
      automaticResendEnabled: true,
    );
    final store = AssignedTaskStore()..setPublicKeyHex = '0123456789';

    await store.saveTasks([task]);
    final loaded = await (AssignedTaskStore()..setPublicKeyHex = '0123456789')
        .loadTasks();
    expect(loaded, hasLength(1));
  });

  test('task names serialize under task_name', () {
    final task = AssignedTask(
      id: 'task-name',
      taskName: 'Check supply kit',
      description: '',
      recipientKeys: const [],
      recipientLabels: const [],
      dueMode: AssignedTaskDueMode.none,
      dueAt: null,
      assignedAt: DateTime(2026),
      automaticResendEnabled: true,
    );
    final json = task.toJson();
    expect(json['task_name'], task.taskName);
    expect(json.containsKey('summary'), isFalse);
    expect(AssignedTask.fromJson(json).taskName, task.taskName);
  });

  test('any completion completes a task and all completions verify it', () {
    final task = AssignedTask(
      id: 'task-status',
      taskName: 'Complete task',
      description: '',
      recipientKeys: const ['everyone'],
      recipientLabels: const ['Everyone'],
      assignedByKey: 'creator',
      expectedRecipientKeys: const ['a', 'b'],
      expectedRecipientCount: 2,
      memberStatuses: const {
        'a': {'status': 'completed'},
        'b': {'status': 'working'},
      },
      dueMode: AssignedTaskDueMode.none,
      dueAt: null,
      assignedAt: DateTime(2026),
      automaticResendEnabled: true,
    );

    expect(task.status, AssignedTaskStatus.completed);
    expect(
      task
          .copyWith(
            memberStatuses: const {
              'a': {'status': 'working'},
              'b': {'status': 'working'},
            },
          )
          .status,
      AssignedTaskStatus.working,
    );
    expect(
      task
          .copyWith(
            memberStatuses: const {
              'a': {'status': 'completed'},
              'b': {'status': 'completed'},
            },
          )
          .status,
      AssignedTaskStatus.verifiedComplete,
    );
    expect(
      task
          .copyWith(
            memberStatuses: const {
              'a': {'status': 'completed'},
              'b': {'status': 'working'},
              'creator': {'status': 'verifiedComplete'},
            },
          )
          .status,
      AssignedTaskStatus.verifiedComplete,
    );
  });

  test(
    'assigned tasks persist per radio with all assignment details',
    () async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();

      final task = AssignedTask(
        id: 'task-1',
        taskName: 'Check supply kit',
        description: 'Confirm the batteries and first-aid supplies.',
        recipientKeys: const ['everyone', 'contact:abc123'],
        recipientLabels: const ['Everyone', 'Jordan'],
        expectedRecipientKeys: const ['abc123', 'def456'],
        expectedRecipientCount: 2,
        receivedRecipientKeys: const ['abc123'],
        assignedByKey: 'sender-key',
        assignedByName: 'Casey',
        channelName: 'Task-task-1',
        channelPskHex: '0123456789abcdef0123456789abcdef',
        channelIndex: 2,
        channelOpened: true,
        memberStatuses: {
          'abc123': {
            'status': AssignedTaskStatus.working.name,
            'updated_at': '2026-11-18T14:30:00.000Z',
          },
        },
        dueMode: AssignedTaskDueMode.immediate,
        dueAt: DateTime(2026, 11, 19, 16, 30),
        assignedAt: DateTime(2026, 11, 18, 14, 30),
        automaticResendEnabled: false,
      );

      final store = AssignedTaskStore()..setPublicKeyHex = '0123456789abcdef';
      await store.saveTasks([task]);

      final loaded =
          await (AssignedTaskStore()..setPublicKeyHex = '0123456789abcdef')
              .loadTasks();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, task.id);
      expect(loaded.single.taskName, task.taskName);
      expect(loaded.single.description, task.description);
      expect(loaded.single.recipientKeys, task.recipientKeys);
      expect(loaded.single.recipientLabels, task.recipientLabels);
      expect(loaded.single.expectedRecipientKeys, task.expectedRecipientKeys);
      expect(loaded.single.expectedRecipientCount, task.expectedRecipientCount);
      expect(loaded.single.receivedRecipientKeys, task.receivedRecipientKeys);
      expect(loaded.single.assignedByKey, task.assignedByKey);
      expect(loaded.single.assignedByName, task.assignedByName);
      expect(loaded.single.channelName, task.channelName);
      expect(loaded.single.channelPskHex, task.channelPskHex);
      expect(loaded.single.channelIndex, task.channelIndex);
      expect(loaded.single.channelOpened, isTrue);
      expect(
        loaded.single.memberStatuses['abc123']?['status'],
        AssignedTaskStatus.working.name,
      );
      expect(loaded.single.dueMode, task.dueMode);
      expect(loaded.single.dueAt, task.dueAt);
      expect(loaded.single.assignedAt, task.assignedAt);
      expect(loaded.single.automaticResendEnabled, isFalse);

      final otherRadioTasks =
          await (AssignedTaskStore()..setPublicKeyHex = 'fedcba9876543210')
              .loadTasks();
      expect(otherRadioTasks, isEmpty);
    },
  );
}

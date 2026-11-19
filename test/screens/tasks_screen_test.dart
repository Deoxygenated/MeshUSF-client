import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshusf/connector/meshcore_protocol.dart';
import 'package:meshusf/connector/meshcore_connector.dart';
import 'package:meshusf/l10n/app_localizations.dart';
import 'package:meshusf/models/channel.dart';
import 'package:meshusf/models/channel_message.dart';
import 'package:meshusf/models/contact.dart';
import 'package:meshusf/models/message.dart';
import 'package:meshusf/models/assigned_task.dart';
import 'package:meshusf/screens/tasks_screen.dart';
import 'package:meshusf/services/task_message_protocol.dart';
import 'package:meshusf/storage/assigned_task_store.dart';
import 'package:meshusf/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _initializePreferences() async {
  SharedPreferences.setMockInitialValues({});
  PrefsManager.reset();
  await PrefsManager.initialize();
}

class _ConnectedMeshCoreConnector extends MeshCoreConnector {
  final List<Contact> testContacts = [
    Contact(
      publicKey: Uint8List.fromList(List<int>.generate(32, (index) => index)),
      name: 'Jordan',
      type: advTypeChat,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026),
    ),
  ];
  final List<Channel> testChannels = [];
  final List<String> sentMessages = [];
  final List<String> sentChannelMessages = [];
  List<Message> incomingTaskMessages = [];
  List<ChannelMessage> incomingTaskChannelMessages = [];

  @override
  bool get isConnected => true;

  @override
  bool get hasLoadedChannels => true;

  @override
  int get maxChannels => 8;

  @override
  List<Contact> get contacts => testContacts;

  @override
  List<Channel> get channels => testChannels;

  @override
  String get selfPublicKeyHex => '0123456789abcdef';

  @override
  Contact? getContactByPubKeyHex(String contactPubKeyHex) {
    for (final contact in testContacts) {
      if (contact.publicKeyHex == contactPubKeyHex) return contact;
    }
    return null;
  }

  @override
  Future<void> setChannel(int index, String name, Uint8List psk) async {
    final channelIndex = testChannels.indexWhere(
      (channel) => channel.index == index,
    );
    final channel = Channel(index: index, name: name, psk: psk);
    if (channelIndex == -1) {
      testChannels.add(channel);
    } else {
      testChannels[channelIndex] = channel;
    }
  }

  @override
  Future<void> sendMessage(
    Contact contact,
    String text, {
    String? originalText,
    String? translatedLanguageCode,
    String? translationModelId,
  }) async {
    sentMessages.add(text);
  }

  @override
  List<Message> getTaskProtocolMessages(Contact contact) =>
      incomingTaskMessages;

  @override
  List<ChannelMessage> getTaskProtocolChannelMessages(Channel channel) =>
      incomingTaskChannelMessages;

  @override
  Future<void> sendChannelMessage(
    Channel channel,
    String text, {
    String? originalText,
    String? translatedLanguageCode,
    String? translationModelId,
    String? region,
    ChannelMessage? replyTo,
  }) async {
    sentChannelMessages.add(text);
  }
}

void main() {
  testWidgets('Tasks screen has two resizable side-by-side sections', (
    tester,
  ) async {
    await _initializePreferences();
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final connector = _ConnectedMeshCoreConnector();
    addTearDown(connector.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final leftSection = find.byKey(const Key('tasks-left-section'));
    final rightSection = find.byKey(const Key('tasks-right-section'));
    final splitter = find.byKey(const Key('tasks-splitter'));
    expect(find.text('Tasks'), findsWidgets);
    expect(tester.getSize(leftSection).width, closeTo(388, 1));
    final rightWidthBeforeDrag = tester.getSize(rightSection).width;

    await tester.drag(splitter, const Offset(120, 0));
    await tester.pumpAndSettle();

    expect(tester.getSize(leftSection).width, greaterThan(388));
    expect(tester.getSize(rightSection).width, lessThan(rightWidthBeforeDrag));
  });

  testWidgets('assigned tasks can be filtered by search, status, and tag', (
    tester,
  ) async {
    await _initializePreferences();
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final connector = _ConnectedMeshCoreConnector();
    addTearDown(connector.dispose);
    final assignedAt = DateTime(2026, 11, 18);
    final tasks = [
      AssignedTask(
        id: 'supply-task',
        taskName: 'Check supply kit',
        description: '',
        recipientKeys: const ['team'],
        recipientLabels: const ['Team'],
        assignedByKey: connector.selfPublicKeyHex,
        assignedByName: 'Me',
        dueMode: AssignedTaskDueMode.none,
        dueAt: null,
        assignedAt: assignedAt,
        automaticResendEnabled: true,
      ),
      AssignedTask(
        id: 'radio-task',
        taskName: 'Inspect the radio',
        description: '',
        recipientKeys: const ['everyone'],
        recipientLabels: const ['Everyone'],
        assignedByKey: connector.selfPublicKeyHex,
        assignedByName: 'Me',
        memberStatuses: {
          connector.testContacts.single.publicKeyHex: {
            'status': AssignedTaskStatus.working.name,
            'updated_at': assignedAt.toIso8601String(),
          },
        },
        dueMode: AssignedTaskDueMode.none,
        dueAt: null,
        assignedAt: assignedAt.add(const Duration(minutes: 1)),
        automaticResendEnabled: true,
      ),
    ];
    await (AssignedTaskStore()..setPublicKeyHex = connector.selfPublicKeyHex)
        .saveTasks(tasks);

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('tasks-assigned-search')),
      'supply',
    );
    await tester.pumpAndSettle();
    expect(find.text('Check supply kit'), findsOneWidget);
    expect(find.text('Inspect the radio'), findsNothing);

    await tester.enterText(find.byKey(const Key('tasks-assigned-search')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tasks-assigned-status-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Being worked on').last);
    await tester.pumpAndSettle();
    expect(find.text('Inspect the radio'), findsOneWidget);
    expect(find.text('Check supply kit'), findsNothing);

    await tester.tap(find.byKey(const Key('tasks-assigned-status-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All statuses').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tasks-assigned-tag-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team').last);
    await tester.pumpAndSettle();
    expect(find.text('Check supply kit'), findsOneWidget);
    expect(find.text('Inspect the radio'), findsNothing);

    await tester.tap(find.byKey(const Key('tasks-assigned-tag-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All tags').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tasks-assigned-sort-order')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Task name'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const Key('assigned-task-supply-task'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('assigned-task-radio-task'))).dy,
      ),
    );
  });

  testWidgets('task assigner edits details and publishes a task update', (
    tester,
  ) async {
    await _initializePreferences();
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final connector = _ConnectedMeshCoreConnector();
    addTearDown(connector.dispose);
    const pskHex = '0123456789abcdef0123456789abcdef';
    connector.testChannels.add(
      Channel(index: 0, name: 'Task-edit', psk: Channel.parsePskHex(pskHex)),
    );
    final assignedAt = DateTime(2026, 11, 18);
    final task = AssignedTask(
      id: 'owner-task',
      taskName: 'Inspect the radio',
      description: 'Check the antenna.',
      recipientKeys: const ['everyone'],
      recipientLabels: const ['Everyone'],
      assignedByKey: connector.selfPublicKeyHex,
      assignedByName: 'Me',
      channelName: 'Task-edit',
      channelPskHex: pskHex,
      channelIndex: 0,
      dueMode: AssignedTaskDueMode.none,
      dueAt: null,
      assignedAt: assignedAt,
      automaticResendEnabled: true,
    );
    final store = AssignedTaskStore()
      ..setPublicKeyHex = connector.selfPublicKeyHex;
    await store.saveTasks([task]);

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tasks-edit-owner-task')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('tasks-edit-name-field')),
      'Replace radio',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Replace radio'), findsOneWidget);
    expect((await store.loadTasks()).single.taskName, 'Replace radio');
    expect(connector.testChannels.single.name, 'Task-Replace radio-owner-ta');
    expect(connector.sentChannelMessages, isNotEmpty);
    expect(
      connector.sentChannelMessages.every(
        (message) => TaskMessageProtocol.parseTaskUpdatePart(message) != null,
      ),
      isTrue,
    );
  });

  testWidgets('Assign pane persists locally assigned tasks', (tester) async {
    await _initializePreferences();
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final connector = _ConnectedMeshCoreConnector();
    addTearDown(connector.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final nameField = find.byKey(const Key('tasks-name-field'));
    expect(nameField, findsNothing);
    await tester.tap(find.byKey(const Key('tasks-toggle-form')));
    await tester.pumpAndSettle();
    final nameTextField = tester.widget<TextField>(nameField);
    expect(nameTextField.maxLength, 17);
    expect(find.text('Task name'), findsOneWidget);
    await tester.enterText(nameField, 'é' * 20);
    expect(
      utf8.encode(nameTextField.controller!.text).length,
      lessThanOrEqualTo(17),
    );
    await tester.enterText(nameField, '');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tasks-description-field')))
          .maxLength,
      500,
    );

    await tester.tap(find.byKey(const Key('tasks-submit-task')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a task name.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tasks-choose-recipients')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyone'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.enterText(nameField, 'Check the supply');
    await tester.tap(find.byKey(const Key('tasks-submit-task')));
    await tester.pumpAndSettle();

    expect(find.text('Check the supply'), findsOneWidget);
    expect(
      connector.testChannels.single.name,
      startsWith('Task-Check the supply-'),
    );
    expect(
      utf8.encode(connector.testChannels.single.name).length,
      lessThanOrEqualTo(31),
    );
    expect(find.text('Assigned tasks'), findsOneWidget);
    expect(find.text('0 of 1 received'), findsOneWidget);
    expect(connector.sentMessages, isNotEmpty);
    expect(
      connector.sentMessages.every((message) => message.length <= 160),
      isTrue,
    );
    final taskId = TaskMessageProtocol.parseAssignmentPart(
      connector.sentMessages.first,
    )!.taskId;
    final recipient = connector.testContacts.single;
    connector.incomingTaskMessages = [
      Message(
        senderKey: recipient.publicKey,
        text: TaskMessageProtocol.encodeReceipt(taskId),
        timestamp: DateTime.now(),
        isOutgoing: false,
      ),
    ];
    connector.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('1 of 1 received'), findsOneWidget);
    await tester.tap(find.byKey(Key('tasks-status-menu-$taskId')));
    await tester.pumpAndSettle();
    expect(find.text('Verified Complete'), findsOneWidget);
    await tester.tap(find.text('Verified Complete'));
    await tester.pumpAndSettle();
    expect(
      connector.sentChannelMessages.single,
      startsWith('MCTASK1|S|$taskId|verifiedComplete|'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Check the supply'), findsOneWidget);
    expect(find.byKey(const Key('tasks-name-field')), findsNothing);
  });

  testWidgets('received assignment is stored and acknowledged', (tester) async {
    await _initializePreferences();
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final connector = _ConnectedMeshCoreConnector();
    addTearDown(connector.dispose);
    final sender = connector.testContacts.single;
    final task = AssignedTask(
      id: 'received-task',
      taskName: 'Check supply kit',
      description: 'Confirm all items are present.',
      recipientKeys: const ['everyone'],
      recipientLabels: const ['Everyone'],
      assignedByKey: sender.publicKeyHex,
      assignedByName: sender.name,
      channelName: 'Task-received',
      channelPskHex: '0123456789abcdef0123456789abcdef',
      dueMode: AssignedTaskDueMode.none,
      dueAt: null,
      assignedAt: DateTime(2026, 11, 18),
      automaticResendEnabled: true,
    );
    connector.incomingTaskMessages = TaskMessageProtocol.encodeAssignment(task)
        .map(
          (text) => Message(
            senderKey: sender.publicKey,
            text: text,
            timestamp: DateTime(2026, 11, 18),
            isOutgoing: false,
          ),
        )
        .toList();

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Assigned to me'), findsOneWidget);
    expect(find.text('Check supply kit'), findsOneWidget);
    expect(find.textContaining('Assigned by: Jordan'), findsOneWidget);
    expect(
      connector.sentMessages,
      contains(TaskMessageProtocol.encodeReceipt(task.id)),
    );
    connector.notifyListeners();
    await tester.pumpAndSettle();
    expect(
      connector.sentMessages
          .where(
            (message) => message == TaskMessageProtocol.encodeReceipt(task.id),
          )
          .length,
      1,
    );
    await tester.tap(find.byKey(const Key('tasks-status-menu-received-task')));
    await tester.pumpAndSettle();
    expect(find.text('Verified Complete'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    final otherParticipantKey = Uint8List.fromList(
      List<int>.filled(sender.publicKey.length, 255),
    );
    connector.incomingTaskChannelMessages = [
      ChannelMessage(
        senderKey: otherParticipantKey,
        senderName: 'Another participant',
        text: TaskMessageProtocol.encodeStatusUpdate(
          task.id,
          AssignedTaskStatus.verifiedComplete,
          DateTime.now(),
        ),
        timestamp: DateTime.now(),
        isOutgoing: false,
        channelIndex: connector.testChannels.single.index,
      ),
    ];
    connector.notifyListeners();
    await tester.pumpAndSettle();
    var storedTasks =
        await (AssignedTaskStore()
              ..setPublicKeyHex = connector.selfPublicKeyHex)
            .loadTasks();
    expect(storedTasks.single.status, AssignedTaskStatus.untouched);

    connector.incomingTaskChannelMessages = [
      ChannelMessage(
        senderKey: sender.publicKey,
        senderName: sender.name,
        text: TaskMessageProtocol.encodeStatusUpdate(
          task.id,
          AssignedTaskStatus.verifiedComplete,
          DateTime.now().add(const Duration(seconds: 1)),
        ),
        timestamp: DateTime.now(),
        isOutgoing: false,
        channelIndex: connector.testChannels.single.index,
      ),
    ];
    connector.notifyListeners();
    await tester.pumpAndSettle();
    storedTasks =
        await (AssignedTaskStore()
              ..setPublicKeyHex = connector.selfPublicKeyHex)
            .loadTasks();
    expect(storedTasks.single.status, AssignedTaskStatus.verifiedComplete);

    connector.incomingTaskMessages = TaskMessageProtocol.encodeAssignment(task)
        .map(
          (text) => Message(
            senderKey: sender.publicKey,
            text: text,
            timestamp: DateTime(
              2026,
              11,
              18,
              14,
              30,
            ).add(Duration(seconds: connector.incomingTaskMessages.length)),
            isOutgoing: false,
          ),
        )
        .toList();
    connector.notifyListeners();
    await tester.pumpAndSettle();
    expect(
      connector.sentMessages
          .where(
            (message) => message == TaskMessageProtocol.encodeReceipt(task.id),
          )
          .length,
      2,
    );
    final storedTasksAfterResend =
        await (AssignedTaskStore()
              ..setPublicKeyHex = connector.selfPublicKeyHex)
            .loadTasks();
    expect(storedTasksAfterResend, hasLength(1));
    expect(storedTasksAfterResend.single.assignedByKey, sender.publicKeyHex);
  });

  testWidgets('Myself tag creates a received task without a direct message', (
    tester,
  ) async {
    await _initializePreferences();
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final connector = _ConnectedMeshCoreConnector();
    addTearDown(connector.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tasks-toggle-form')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tasks-choose-recipients')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Myself'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('tasks-name-field')),
      'Prepare own kit',
    );
    await tester.tap(find.byKey(const Key('tasks-submit-task')));
    await tester.pumpAndSettle();

    expect(connector.sentMessages, isEmpty);
    expect(find.text('1 of 1 received'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('tasks-right-section')),
        matching: find.text('Prepare own kit'),
      ),
      findsOneWidget,
    );
    final tasks =
        await (AssignedTaskStore()
              ..setPublicKeyHex = connector.selfPublicKeyHex)
            .loadTasks();
    expect(tasks.single.recipientKeys, contains('self'));
    expect(
      tasks.single.expectedRecipientKeys,
      contains(connector.selfPublicKeyHex),
    );
    expect(
      tasks.single.receivedRecipientKeys,
      contains(connector.selfPublicKeyHex),
    );
  });
}

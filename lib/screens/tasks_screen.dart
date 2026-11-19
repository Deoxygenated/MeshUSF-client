import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart'
    show advTypeChat, maxChannelMessageBytes, pubKeyToHex;
import '../helpers/utf8_length_limiter.dart';
import '../l10n/l10n.dart';
import '../models/assigned_task.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/contact_group.dart';
import '../services/task_message_protocol.dart';
import '../storage/assigned_task_store.dart';
import '../storage/contact_group_store.dart';
import '../utils/app_logger.dart';
import '../utils/disconnect_navigation_mixin.dart';
import '../utils/keys.dart';
import '../utils/route_transitions.dart';
import '../widgets/app_bar.dart';
import '../widgets/quick_switch_bar.dart';
import 'channel_chat_screen.dart';
import 'channels_screen.dart';
import 'contacts_screen.dart';
import 'map_screen.dart';

enum _TaskSortOrder { recentlyAssigned, dueSoonest, taskName }

const int _taskNameMaxBytes = 17;

String _taskChannelName(String taskName, String taskId) =>
    // Keep channel names recognizable while reserving room for a stable ID suffix.
    'Task-$taskName-${taskId.substring(0, 8)}';

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

extension _TasksScreenFilters on _TasksScreenState {
  // Filtering and sorting is applied separately to assigned and received views.
  List<AssignedTask> _filterAndSortTasks(
    List<AssignedTask> source, {
    required bool assignedByMe,
  }) {
    final query = (assignedByMe ? _assignedSearchText : _receivedSearchText)
        .trim()
        .toLowerCase();
    final statusFilter = assignedByMe
        ? _assignedStatusFilter
        : _receivedStatusFilter;
    final tagFilter = assignedByMe ? _assignedTagFilter : _receivedTagFilter;
    final sortOrder = assignedByMe ? _assignedSortOrder : _receivedSortOrder;

    final tasks = source.where((task) {
      if (statusFilter != 'all' && task.status.name != statusFilter) {
        return false;
      }
      if (tagFilter != 'all' && !task.recipientLabels.contains(tagFilter)) {
        return false;
      }
      if (query.isEmpty) return true;
      return task.taskName.toLowerCase().contains(query) ||
          task.description.toLowerCase().contains(query) ||
          task.assignedByName.toLowerCase().contains(query) ||
          task.recipientLabels.any(
            (label) => label.toLowerCase().contains(query),
          );
    }).toList();

    tasks.sort((a, b) {
      switch (sortOrder) {
        case _TaskSortOrder.recentlyAssigned:
          return b.assignedAt.compareTo(a.assignedAt);
        case _TaskSortOrder.dueSoonest:
          if (a.dueAt == null && b.dueAt == null) return 0;
          if (a.dueAt == null) return 1;
          if (b.dueAt == null) return -1;
          return a.dueAt!.compareTo(b.dueAt!);
        case _TaskSortOrder.taskName:
          return a.taskName.toLowerCase().compareTo(b.taskName.toLowerCase());
      }
    });
    return tasks;
  }

  Widget _buildTaskFilters(
    BuildContext context,
    List<AssignedTask> tasks, {
    required bool assignedByMe,
  }) {
    final statusFilter = assignedByMe
        ? _assignedStatusFilter
        : _receivedStatusFilter;
    final tagFilter = assignedByMe ? _assignedTagFilter : _receivedTagFilter;
    final sortOrder = assignedByMe ? _assignedSortOrder : _receivedSortOrder;
    final tags = tasks.expand((task) => task.recipientLabels).toSet().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          TextField(
            key: Key(
              assignedByMe ? 'tasks-assigned-search' : 'tasks-received-search',
            ),
            decoration: InputDecoration(
              labelText: context.l10n.tasks_searchTasks,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => _setTaskSearchText(assignedByMe, value),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 170,
                child: DropdownButtonFormField<String>(
                  key: Key(
                    assignedByMe
                        ? 'tasks-assigned-status-filter'
                        : 'tasks-received-status-filter',
                  ),
                  initialValue: statusFilter,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.tasks_filterStatus,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text(context.l10n.tasks_filterAll),
                    ),
                    for (final status in AssignedTaskStatus.values)
                      DropdownMenuItem(
                        value: status.name,
                        child: Text(_taskStatusLabel(context, status)),
                      ),
                  ],
                  onChanged: (value) =>
                      _setTaskStatusFilter(assignedByMe, value ?? 'all'),
                ),
              ),
              SizedBox(
                width: 170,
                child: DropdownButtonFormField<_TaskSortOrder>(
                  key: Key(
                    assignedByMe
                        ? 'tasks-assigned-sort-order'
                        : 'tasks-received-sort-order',
                  ),
                  initialValue: sortOrder,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.tasks_sortBy,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: _TaskSortOrder.recentlyAssigned,
                      child: Text(context.l10n.tasks_sortRecentlyAssigned),
                    ),
                    DropdownMenuItem(
                      value: _TaskSortOrder.dueSoonest,
                      child: Text(context.l10n.tasks_sortDueSoonest),
                    ),
                    DropdownMenuItem(
                      value: _TaskSortOrder.taskName,
                      child: Text(context.l10n.tasks_sortTaskName),
                    ),
                  ],
                  onChanged: (value) => _setTaskSortOrder(
                    assignedByMe,
                    value ?? _TaskSortOrder.recentlyAssigned,
                  ),
                ),
              ),
              SizedBox(
                width: 170,
                child: DropdownButtonFormField<String>(
                  key: Key(
                    assignedByMe
                        ? 'tasks-assigned-tag-filter'
                        : 'tasks-received-tag-filter',
                  ),
                  initialValue: tags.contains(tagFilter) ? tagFilter : 'all',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.tasks_filterTag,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text(context.l10n.tasks_filterAllTags),
                    ),
                    for (final tag in tags)
                      DropdownMenuItem(value: tag, child: Text(tag)),
                  ],
                  onChanged: (value) =>
                      _setTaskTagFilter(assignedByMe, value ?? 'all'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TasksScreenState extends State<TasksScreen>
    with DisconnectNavigationMixin {
  static const double _dividerWidth = 24;
  static const double _minPaneFraction = 0.15;
  static const double _maxPaneFraction = 0.85;
  static const String _everyoneKey = 'everyone';
  static const String _selfKey = 'self';
  static const Uuid _uuid = Uuid();
  static final Expando<int> _lastResendSessionByConnector = Expando<int>();

  final ContactGroupStore _contactGroupStore = ContactGroupStore();
  final TextEditingController _taskNameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _editTaskNameController = TextEditingController();
  final TextEditingController _editDescriptionController =
      TextEditingController();
  final Set<String> _selectedRecipients = {};
  final Set<String> _expandedTaskIds = {};
  final Map<String, TextEditingController> _channelInputControllers = {};
  final Map<String, Map<int, String>> _incomingAssignmentParts = {};
  final Set<String> _processedTaskMessageIds = {};
  List<AssignedTask> _assignedTasks = [];

  MeshCoreConnector? _scopeSyncConnector;
  List<ContactGroup> _groups = [];
  String _loadedGroupScopeKeyHex = '';
  String _loadingGroupScopeKeyHex = '';
  String _loadedTaskScopeKeyHex = '';
  String _loadingTaskScopeKeyHex = '';
  double _splitFraction = 0.5;
  bool _isLoadingGroups = false;
  bool _isLoadingTasks = false;
  bool _isSavingTask = false;
  bool _isAssignFormOpen = false;
  bool _isProcessingTaskMessages = false;
  bool _taskMessagesPending = false;
  bool _automaticResendEnabled = true;
  String _assignedSearchText = '';
  String _receivedSearchText = '';
  String _assignedStatusFilter = 'all';
  String _receivedStatusFilter = 'all';
  String _assignedTagFilter = 'all';
  String _receivedTagFilter = 'all';
  _TaskSortOrder _assignedSortOrder = _TaskSortOrder.recentlyAssigned;
  _TaskSortOrder _receivedSortOrder = _TaskSortOrder.recentlyAssigned;
  AssignedTaskDueMode _dueMode = AssignedTaskDueMode.none;
  int _dueInHours = 1;
  DateTime? _dueDate;
  String? _validationMessage;
  String? _taskError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final connector = context.read<MeshCoreConnector>();
    if (!identical(_scopeSyncConnector, connector)) {
      _scopeSyncConnector?.removeListener(_handleConnectorScopeChange);
      _scopeSyncConnector = connector;
      _scopeSyncConnector?.addListener(_handleConnectorScopeChange);
    }
    _syncGroupScopeIfNeeded(connector);
    _syncTaskScopeIfNeeded(connector);
  }

  @override
  void dispose() {
    _scopeSyncConnector?.removeListener(_handleConnectorScopeChange);
    _taskNameController.dispose();
    _descriptionController.dispose();
    _editTaskNameController.dispose();
    _editDescriptionController.dispose();
    for (final controller in _channelInputControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _handleConnectorScopeChange() {
    final connector = _scopeSyncConnector;
    if (connector != null) {
      _syncGroupScopeIfNeeded(connector);
      _syncTaskScopeIfNeeded(connector);
      unawaited(_processTaskMessages(connector));
      unawaited(_resendForCurrentSession(connector));
    }
  }

  void _syncGroupScopeIfNeeded(MeshCoreConnector connector) {
    final scopeKey = connector.selfPublicKeyHex;
    if (scopeKey.isEmpty ||
        scopeKey == _loadedGroupScopeKeyHex ||
        scopeKey == _loadingGroupScopeKeyHex) {
      return;
    }
    _loadGroups(scopeKey);
  }

  Future<void> _loadGroups(String scopeKey) async {
    _loadingGroupScopeKeyHex = scopeKey;
    _contactGroupStore.setPublicKeyHex = scopeKey;
    if (mounted) {
      setState(() {
        _isLoadingGroups = true;
        if (_loadedGroupScopeKeyHex.isNotEmpty &&
            _loadedGroupScopeKeyHex != scopeKey) {
          _groups = [];
          _selectedRecipients.clear();
        }
      });
    }
    final groups = await _contactGroupStore.loadGroups();
    if (!mounted) return;
    if (_scopeSyncConnector?.selfPublicKeyHex != scopeKey) {
      if (_loadingGroupScopeKeyHex == scopeKey) {
        _loadingGroupScopeKeyHex = '';
        _isLoadingGroups = false;
        final connector = _scopeSyncConnector;
        if (connector != null) {
          _syncGroupScopeIfNeeded(connector);
        }
      }
      return;
    }
    _loadingGroupScopeKeyHex = '';
    setState(() {
      _groups = groups;
      _loadedGroupScopeKeyHex = scopeKey;
      _isLoadingGroups = false;
    });
  }

  void _syncTaskScopeIfNeeded(MeshCoreConnector connector) {
    final scopeKey = connector.selfPublicKeyHex;
    if (scopeKey.isEmpty ||
        scopeKey == _loadedTaskScopeKeyHex ||
        scopeKey == _loadingTaskScopeKeyHex) {
      return;
    }
    _loadTasks(scopeKey);
  }

  Future<void> _loadTasks(String scopeKey) async {
    // Load persisted task state for this radio identity and clear stale state
    // when switching between radios.
    _loadingTaskScopeKeyHex = scopeKey;
    if (mounted) {
      setState(() {
        _isLoadingTasks = true;
        _isSavingTask = false;
        _taskError = null;
        if (_loadedTaskScopeKeyHex.isNotEmpty &&
            _loadedTaskScopeKeyHex != scopeKey) {
          _assignedTasks = [];
          _loadedTaskScopeKeyHex = '';
        }
      });
    }

    final store = AssignedTaskStore()..setPublicKeyHex = scopeKey;
    final List<AssignedTask> tasks;
    try {
      tasks = await store.loadTasks();
    } catch (error) {
      appLogger.error('Failed to load assigned tasks: $error', tag: 'Tasks');
      if (!mounted || _scopeSyncConnector?.selfPublicKeyHex != scopeKey) {
        return;
      }
      _loadingTaskScopeKeyHex = '';
      setState(() {
        _isLoadingTasks = false;
        _taskError = context.l10n.tasks_loadFailed;
      });
      return;
    }

    if (!mounted) return;
    if (_scopeSyncConnector?.selfPublicKeyHex != scopeKey) {
      if (_loadingTaskScopeKeyHex == scopeKey) {
        _loadingTaskScopeKeyHex = '';
        _isLoadingTasks = false;
        final connector = _scopeSyncConnector;
        if (connector != null) {
          _syncTaskScopeIfNeeded(connector);
        }
      }
      return;
    }
    _loadingTaskScopeKeyHex = '';
    setState(() {
      _assignedTasks = tasks;
      _loadedTaskScopeKeyHex = scopeKey;
      _isLoadingTasks = false;
      _taskError = null;
    });
    final connector = _scopeSyncConnector;
    if (connector != null) {
      await _processTaskMessages(connector);
      await _resendForCurrentSession(connector);
    }
  }

  List<String> _recipientLabels(List<Contact> contacts) {
    final labels = <String>[];
    if (_selectedRecipients.contains(_everyoneKey)) {
      labels.add(context.l10n.tasks_everyone);
    }
    if (_selectedRecipients.contains(_selfKey)) {
      labels.add(context.l10n.tasks_myself);
    }
    for (final group in _groups) {
      if (_selectedRecipients.contains(_groupKey(group.name))) {
        labels.add(group.name);
      }
    }
    for (final contact in contacts) {
      if (_selectedRecipients.contains(_contactKey(contact.publicKeyHex))) {
        labels.add(contact.name);
      }
    }
    return labels;
  }

  String _groupKey(String name) => 'group:$name';

  String _contactKey(String publicKeyHex) => 'contact:$publicKeyHex';

  Future<void> _chooseRecipients(List<Contact> contacts) async {
    final workingSelection = Set<String>.from(_selectedRecipients);
    var query = '';
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final visibleGroups = _groups
              .where(
                (group) => group.name.toLowerCase().contains(
                  query.trim().toLowerCase(),
                ),
              )
              .toList();
          final visibleContacts = contacts
              .where(
                (contact) =>
                    contact.name.toLowerCase().contains(
                      query.trim().toLowerCase(),
                    ) ||
                    contact.publicKeyHex.toLowerCase().contains(
                      query.trim().toLowerCase(),
                    ),
              )
              .toList();

          return AlertDialog(
            title: Text(context.l10n.tasks_chooseRecipients),
            content: SizedBox(
              width: 440,
              height: 480,
              child: Column(
                children: [
                  TextField(
                    decoration: InputDecoration(
                      labelText: context.l10n.tasks_searchRecipients,
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (value) => setDialogState(() {
                      query = value;
                    }),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: workingSelection.contains(_everyoneKey),
                          title: Text(context.l10n.tasks_everyone),
                          onChanged: (value) {
                            setDialogState(() {
                              if (value ?? false) {
                                workingSelection.add(_everyoneKey);
                              } else {
                                workingSelection.remove(_everyoneKey);
                              }
                            });
                          },
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: workingSelection.contains(_selfKey),
                          title: Text(context.l10n.tasks_myself),
                          onChanged: (value) {
                            setDialogState(() {
                              if (value ?? false) {
                                workingSelection.add(_selfKey);
                              } else {
                                workingSelection.remove(_selfKey);
                              }
                            });
                          },
                        ),
                        if (_isLoadingGroups)
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(),
                            ),
                          )
                        else if (_groups.isNotEmpty) ...[
                          const Divider(),
                          ListTile(
                            dense: true,
                            title: Text(context.l10n.tasks_groups),
                          ),
                          for (final group in visibleGroups)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              value: workingSelection.contains(
                                _groupKey(group.name),
                              ),
                              title: Text(group.name),
                              subtitle: Text(
                                context.l10n.tasks_groupMemberCount(
                                  group.memberKeys.length,
                                ),
                              ),
                              onChanged: (value) {
                                setDialogState(() {
                                  final key = _groupKey(group.name);
                                  if (value ?? false) {
                                    workingSelection.add(key);
                                  } else {
                                    workingSelection.remove(key);
                                  }
                                });
                              },
                            ),
                        ],
                        if (contacts.isNotEmpty) ...[
                          const Divider(),
                          ListTile(
                            dense: true,
                            title: Text(context.l10n.tasks_contacts),
                          ),
                          for (final contact in visibleContacts)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              value: workingSelection.contains(
                                _contactKey(contact.publicKeyHex),
                              ),
                              title: Text(contact.name),
                              subtitle: Text(
                                contact.publicKeyHex,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onChanged: (value) {
                                setDialogState(() {
                                  final key = _contactKey(contact.publicKeyHex);
                                  if (value ?? false) {
                                    workingSelection.add(key);
                                  } else {
                                    workingSelection.remove(key);
                                  }
                                });
                              },
                            ),
                        ],
                        if (_groups.isEmpty && contacts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(context.l10n.tasks_noGroupsOrContacts),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(context.l10n.common_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  Set<String>.from(workingSelection),
                ),
                child: Text(context.l10n.common_done),
              ),
            ],
          );
        },
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selectedRecipients
        ..clear()
        ..addAll(selected);
      _validationMessage = null;
    });
  }

  Future<void> _selectDueDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? today,
      firstDate: today,
      lastDate: DateTime(2100),
    );
    if (selectedDate == null || !mounted) return;
    setState(() {
      _dueDate = selectedDate;
    });
  }

  List<Contact> _resolveTaskRecipients(List<Contact> contacts) {
    final selectedKeys = <String>{};
    if (_selectedRecipients.contains(_everyoneKey)) {
      selectedKeys.addAll(contacts.map((contact) => contact.publicKeyHex));
    }
    for (final group in _groups) {
      if (_selectedRecipients.contains(_groupKey(group.name))) {
        selectedKeys.addAll(group.memberKeys);
      }
    }
    for (final contact in contacts) {
      if (_selectedRecipients.contains(_contactKey(contact.publicKeyHex))) {
        selectedKeys.add(contact.publicKeyHex);
      }
    }
    return contacts
        .where(
          (contact) =>
              contact.type == advTypeChat &&
              selectedKeys.contains(contact.publicKeyHex),
        )
        .toList();
  }

  Future<int?> _configureTaskChannel(
    MeshCoreConnector connector,
    String name,
    Uint8List psk,
  ) async {
    if (!connector.isConnected || !connector.hasLoadedChannels) return null;

    final pskHex = _hex(psk);
    final matchingChannel = connector.channels.cast<Channel?>().firstWhere(
      (channel) => channel?.pskHex == pskHex,
      orElse: () => null,
    );
    if (matchingChannel != null) return matchingChannel.index;

    final occupiedIndices = connector.channels.map((channel) => channel.index);
    for (var index = 0; index < connector.maxChannels; index++) {
      if (occupiedIndices.contains(index)) continue;
      await connector.setChannel(index, name, psk);
      return index;
    }
    return null;
  }

  String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _saveTask(
    List<Contact> contacts,
    MeshCoreConnector connector,
  ) async {
    // Validate, configure the private task channel, persist locally, then send.
    final taskName = _taskNameController.text.trim();
    final recipientLabels = _recipientLabels(contacts);
    final recipients = _resolveTaskRecipients(contacts);
    final validationMessage = taskName.isEmpty
        ? context.l10n.tasks_taskNameRequired
        : utf8.encode(taskName).length > _taskNameMaxBytes
        ? context.l10n.tasks_taskNameTooLong
        : recipientLabels.isEmpty
        ? context.l10n.tasks_recipientRequired
        : recipients.isEmpty && !_selectedRecipients.contains(_selfKey)
        ? context.l10n.tasks_noReachableRecipients
        : _dueMode == AssignedTaskDueMode.longTerm && _dueDate == null
        ? context.l10n.tasks_dueDateRequired
        : null;

    if (validationMessage != null) {
      setState(() {
        _validationMessage = validationMessage;
      });
      return;
    }

    final scopeKey = connector.selfPublicKeyHex;
    if (scopeKey.isEmpty) {
      setState(() {
        _taskError = context.l10n.tasks_missingIdentity;
      });
      return;
    }
    if (scopeKey != _loadedTaskScopeKeyHex || _isSavingTask) return;

    if (!connector.hasLoadedChannels) {
      setState(() {
        _taskError = context.l10n.tasks_channelsNotReady;
      });
      return;
    }

    final dueAt = switch (_dueMode) {
      AssignedTaskDueMode.none => null,
      AssignedTaskDueMode.immediate => DateTime.now().add(
        Duration(hours: _dueInHours),
      ),
      AssignedTaskDueMode.longTerm => _dueDate,
    };
    setState(() {
      _isSavingTask = true;
      _taskError = null;
    });
    final id = _uuid.v4();
    final channelName = _taskChannelName(taskName, id);
    final channelPsk = randomBytes(16);
    final int? channelIndex;
    try {
      channelIndex = await _configureTaskChannel(
        connector,
        channelName,
        channelPsk,
      );
    } catch (error) {
      appLogger.error('Failed to configure task channel: $error', tag: 'Tasks');
      if (mounted) {
        setState(() {
          _isSavingTask = false;
          _taskError = context.l10n.tasks_channelSetupFailed;
        });
      }
      return;
    }
    if (!mounted) return;
    if (channelIndex == null) {
      setState(() {
        _isSavingTask = false;
        _taskError = context.l10n.tasks_channelSetupFailed;
      });
      return;
    }
    final task = AssignedTask(
      id: id,
      taskName: taskName,
      description: _descriptionController.text.trim(),
      recipientKeys: _selectedRecipients.toList(),
      recipientLabels: recipientLabels,
      expectedRecipientKeys: recipients
          .map((contact) => contact.publicKeyHex)
          .followedBy(
            _selectedRecipients.contains(_selfKey)
                ? [scopeKey]
                : const <String>[],
          )
          .toList(),
      receivedRecipientKeys: _selectedRecipients.contains(_selfKey)
          ? [scopeKey]
          : const [],
      assignedByKey: scopeKey,
      assignedByName: connector.selfName ?? '',
      channelName: channelName,
      channelPskHex: _hex(channelPsk),
      channelIndex: channelIndex,
      dueMode: _dueMode,
      dueAt: dueAt,
      assignedAt: DateTime.now(),
      automaticResendEnabled: _automaticResendEnabled,
    );
    final updatedTasks = List<AssignedTask>.from(_assignedTasks)
      ..insert(0, task);

    try {
      final store = AssignedTaskStore()..setPublicKeyHex = scopeKey;
      await store.saveTasks(updatedTasks);
    } catch (error) {
      appLogger.error('Failed to save assigned task: $error', tag: 'Tasks');
      if (!mounted) return;
      setState(() {
        _isSavingTask = false;
        _taskError = context.l10n.tasks_saveFailed;
      });
      return;
    }

    if (!mounted || _scopeSyncConnector?.selfPublicKeyHex != scopeKey) return;
    setState(() {
      _assignedTasks = updatedTasks;
      _isSavingTask = false;
      _isAssignFormOpen = false;
      _taskNameController.clear();
      _descriptionController.clear();
      _selectedRecipients.clear();
      _dueMode = AssignedTaskDueMode.none;
      _dueDate = null;
      _dueInHours = 1;
      _automaticResendEnabled = true;
      _validationMessage = null;
      _taskError = null;
    });
    unawaited(_sendTaskToRecipients(task, recipients, connector));
  }

  Future<void> _sendTaskToRecipients(
    AssignedTask task,
    List<Contact> recipients,
    MeshCoreConnector connector,
  ) async {
    // Direct assignments include the recipient count but omit the assigner's
    // recipient delivery and local channel UI tracking lists.
    final messageTask = AssignedTask(
      id: task.id,
      taskName: task.taskName,
      description: task.description,
      recipientKeys: task.recipientKeys,
      recipientLabels: task.recipientLabels,
      expectedRecipientCount: task.expectedRecipientKeys.length,
      assignedByKey: task.assignedByKey,
      assignedByName: task.assignedByName,
      channelName: task.channelName,
      channelPskHex: task.channelPskHex,
      dueMode: task.dueMode,
      dueAt: task.dueAt,
      assignedAt: task.assignedAt,
      updatedAt: task.updatedAt,
      automaticResendEnabled: task.automaticResendEnabled,
    );
    final messages = TaskMessageProtocol.encodeAssignment(messageTask);
    for (final recipient in recipients) {
      try {
        for (final message in messages) {
          await connector.sendMessage(recipient, message);
        }
      } catch (error) {
        appLogger.error(
          'Failed to send task ${task.id} to ${recipient.publicKeyHex}: $error',
          tag: 'Tasks',
        );
        if (mounted) {
          setState(() {
            _taskError = context.l10n.tasks_sendFailed;
          });
        }
      }
    }
  }

  Future<void> _resendUnreceivedTasks(MeshCoreConnector connector) async {
    // Automatic resend targets known chat contacts that are awaiting a receipt
    // and belong to the task's expected recipient list.
    if (!connector.isConnected ||
        connector.selfPublicKeyHex != _loadedTaskScopeKeyHex) {
      return;
    }
    for (final task in _assignedTasks) {
      if (task.assignedByKey.isNotEmpty &&
          task.assignedByKey != connector.selfPublicKeyHex) {
        continue;
      }
      if (!task.automaticResendEnabled) continue;
      final receivedKeys = task.receivedRecipientKeys.toSet();
      final recipients = task.expectedRecipientKeys
          .where((key) => !receivedKeys.contains(key))
          .map(connector.getContactByPubKeyHex)
          .whereType<Contact>()
          .where((contact) => contact.type == advTypeChat)
          .toList();
      if (recipients.isNotEmpty) {
        await _sendTaskToRecipients(task, recipients, connector);
      }
    }
  }

  Future<void> _resendForCurrentSession(MeshCoreConnector connector) async {
    if (!connector.isConnected ||
        !connector.hasLoadedContacts ||
        connector.selfPublicKeyHex != _loadedTaskScopeKeyHex ||
        _isLoadingTasks) {
      return;
    }
    final sessionId = connector.connectionSessionId;
    if (_lastResendSessionByConnector[connector] == sessionId) return;
    _lastResendSessionByConnector[connector] = sessionId;
    await _resendUnreceivedTasks(connector);
  }

  Future<void> _processTaskMessages(MeshCoreConnector connector) async {
    // Process direct assignments, receipts, task channels, and channel status
    // updates in one serialized pass, persisting only if task state changed.
    if (!mounted) return;
    if (_isProcessingTaskMessages) {
      _taskMessagesPending = true;
      return;
    }
    if (_isLoadingTasks ||
        connector.selfPublicKeyHex.isEmpty ||
        connector.selfPublicKeyHex != _loadedTaskScopeKeyHex) {
      return;
    }

    _isProcessingTaskMessages = true;
    try {
      final receiptsToSend = <({Contact contact, String taskId})>[];
      var changed = false;

      final chatContacts = connector.contacts
          .where((contact) => contact.type == advTypeChat)
          .toList();
      for (final contact in chatContacts) {
        await connector.loadMessagesForContact(contact);
      }

      final tasks = List<AssignedTask>.from(_assignedTasks);
      for (final contact in chatContacts) {
        for (final message in connector.getTaskProtocolMessages(contact)) {
          if (message.isOutgoing) continue;
          final messageKey =
              '${contact.publicKeyHex}:${message.messageId}:'
              '${message.timestamp.millisecondsSinceEpoch}';
          if (!_processedTaskMessageIds.add(messageKey)) continue;

          final part = TaskMessageProtocol.parseAssignmentPart(message.text);
          if (part != null) {
            final partKey = '${contact.publicKeyHex}:${part.taskId}';
            final parts = _incomingAssignmentParts.putIfAbsent(
              partKey,
              () => <int, String>{},
            );
            parts[part.index] = part.payload;
            if (parts.length == part.total) {
              final payload = List.generate(
                part.total,
                (index) => parts[index + 1] ?? '',
              ).join();
              final receivedTask = TaskMessageProtocol.decodeAssignment(
                payload,
              );
              _incomingAssignmentParts.remove(partKey);
              if (receivedTask == null ||
                  receivedTask.id != part.taskId ||
                  (receivedTask.assignedByKey.isNotEmpty &&
                      receivedTask.assignedByKey != contact.publicKeyHex)) {
                continue;
              }
              if (tasks.any((task) => task.id == receivedTask.id)) {
                receiptsToSend.add((contact: contact, taskId: receivedTask.id));
                continue;
              }
              tasks.insert(
                0,
                receivedTask.copyWith(
                  assignedByKey: contact.publicKeyHex,
                  assignedByName: contact.name,
                  expectedRecipientKeys: const [],
                  receivedRecipientKeys: const [],
                  clearChannelIndex: true,
                  channelOpened: false,
                ),
              );
              receiptsToSend.add((contact: contact, taskId: receivedTask.id));
              changed = true;
            }
            continue;
          }

          final receipt = TaskMessageProtocol.parseReceipt(message.text);
          if (receipt == null) continue;
          final taskIndex = tasks.indexWhere((task) => task.id == receipt);
          if (taskIndex < 0) continue;
          final task = tasks[taskIndex];
          if (!task.expectedRecipientKeys.contains(contact.publicKeyHex) ||
              task.receivedRecipientKeys.contains(contact.publicKeyHex)) {
            continue;
          }
          tasks[taskIndex] = task.copyWith(
            receivedRecipientKeys: [
              ...task.receivedRecipientKeys,
              contact.publicKeyHex,
            ],
          );
          changed = true;
        }
      }

      if (connector.hasLoadedChannels) {
        for (var index = 0; index < tasks.length; index++) {
          var task = tasks[index];
          if (task.channelPskHex.isNotEmpty && task.channelIndex == null) {
            final channelIndex = await _configureTaskChannel(
              connector,
              task.channelName,
              Channel.parsePskHex(task.channelPskHex),
            );
            if (channelIndex != null) {
              task = task.copyWith(channelIndex: channelIndex);
              tasks[index] = task;
              changed = true;
            }
          }

          final channel = _channelForTask(task, connector);
          if (channel == null) continue;
          for (final message in connector.getTaskProtocolChannelMessages(
            channel,
          )) {
            if (message.isOutgoing || message.senderKey == null) continue;
            final update = TaskMessageProtocol.parseStatusUpdate(message.text);
            if (update == null || update.taskId != task.id) continue;
            final memberKey = pubKeyToHex(message.senderKey!);
            if (update.status == AssignedTaskStatus.verifiedComplete &&
                memberKey != task.assignedByKey) {
              continue;
            }
            final current = task.memberStatuses[memberKey];
            final currentTime = DateTime.tryParse(
              current?['updated_at'] as String? ?? '',
            );
            if (currentTime != null &&
                !update.updatedAt.isAfter(currentTime.toUtc())) {
              continue;
            }
            final statuses =
                Map<String, Map<String, dynamic>>.from(task.memberStatuses)
                  ..[memberKey] = {
                    'status': update.status.name,
                    'updated_at': update.updatedAt.toUtc().toIso8601String(),
                  };
            task = task.copyWith(
              memberStatuses: statuses,
              updatedAt: update.updatedAt.isAfter(task.updatedAt)
                  ? update.updatedAt
                  : task.updatedAt,
            );
            tasks[index] = task;
            changed = true;
          }
        }
      }

      if (changed) {
        final store = AssignedTaskStore()
          ..setPublicKeyHex = connector.selfPublicKeyHex;
        await store.saveTasks(tasks);
        if (mounted) {
          setState(() {
            _assignedTasks = tasks;
          });
        }
      }

      for (final receipt in receiptsToSend) {
        await connector.sendMessage(
          receipt.contact,
          TaskMessageProtocol.encodeReceipt(receipt.taskId),
        );
      }
    } catch (error) {
      appLogger.error('Failed to process task messages: $error', tag: 'Tasks');
      if (mounted) {
        setState(() {
          _taskError = context.l10n.tasks_messageProcessingFailed;
        });
      }
    } finally {
      _isProcessingTaskMessages = false;
      if (_taskMessagesPending && mounted) {
        _taskMessagesPending = false;
        unawaited(_processTaskMessages(connector));
      }
    }
  }

  Channel? _channelForTask(AssignedTask task, MeshCoreConnector connector) {
    if (task.channelPskHex.isEmpty) return null;
    for (final channel in connector.channels) {
      if (channel.pskHex == task.channelPskHex) return channel;
    }
    return null;
  }

  Future<void> _updateTaskStatus(
    AssignedTask task,
    AssignedTaskStatus status,
    MeshCoreConnector connector,
  ) async {
    // Verified-complete is restricted to the assigner; the current member
    // receives the status and task timestamp is advanced monotonically.
    final selfKey = connector.selfPublicKeyHex;
    if (selfKey.isEmpty) return;
    if (status == AssignedTaskStatus.verifiedComplete &&
        task.assignedByKey != selfKey) {
      return;
    }
    final tasks = List<AssignedTask>.from(_assignedTasks);
    final index = tasks.indexWhere((item) => item.id == task.id);
    if (index < 0) return;
    final currentTask = tasks[index];
    final now = DateTime.now().toUtc();
    final updatedAt = now.isAfter(currentTask.updatedAt)
        ? now
        : currentTask.updatedAt.add(const Duration(milliseconds: 1));
    final statuses =
        Map<String, Map<String, dynamic>>.from(currentTask.memberStatuses)
          ..[selfKey] = {
            'status': status.name,
            'updated_at': updatedAt.toIso8601String(),
          };
    final updatedTask = currentTask.copyWith(
      memberStatuses: statuses,
      updatedAt: updatedAt,
    );
    tasks[index] = updatedTask;
    try {
      final store = AssignedTaskStore()..setPublicKeyHex = selfKey;
      await store.saveTasks(tasks);
      if (!mounted) return;
      setState(() {
        _assignedTasks = tasks;
      });
      final channel = _channelForTask(updatedTask, connector);
      if (channel != null) {
        await connector.sendChannelMessage(
          channel,
          TaskMessageProtocol.encodeStatusUpdate(task.id, status, updatedAt),
        );
      } else {
        setState(() {
          _taskError = context.l10n.tasks_channelUnavailable;
        });
      }
    } catch (error) {
      appLogger.error('Failed to update task status: $error', tag: 'Tasks');
      if (mounted) {
        setState(() {
          _taskError = context.l10n.tasks_saveFailed;
        });
      }
    }
  }

  Future<void> _setAutomaticResend(
    AssignedTask task,
    bool enabled,
    MeshCoreConnector connector,
  ) async {
    final tasks = List<AssignedTask>.from(_assignedTasks);
    final index = tasks.indexWhere((item) => item.id == task.id);
    if (index < 0) return;
    tasks[index] = tasks[index].copyWith(automaticResendEnabled: enabled);
    try {
      final store = AssignedTaskStore()
        ..setPublicKeyHex = connector.selfPublicKeyHex;
      await store.saveTasks(tasks);
      if (!mounted) return;
      setState(() {
        _assignedTasks = tasks;
      });
    } catch (error) {
      appLogger.error(
        'Failed to update task resend preference: $error',
        tag: 'Tasks',
      );
      if (mounted) {
        setState(() {
          _taskError = context.l10n.tasks_saveFailed;
        });
      }
    }
  }

  Future<void> _sendTaskUpdateToChannel(
    AssignedTask task,
    MeshCoreConnector connector,
  ) async {
    final channel = _channelForTask(task, connector);
    if (channel == null) {
      if (mounted) {
        setState(() {
          _taskError = context.l10n.tasks_channelUnavailable;
        });
      }
      return;
    }
    try {
      for (final part in TaskMessageProtocol.encodeTaskUpdate(task)) {
        await connector.sendChannelMessage(channel, part);
      }
      if (mounted) {
        setState(() {
          _taskError = null;
        });
      }
    } catch (error) {
      appLogger.error('Failed to share task update: $error', tag: 'Tasks');
      if (mounted) {
        setState(() {
          _taskError = context.l10n.tasks_updateSendFailed;
        });
      }
    }
  }

  Future<void> _editTask(AssignedTask task, MeshCoreConnector connector) async {
    // Editing is assigner-only and publishes a timestamped snapshot to the
    // task channel.
    if (task.assignedByKey != connector.selfPublicKeyHex) return;
    _editTaskNameController.text = task.taskName;
    _editDescriptionController.text = task.description;
    var dueMode = task.dueMode;
    DateTime? dueDate = task.dueAt;
    var dueInHours = task.dueAt == null
        ? 1
        : task.dueAt!.difference(DateTime.now()).inHours.clamp(1, 24).toInt();
    var validationMessage = '';
    final result = await showDialog<AssignedTask>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.l10n.tasks_editTask),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('tasks-edit-name-field'),
                    controller: _editTaskNameController,
                    maxLength: _taskNameMaxBytes,
                    inputFormatters: const [
                      Utf8LengthLimitingTextInputFormatter(_taskNameMaxBytes),
                    ],
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: context.l10n.tasks_taskName,
                    ),
                  ),
                  TextField(
                    key: const Key('tasks-edit-description-field'),
                    controller: _editDescriptionController,
                    maxLength: 500,
                    minLines: 3,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: context.l10n.tasks_descriptionOptional,
                    ),
                  ),
                  DropdownButtonFormField<AssignedTaskDueMode>(
                    isExpanded: true,
                    initialValue: dueMode,
                    decoration: InputDecoration(
                      labelText: context.l10n.tasks_dueDate,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: AssignedTaskDueMode.none,
                        child: Text(context.l10n.tasks_noDueDate),
                      ),
                      DropdownMenuItem(
                        value: AssignedTaskDueMode.immediate,
                        child: Text(context.l10n.tasks_immediate),
                      ),
                      DropdownMenuItem(
                        value: AssignedTaskDueMode.longTerm,
                        child: Text(context.l10n.tasks_longTerm),
                      ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      dueMode = value ?? AssignedTaskDueMode.none;
                      validationMessage = '';
                      if (dueMode != AssignedTaskDueMode.longTerm) {
                        dueDate = null;
                      }
                    }),
                  ),
                  if (dueMode == AssignedTaskDueMode.immediate)
                    DropdownButtonFormField<int>(
                      isExpanded: true,
                      initialValue: dueInHours,
                      decoration: InputDecoration(
                        labelText: context.l10n.tasks_completeWithin,
                      ),
                      items: [
                        for (var hours = 1; hours <= 24; hours++)
                          DropdownMenuItem(
                            value: hours,
                            child: Text(context.l10n.tasks_hours(hours)),
                          ),
                      ],
                      onChanged: (value) => setDialogState(() {
                        dueInHours = value ?? 1;
                      }),
                    ),
                  if (dueMode == AssignedTaskDueMode.longTerm)
                    TextButton.icon(
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text(
                        dueDate == null
                            ? context.l10n.tasks_chooseDate
                            : MaterialLocalizations.of(
                                context,
                              ).formatMediumDate(dueDate!),
                      ),
                      onPressed: () async {
                        final today = DateUtils.dateOnly(DateTime.now());
                        final initialDate =
                            dueDate != null && !dueDate!.isBefore(today)
                            ? dueDate!
                            : today;
                        final selected = await showDatePicker(
                          context: context,
                          initialDate: initialDate,
                          firstDate: today,
                          lastDate: DateTime(2100),
                        );
                        if (selected != null) {
                          setDialogState(() {
                            dueDate = selected;
                            validationMessage = '';
                          });
                        }
                      },
                    ),
                  if (validationMessage.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        validationMessage,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () {
                final taskName = _editTaskNameController.text.trim();
                if (taskName.isEmpty) {
                  setDialogState(() {
                    validationMessage = context.l10n.tasks_taskNameRequired;
                  });
                  return;
                }
                if (utf8.encode(taskName).length > _taskNameMaxBytes) {
                  setDialogState(() {
                    validationMessage = context.l10n.tasks_taskNameTooLong;
                  });
                  return;
                }
                if (dueMode == AssignedTaskDueMode.longTerm &&
                    dueDate == null) {
                  setDialogState(() {
                    validationMessage = context.l10n.tasks_dueDateRequired;
                  });
                  return;
                }
                final dueAt = switch (dueMode) {
                  AssignedTaskDueMode.none => null,
                  AssignedTaskDueMode.immediate => DateTime.now().add(
                    Duration(hours: dueInHours),
                  ),
                  AssignedTaskDueMode.longTerm => dueDate,
                };
                final now = DateTime.now().toUtc();
                Navigator.pop(
                  dialogContext,
                  task.copyWith(
                    taskName: taskName,
                    channelName: _taskChannelName(taskName, task.id),
                    description: _editDescriptionController.text.trim(),
                    dueMode: dueMode,
                    dueAt: dueAt,
                    clearDueAt: dueAt == null,
                    updatedAt: now.isAfter(task.updatedAt)
                        ? now
                        : task.updatedAt.add(const Duration(milliseconds: 1)),
                  ),
                );
              },
              child: Text(context.l10n.common_save),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;

    final tasks = List<AssignedTask>.from(_assignedTasks);
    final index = tasks.indexWhere((item) => item.id == task.id);
    if (index < 0) return;
    tasks[index] = result;
    try {
      if (result.channelName != task.channelName) {
        final channel = _channelForTask(task, connector);
        if (channel != null) {
          await connector.setChannel(
            channel.index,
            result.channelName,
            channel.psk,
          );
        }
      }
      final store = AssignedTaskStore()
        ..setPublicKeyHex = connector.selfPublicKeyHex;
      await store.saveTasks(tasks);
      if (!mounted) return;
      setState(() {
        _assignedTasks = tasks;
        _taskError = null;
      });
      await _sendTaskUpdateToChannel(result, connector);
    } catch (error) {
      appLogger.error('Failed to edit task: $error', tag: 'Tasks');
      if (mounted) {
        setState(() {
          _taskError = context.l10n.tasks_saveFailed;
        });
      }
    }
  }

  Future<void> _sendTaskChannelMessage(
    AssignedTask task,
    MeshCoreConnector connector,
  ) async {
    final controller = _channelInputControllers[task.id];
    final text = controller?.text.trim() ?? '';
    if (text.isEmpty) return;
    final channel = _channelForTask(task, connector);
    if (channel == null) {
      setState(() {
        _taskError = context.l10n.tasks_channelUnavailable;
      });
      return;
    }
    if (utf8.encode(text).length > maxChannelMessageBytes(connector.selfName)) {
      setState(() {
        _taskError = context.l10n.tasks_channelMessageTooLong;
      });
      return;
    }
    try {
      await connector.sendChannelMessage(channel, text);
      controller?.clear();
      if (mounted) {
        setState(() {
          _taskError = null;
        });
      }
    } catch (error) {
      appLogger.error(
        'Failed to send task channel message: $error',
        tag: 'Tasks',
      );
      if (mounted) {
        setState(() {
          _taskError = context.l10n.tasks_sendFailed;
        });
      }
    }
  }

  Future<void> _openTaskChannel(
    AssignedTask task,
    MeshCoreConnector connector,
  ) async {
    // Opening configures a missing task channel or reveals an existing one,
    // then persists the channel index and opened preference.
    try {
      var channel = _channelForTask(task, connector);
      if (channel == null && task.channelPskHex.isNotEmpty) {
        final index = await _configureTaskChannel(
          connector,
          task.channelName,
          Channel.parsePskHex(task.channelPskHex),
        );
        if (index != null) {
          final tasks = List<AssignedTask>.from(_assignedTasks);
          final taskIndex = tasks.indexWhere((item) => item.id == task.id);
          if (taskIndex >= 0) {
            final updated = task.copyWith(
              channelIndex: index,
              channelOpened: true,
            );
            tasks[taskIndex] = updated;
            final store = AssignedTaskStore()
              ..setPublicKeyHex = connector.selfPublicKeyHex;
            await store.saveTasks(tasks);
            if (mounted) {
              setState(() {
                _assignedTasks = tasks;
              });
            }
            channel = _channelForTask(updated, connector);
          }
        }
      } else if (channel != null && !task.channelOpened) {
        final tasks = List<AssignedTask>.from(_assignedTasks);
        final taskIndex = tasks.indexWhere((item) => item.id == task.id);
        if (taskIndex >= 0) {
          tasks[taskIndex] = task.copyWith(
            channelIndex: channel.index,
            channelOpened: true,
          );
          final store = AssignedTaskStore()
            ..setPublicKeyHex = connector.selfPublicKeyHex;
          await store.saveTasks(tasks);
          if (mounted) {
            setState(() {
              _assignedTasks = tasks;
            });
          }
        }
      }
      final openedChannel = channel;
      if (openedChannel == null || !mounted) {
        if (mounted) {
          setState(() {
            _taskError = context.l10n.tasks_channelUnavailable;
          });
        }
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChannelChatScreen(
            channel: openedChannel,
            initialUnreadCount: connector.getUnreadCountForChannel(
              openedChannel,
            ),
          ),
        ),
      );
      if (mounted && connector.selfPublicKeyHex == _loadedTaskScopeKeyHex) {
        await _loadTasks(connector.selfPublicKeyHex);
      }
    } catch (error) {
      appLogger.error('Failed to open task channel: $error', tag: 'Tasks');
      if (mounted) {
        setState(() {
          _taskError = context.l10n.tasks_channelUnavailable;
        });
      }
    }
  }

  Widget _buildAssignForm(BuildContext context, MeshCoreConnector connector) {
    final contacts = connector.contacts
        .where((contact) => contact.type == advTypeChat)
        .toList();
    final selectedLabels = _recipientLabels(contacts);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          key: const Key('tasks-choose-recipients'),
          onPressed: () => _chooseRecipients(contacts),
          icon: const Icon(Icons.people_outline),
          label: Text(
            selectedLabels.isEmpty
                ? context.l10n.tasks_chooseRecipients
                : context.l10n.tasks_recipientsSelected(
                    _selectedRecipients.length,
                  ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (selectedLabels.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: selectedLabels
                  .map((label) => Chip(label: Text(label)))
                  .toList(),
            ),
          ),
        const SizedBox(height: 12),
        DropdownButtonFormField<AssignedTaskDueMode>(
          isExpanded: true,
          initialValue: _dueMode,
          decoration: InputDecoration(
            labelText: context.l10n.tasks_dueDate,
            border: const OutlineInputBorder(),
          ),
          items: [
            DropdownMenuItem(
              value: AssignedTaskDueMode.none,
              child: Text(context.l10n.tasks_noDueDate),
            ),
            DropdownMenuItem(
              value: AssignedTaskDueMode.immediate,
              child: Text(context.l10n.tasks_immediate),
            ),
            DropdownMenuItem(
              value: AssignedTaskDueMode.longTerm,
              child: Text(context.l10n.tasks_longTerm),
            ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _dueMode = value;
              if (value != AssignedTaskDueMode.longTerm) _dueDate = null;
              _validationMessage = null;
            });
          },
        ),
        if (_dueMode == AssignedTaskDueMode.immediate) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: _dueInHours,
            decoration: InputDecoration(
              labelText: context.l10n.tasks_completeWithin,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (var hours = 1; hours <= 24; hours++)
                DropdownMenuItem(
                  value: hours,
                  child: Text(context.l10n.tasks_hours(hours)),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _dueInHours = value;
              });
            },
          ),
        ],
        if (_dueMode == AssignedTaskDueMode.longTerm) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('tasks-select-due-date'),
            onPressed: _selectDueDate,
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text(
              _dueDate == null
                  ? context.l10n.tasks_chooseDate
                  : MaterialLocalizations.of(
                      context,
                    ).formatMediumDate(_dueDate!),
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          key: const Key('tasks-name-field'),
          controller: _taskNameController,
          maxLength: _taskNameMaxBytes,
          inputFormatters: const [
            Utf8LengthLimitingTextInputFormatter(_taskNameMaxBytes),
          ],
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: context.l10n.tasks_taskName,
            hintText: context.l10n.tasks_taskNameHint,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) {
            if (_validationMessage != null) {
              setState(() {
                _validationMessage = null;
              });
            }
          },
        ),
        const SizedBox(height: 4),
        TextField(
          key: const Key('tasks-description-field'),
          controller: _descriptionController,
          maxLength: 500,
          minLines: 3,
          maxLines: 5,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: context.l10n.tasks_descriptionOptional,
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _automaticResendEnabled,
          title: Text(
            context.l10n.tasks_automaticResend,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (value) {
            setState(() {
              _automaticResendEnabled = value ?? false;
            });
          },
        ),
        if (_validationMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _validationMessage!,
              style: TextStyle(color: scheme.error),
            ),
          ),
        FilledButton.icon(
          key: const Key('tasks-submit-task'),
          onPressed:
              _isSavingTask ||
                  _isLoadingTasks ||
                  _loadedTaskScopeKeyHex != connector.selfPublicKeyHex
              ? null
              : () => _saveTask(contacts, connector),
          icon: _isSavingTask
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_task),
          label: Text(context.l10n.tasks_saveTask),
        ),
      ],
    );
  }

  void _setTaskSearchText(bool assignedByMe, String value) {
    setState(() {
      if (assignedByMe) {
        _assignedSearchText = value;
      } else {
        _receivedSearchText = value;
      }
    });
  }

  void _setTaskStatusFilter(bool assignedByMe, String value) {
    setState(() {
      if (assignedByMe) {
        _assignedStatusFilter = value;
      } else {
        _receivedStatusFilter = value;
      }
    });
  }

  void _setTaskTagFilter(bool assignedByMe, String value) {
    setState(() {
      if (assignedByMe) {
        _assignedTagFilter = value;
      } else {
        _receivedTagFilter = value;
      }
    });
  }

  void _setTaskSortOrder(bool assignedByMe, _TaskSortOrder value) {
    setState(() {
      if (assignedByMe) {
        _assignedSortOrder = value;
      } else {
        _receivedSortOrder = value;
      }
    });
  }

  String _taskStatusLabel(BuildContext context, AssignedTaskStatus status) =>
      switch (status) {
        AssignedTaskStatus.untouched => context.l10n.tasks_statusUntouched,
        AssignedTaskStatus.working => context.l10n.tasks_statusWorking,
        AssignedTaskStatus.completed => context.l10n.tasks_statusCompleted,
        AssignedTaskStatus.verifiedComplete =>
          context.l10n.tasks_statusVerifiedComplete,
      };

  String _formatDateTime(BuildContext context, DateTime dateTime) {
    final materialLocalizations = MaterialLocalizations.of(context);
    return '${materialLocalizations.formatMediumDate(dateTime)}, '
        '${materialLocalizations.formatTimeOfDay(TimeOfDay.fromDateTime(dateTime))}';
  }

  Widget _buildTaskCard(
    BuildContext context,
    AssignedTask task,
    MeshCoreConnector connector, {
    required bool assignedByMe,
  }) {
    final expanded = _expandedTaskIds.contains(task.id);
    final workingNames = task.workingMemberKeys.map((key) {
      if (key == connector.selfPublicKeyHex) {
        return connector.selfName ?? context.l10n.tasks_you;
      }
      return connector.getContactByPubKeyHex(key)?.name ?? key;
    }).toList();
    final channel = _channelForTask(task, connector);
    final canVerifyComplete = task.assignedByKey == connector.selfPublicKeyHex;
    final channelMessages = channel == null
        ? const []
        : connector
              .getChannelMessages(channel)
              .where(
                (message) =>
                    !TaskMessageProtocol.isProtocolMessage(message.text),
              )
              .toList();
    final inputController = _channelInputControllers.putIfAbsent(
      task.id,
      TextEditingController.new,
    );
    final materialLocalizations = MaterialLocalizations.of(context);

    return Card(
      key: ValueKey(
        '${assignedByMe ? 'assigned' : 'received'}-task-${task.id}',
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PopupMenuButton<AssignedTaskStatus>(
                  key: Key('tasks-status-menu-${task.id}'),
                  tooltip: _taskStatusLabel(context, task.status),
                  icon: Icon(switch (task.status) {
                    AssignedTaskStatus.untouched =>
                      Icons.radio_button_unchecked,
                    AssignedTaskStatus.working => Icons.pending_outlined,
                    AssignedTaskStatus.completed => Icons.check_circle_outline,
                    AssignedTaskStatus.verifiedComplete => Icons.done_all,
                  }, semanticLabel: _taskStatusLabel(context, task.status)),
                  onSelected: (status) =>
                      unawaited(_updateTaskStatus(task, status, connector)),
                  itemBuilder: (context) => AssignedTaskStatus.values
                      .where(
                        (status) =>
                            status != AssignedTaskStatus.verifiedComplete ||
                            canVerifyComplete,
                      )
                      .map(
                        (status) => PopupMenuItem(
                          value: status,
                          child: Text(_taskStatusLabel(context, status)),
                        ),
                      )
                      .toList(),
                ),
                Expanded(
                  child: Text(
                    task.taskName,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (assignedByMe)
              Text(
                task.recipientLabels.join(', '),
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              Text(
                context.l10n.tasks_assignedBy(
                  task.assignedByName.isEmpty
                      ? context.l10n.tasks_unknownAssigner
                      : task.assignedByName,
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (!assignedByMe && task.recipientLabels.isNotEmpty)
              Text(
                task.recipientLabels.join(', '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            Text(
              context.l10n.tasks_assignedOn(
                _formatDateTime(context, task.assignedAt),
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (task.dueAt == null)
              Text(
                context.l10n.tasks_noDueDate,
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              Text(
                context.l10n.tasks_dueOn(
                  [
                    materialLocalizations.formatMediumDate(task.dueAt!),
                    if (task.dueMode == AssignedTaskDueMode.immediate)
                      materialLocalizations.formatTimeOfDay(
                        TimeOfDay.fromDateTime(task.dueAt!),
                      ),
                  ].join(', '),
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (workingNames.isNotEmpty)
              Tooltip(
                message: workingNames.join(', '),
                child: Text(
                  context.l10n.tasks_workingMembers(workingNames.join(', ')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (assignedByMe)
              Text(
                context.l10n.tasks_deliveryCount(
                  task.receivedRecipientKeys.length,
                  task.expectedRecipientKeys.length,
                ),
                key: Key('tasks-delivery-count-${task.id}'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (assignedByMe)
              SwitchListTile(
                key: Key('tasks-auto-resend-${task.id}'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  context.l10n.tasks_automaticResend,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: task.automaticResendEnabled,
                onChanged: (enabled) =>
                    unawaited(_setAutomaticResend(task, enabled, connector)),
              ),
            if (assignedByMe &&
                task.assignedByKey == connector.selfPublicKeyHex)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('tasks-edit-${task.id}'),
                  onPressed: () => unawaited(_editTask(task, connector)),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(context.l10n.tasks_editTask),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: Key('tasks-expand-${task.id}'),
                onPressed: () {
                  setState(() {
                    if (expanded) {
                      _expandedTaskIds.remove(task.id);
                    } else {
                      _expandedTaskIds.add(task.id);
                    }
                  });
                },
                icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                label: Text(
                  expanded
                      ? context.l10n.tasks_collapse
                      : context.l10n.tasks_expand,
                ),
              ),
            ),
            if (expanded) ...[
              if (task.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(task.description),
                ),
              Text(
                context.l10n.tasks_taskChannel,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (channelMessages.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    channel == null
                        ? context.l10n.tasks_channelUnavailable
                        : context.l10n.tasks_noChannelMessages,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                for (final message in channelMessages.reversed.take(3))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${message.senderName}: ${message.text}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: Key('tasks-channel-input-${task.id}'),
                      controller: inputController,
                      maxLength: maxChannelMessageBytes(connector.selfName),
                      decoration: InputDecoration(
                        hintText: context.l10n.tasks_channelMessage,
                        isDense: true,
                      ),
                      onSubmitted: (_) =>
                          unawaited(_sendTaskChannelMessage(task, connector)),
                    ),
                  ),
                  IconButton(
                    key: Key('tasks-channel-send-${task.id}'),
                    tooltip: context.l10n.tasks_send,
                    onPressed: () =>
                        unawaited(_sendTaskChannelMessage(task, connector)),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
              OutlinedButton.icon(
                key: Key('tasks-open-channel-${task.id}'),
                onPressed: () => unawaited(_openTaskChannel(task, connector)),
                icon: const Icon(Icons.open_in_new),
                label: Text(context.l10n.tasks_openChannel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAssignedTaskList(
    BuildContext context,
    MeshCoreConnector connector,
    List<AssignedTask> assignedTasks,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_taskError != null) ...[
          Text(
            _taskError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          if (_loadedTaskScopeKeyHex.isEmpty)
            TextButton(
              onPressed: () {
                final currentConnector = _scopeSyncConnector;
                if (currentConnector != null) {
                  _syncTaskScopeIfNeeded(currentConnector);
                }
              },
              child: Text(context.l10n.tasks_retryLoad),
            ),
        ],
        if (_isLoadingTasks)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (assignedTasks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(context.l10n.tasks_noAssignedTasks),
          )
        else
          for (final task in assignedTasks)
            _buildTaskCard(context, task, connector, assignedByMe: true),
      ],
    );
  }

  Widget _buildReceivedTaskList(
    BuildContext context,
    MeshCoreConnector connector,
  ) {
    final receivedTasks = _filterAndSortTasks(
      _assignedTasks
          .where(
            (task) =>
                (task.assignedByKey.isNotEmpty &&
                    task.assignedByKey != connector.selfPublicKeyHex) ||
                task.recipientKeys.contains(_selfKey),
          )
          .toList(),
      assignedByMe: false,
    );
    return ListView(
      key: const Key('tasks-right-section'),
      padding: const EdgeInsets.all(12),
      children: [
        Text(
          context.l10n.tasks_lookingSection,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        _buildTaskFilters(context, receivedTasks, assignedByMe: false),
        if (_isLoadingTasks)
          const Center(child: CircularProgressIndicator())
        else if (receivedTasks.isEmpty)
          Text(context.l10n.tasks_noReceivedTasks)
        else
          for (final task in receivedTasks)
            _buildTaskCard(context, task, connector, assignedByMe: false),
      ],
    );
  }

  Widget _buildAssignPane(BuildContext context, MeshCoreConnector connector) {
    final scheme = Theme.of(context).colorScheme;
    final assignedSource = _assignedTasks
        .where(
          (task) =>
              task.assignedByKey.isEmpty ||
              task.assignedByKey == connector.selfPublicKeyHex,
        )
        .toList();
    final assignedTasks = _filterAndSortTasks(
      assignedSource,
      assignedByMe: true,
    );
    return ListView(
      key: const Key('tasks-left-section'),
      padding: const EdgeInsets.all(12),
      children: [
        Text(
          context.l10n.tasks_assignSection,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          context.l10n.tasks_storageNotice,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('tasks-toggle-form'),
          onPressed: () {
            setState(() {
              _isAssignFormOpen = !_isAssignFormOpen;
              _validationMessage = null;
            });
          },
          icon: Icon(_isAssignFormOpen ? Icons.close : Icons.add_task),
          label: Text(
            _isAssignFormOpen
                ? context.l10n.tasks_closeForm
                : context.l10n.tasks_openForm,
          ),
        ),
        if (_isAssignFormOpen) ...[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildAssignForm(context, connector),
            ),
          ),
        ],
        const Divider(height: 28),
        Text(
          context.l10n.tasks_assignedTasks,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        _buildTaskFilters(context, assignedSource, assignedByMe: true),
        _buildAssignedTaskList(context, connector, assignedTasks),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    if (!checkConnectionAndNavigate(connector)) {
      return const SizedBox.shrink();
    }

    return Scaffold(
      appBar: AppBar(
        title: AppBarTitle(context.l10n.nav_tasks),
        automaticallyImplyLeading: false,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final dividerWidth = constraints.maxWidth < _dividerWidth
              ? constraints.maxWidth
              : _dividerWidth;
          final availableWidth = constraints.maxWidth - dividerWidth;
          final leftWidth = availableWidth * _splitFraction;

          return Row(
            children: [
              SizedBox(
                width: leftWidth,
                child: _buildAssignPane(context, connector),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (details) {
                    if (availableWidth <= 0) return;
                    setState(() {
                      _splitFraction =
                          (_splitFraction + details.delta.dx / availableWidth)
                              .clamp(_minPaneFraction, _maxPaneFraction);
                    });
                  },
                  child: SizedBox(
                    key: const Key('tasks-splitter'),
                    width: dividerWidth,
                    child: Center(
                      child: Container(
                        width: 1,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(child: _buildReceivedTaskList(context, connector)),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: QuickSwitchBar(
          selectedIndex: 3,
          onDestinationSelected: (index) {
            switch (index) {
              case 0:
                Navigator.pushReplacement(
                  context,
                  buildQuickSwitchRoute(
                    const ContactsScreen(hideBackButton: true),
                  ),
                );
                break;
              case 1:
                Navigator.pushReplacement(
                  context,
                  buildQuickSwitchRoute(
                    const ChannelsScreen(hideBackButton: true),
                  ),
                );
                break;
              case 2:
                Navigator.pushReplacement(
                  context,
                  buildQuickSwitchRoute(const MapScreen(hideBackButton: true)),
                );
                break;
            }
          },
          contactsUnreadCount: connector.getTotalContactsUnreadCount(),
          channelsUnreadCount: connector.getTotalChannelsUnreadCount(),
        ),
      ),
    );
  }
}

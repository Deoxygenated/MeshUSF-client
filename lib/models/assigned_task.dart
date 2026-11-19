enum AssignedTaskDueMode { none, immediate, longTerm }

enum AssignedTaskStatus { untouched, working, completed, verifiedComplete }

class AssignedTask {
  final String id;
  final String taskName;
  final String description;
  final List<String> recipientKeys;
  final List<String> recipientLabels;
  final List<String> expectedRecipientKeys;
  final int expectedRecipientCount;
  final List<String> receivedRecipientKeys;
  final String assignedByKey;
  final String assignedByName;
  final String channelName;
  final String channelPskHex;
  final int? channelIndex;
  final bool channelOpened;
  final Map<String, Map<String, dynamic>> memberStatuses;
  final AssignedTaskDueMode dueMode;
  final DateTime? dueAt;
  final DateTime assignedAt;
  final DateTime updatedAt;
  final bool automaticResendEnabled;

  const AssignedTask({
    required this.id,
    required this.taskName,
    required this.description,
    required this.recipientKeys,
    required this.recipientLabels,
    this.expectedRecipientKeys = const [],
    this.expectedRecipientCount = 0,
    this.receivedRecipientKeys = const [],
    this.assignedByKey = '',
    this.assignedByName = '',
    this.channelName = '',
    this.channelPskHex = '',
    this.channelIndex,
    this.channelOpened = false,
    this.memberStatuses = const {},
    required this.dueMode,
    required this.dueAt,
    required this.assignedAt,
    DateTime? updatedAt,
    required this.automaticResendEnabled,
  }) : updatedAt = updatedAt ?? assignedAt;

  AssignedTaskStatus get status {
    // Assigner verification wins, then exact recipient completion is checked
    // before generic partial-completion and working states.
    if (memberStatuses[assignedByKey]?['status'] ==
        AssignedTaskStatus.verifiedComplete.name) {
      return AssignedTaskStatus.verifiedComplete;
    }
    final expectedCount = expectedRecipientCount > 0
        ? expectedRecipientCount
        : expectedRecipientKeys.length;
    final completedRecipientCount = memberStatuses.values
        .where(
          (update) => update['status'] == AssignedTaskStatus.completed.name,
        )
        .length;
    final allExpectedRecipientsCompleted =
        expectedCount > 0 &&
        (expectedRecipientKeys.isNotEmpty
            ? expectedRecipientKeys.every(
                (key) =>
                    memberStatuses[key]?['status'] ==
                    AssignedTaskStatus.completed.name,
              )
            : completedRecipientCount >= expectedCount);
    if (allExpectedRecipientsCompleted) {
      return AssignedTaskStatus.verifiedComplete;
    }
    if (completedRecipientCount > 0) {
      return AssignedTaskStatus.completed;
    }
    if (memberStatuses.values.any(
      (update) => update['status'] == AssignedTaskStatus.working.name,
    )) {
      return AssignedTaskStatus.working;
    }
    return AssignedTaskStatus.untouched;
  }

  List<String> get workingMemberKeys => memberStatuses.entries
      .where(
        (entry) => entry.value['status'] == AssignedTaskStatus.working.name,
      )
      .map((entry) => entry.key)
      .toList();

  // Copy preserves immutable task identity and only replaces explicitly supplied fields.
  AssignedTask copyWith({
    String? taskName,
    String? channelName,
    String? description,
    List<String>? recipientKeys,
    List<String>? recipientLabels,
    List<String>? expectedRecipientKeys,
    int? expectedRecipientCount,
    List<String>? receivedRecipientKeys,
    Map<String, Map<String, dynamic>>? memberStatuses,
    int? channelIndex,
    bool clearChannelIndex = false,
    bool? channelOpened,
    bool? automaticResendEnabled,
    String? assignedByKey,
    String? assignedByName,
    AssignedTaskDueMode? dueMode,
    DateTime? dueAt,
    bool clearDueAt = false,
    DateTime? updatedAt,
  }) => AssignedTask(
    id: id,
    taskName: taskName ?? this.taskName,
    description: description ?? this.description,
    recipientKeys: recipientKeys ?? this.recipientKeys,
    recipientLabels: recipientLabels ?? this.recipientLabels,
    expectedRecipientKeys: expectedRecipientKeys ?? this.expectedRecipientKeys,
    expectedRecipientCount:
        expectedRecipientCount ?? this.expectedRecipientCount,
    receivedRecipientKeys: receivedRecipientKeys ?? this.receivedRecipientKeys,
    assignedByKey: assignedByKey ?? this.assignedByKey,
    assignedByName: assignedByName ?? this.assignedByName,
    channelName: channelName ?? this.channelName,
    channelPskHex: channelPskHex,
    channelIndex: clearChannelIndex ? null : channelIndex ?? this.channelIndex,
    channelOpened: channelOpened ?? this.channelOpened,
    memberStatuses: memberStatuses ?? this.memberStatuses,
    dueMode: dueMode ?? this.dueMode,
    dueAt: clearDueAt ? null : dueAt ?? this.dueAt,
    assignedAt: assignedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    automaticResendEnabled:
        automaticResendEnabled ?? this.automaticResendEnabled,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'task_name': taskName,
    'description': description,
    'recipient_keys': recipientKeys,
    'recipient_labels': recipientLabels,
    'expected_recipient_keys': expectedRecipientKeys,
    'expected_recipient_count': expectedRecipientCount,
    'received_recipient_keys': receivedRecipientKeys,
    'assigned_by_key': assignedByKey,
    'assigned_by_name': assignedByName,
    'channel_name': channelName,
    'channel_psk_hex': channelPskHex,
    'channel_index': channelIndex,
    'channel_opened': channelOpened,
    'member_statuses': memberStatuses,
    'due_mode': dueMode.name,
    'due_at': dueAt?.toUtc().toIso8601String(),
    'assigned_at': assignedAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'automatic_resend_enabled': automaticResendEnabled,
  };

  factory AssignedTask.fromJson(Map<String, dynamic> json) {
    final dueModeName = json['due_mode'] as String? ?? 'none';
    final dueMode = AssignedTaskDueMode.values.firstWhere(
      (mode) => mode.name == dueModeName,
      orElse: () => AssignedTaskDueMode.none,
    );
    final dueAtString = json['due_at'] as String?;

    return AssignedTask(
      id: json['id'] as String,
      taskName: json['task_name'] as String,
      description: json['description'] as String? ?? '',
      recipientKeys: (json['recipient_keys'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      recipientLabels: (json['recipient_labels'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      expectedRecipientKeys:
          (json['expected_recipient_keys'] as List? ?? const [])
              .whereType<String>()
              .toList(),
      expectedRecipientCount: json['expected_recipient_count'] as int? ?? 0,
      receivedRecipientKeys:
          (json['received_recipient_keys'] as List? ?? const [])
              .whereType<String>()
              .toList(),
      assignedByKey: json['assigned_by_key'] as String? ?? '',
      assignedByName: json['assigned_by_name'] as String? ?? '',
      channelName: json['channel_name'] as String? ?? '',
      channelPskHex: json['channel_psk_hex'] as String? ?? '',
      channelIndex: json['channel_index'] as int?,
      channelOpened: json['channel_opened'] as bool? ?? false,
      memberStatuses: _parseMemberStatuses(json['member_statuses']),
      dueMode: dueMode,
      dueAt: dueAtString == null ? null : DateTime.parse(dueAtString).toLocal(),
      assignedAt: DateTime.parse(json['assigned_at'] as String).toLocal(),
      updatedAt: DateTime.parse(
        json['updated_at'] as String? ?? json['assigned_at'] as String,
      ).toLocal(),
      automaticResendEnabled: json['automatic_resend_enabled'] as bool? ?? true,
    );
  }

  static Map<String, Map<String, dynamic>> _parseMemberStatuses(Object? value) {
    if (value is! Map) return const {};
    final result = <String, Map<String, dynamic>>{};
    for (final entry in value.entries) {
      if (entry.key is String && entry.value is Map) {
        result[entry.key as String] = Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
    }
    return result;
  }
}

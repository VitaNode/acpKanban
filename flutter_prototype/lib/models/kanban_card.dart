class KanbanCard {
  final String id;
  final String columnId;
  final String title;
  final String description;
  final int position;
  final String createdAt;
  final String updatedAt;
  final int sessionCount;
  final String status;
  final String planStatus;
  final String? featureId;
  final String? completedAt;
  final String? parentId;
  final String? acpSessionId;
  final String? acpProviderId;
  final String? columnName;
  final String? summary;
  final String? sessionMode;
  final List<Map<String, dynamic>>? availableCommands;
  final int inputTokens;
  final int outputTokens;

  KanbanCard({
    required this.id,
    required this.columnId,
    required this.title,
    required this.description,
    this.position = 0,
    required this.createdAt,
    required this.updatedAt,
    this.sessionCount = 0,
    this.status = 'active',
    this.planStatus = 'plan',
    this.featureId,
    this.completedAt,
    this.parentId,
    this.acpSessionId,
    this.acpProviderId,
    this.columnName,
    this.summary,
    this.sessionMode,
    this.availableCommands,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  String get shortId => id.length >= 8 ? id.substring(0, 8) : id;
  bool get isCompleted => status == 'completed';

  factory KanbanCard.fromJson(Map<String, dynamic> json) {
    return KanbanCard(
      id: json['id']?.toString() ?? '',
      columnId: json['column_id']?.toString() ?? '',
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      position: json['position'] ?? 0,
      createdAt: json['created_at'] ?? DateTime.now().toIso8601String(),
      updatedAt: json['updated_at'] ?? DateTime.now().toIso8601String(),
      sessionCount: json['session_count'] ?? 0,
      status: json['status'] ?? 'active',
      planStatus: json['plan_status'] ?? 'plan',
      featureId: json['feature_id'],
      completedAt: json['completed_at'],
      parentId: json['parent_id'],
      acpSessionId: json['acp_session_id'],
      acpProviderId: json['acp_provider_id'],
      columnName: json['column_name'],
      summary: json['summary'],
      sessionMode: json['session_mode'],
      availableCommands: (json['available_commands'] as List?)?.cast<Map<String, dynamic>>(),
      inputTokens: json['input_tokens'] ?? 0,
      outputTokens: json['output_tokens'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'column_id': columnId,
      'title': title,
      'description': description,
      'position': position,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'status': status,
      'plan_status': planStatus,
      if (featureId != null) 'feature_id': featureId,
      if (completedAt != null) 'completed_at': completedAt,
      if (parentId != null) 'parent_id': parentId,
      if (acpSessionId != null) 'acp_session_id': acpSessionId,
      if (acpProviderId != null) 'acp_provider_id': acpProviderId,
      if (columnName != null) 'column_name': columnName,
      if (summary != null) 'summary': summary,
      if (sessionMode != null) 'session_mode': sessionMode,
      if (availableCommands != null) 'available_commands': availableCommands,
      'input_tokens': inputTokens,
      'output_tokens': outputTokens,
    };
  }

  KanbanCard copyWith({
    String? columnId,
    String? title,
    String? description,
    int? position,
    int? sessionCount,
    String? status,
    String? planStatus,
    String? featureId,
    String? completedAt,
    String? updatedAt,
    String? acpSessionId,
    String? acpProviderId,
    String? sessionMode,
    List<Map<String, dynamic>>? availableCommands,
    int? inputTokens,
    int? outputTokens,
  }) {
    return KanbanCard(
      id: id,
      columnId: columnId ?? this.columnId,
      title: title ?? this.title,
      description: description ?? this.description,
      position: position ?? this.position,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now().toIso8601String(),
      sessionCount: sessionCount ?? this.sessionCount,
      status: status ?? this.status,
      planStatus: planStatus ?? this.planStatus,
      featureId: featureId ?? this.featureId,
      completedAt: completedAt ?? this.completedAt,
      parentId: parentId,
      acpSessionId: acpSessionId ?? this.acpSessionId,
      acpProviderId: acpProviderId ?? this.acpProviderId,
      sessionMode: sessionMode ?? this.sessionMode,
      availableCommands: availableCommands ?? this.availableCommands,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
    );
  }
}

class ACPProvider {
  final String id;
  final String name;
  final List<String> command;
  final bool supportsYolo;
  final String icon;

  ACPProvider({
    required this.id,
    required this.name,
    required this.command,
    this.supportsYolo = false,
    this.icon = 'smart_toy',
  });

  factory ACPProvider.fromJson(Map<String, dynamic> json) {
    return ACPProvider(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      command: List<String>.from(json['command'] ?? []),
      supportsYolo: json['supports_yolo'] ?? false,
      icon: json['icon'] ?? 'smart_toy',
    );
  }
}

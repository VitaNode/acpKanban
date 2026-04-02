class KanbanCard {
  final String id;
  final String columnId;
  final String title;
  final String description;
  final int position;
  final String createdAt;
  final String updatedAt;
  final int sessionCount;
  final String? acpSessionId;
  final String? acpProviderId;

  KanbanCard({
    required this.id,
    required this.columnId,
    required this.title,
    required this.description,
    this.position = 0,
    required this.createdAt,
    required this.updatedAt,
    this.sessionCount = 0,
    this.acpSessionId,
    this.acpProviderId,
  });

  String get shortId => id.length >= 8 ? id.substring(0, 8) : id;

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
      acpSessionId: json['acp_session_id'],
      acpProviderId: json['acp_provider_id'],
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
      if (acpSessionId != null) 'acp_session_id': acpSessionId,
      if (acpProviderId != null) 'acp_provider_id': acpProviderId,
    };
  }

  KanbanCard copyWith({
    String? columnId,
    String? title,
    String? description,
    int? position,
    int? sessionCount,
    String? updatedAt,
    String? acpSessionId,
    String? acpProviderId,
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
      acpSessionId: acpSessionId ?? this.acpSessionId,
      acpProviderId: acpProviderId ?? this.acpProviderId,
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

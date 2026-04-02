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
    );
  }
}

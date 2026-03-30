class KanbanTask {
  final String id;
  final String title;
  final String description;
  final String status;
  final String updatedAt;
  final int sessionCount;

  KanbanTask({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    required this.updatedAt,
    this.sessionCount = 0,
  });

  factory KanbanTask.fromJson(Map<String, dynamic> json) {
    return KanbanTask(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      description: json['description'] ?? '',
      status: json['status'] ?? 'todo',
      updatedAt: json['updated_at'] ?? DateTime.now().toIso8601String(),
      sessionCount: json['session_count'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'status': status,
      'updated_at': updatedAt,
      'session_count': sessionCount,
    };
  }

  KanbanTask copyWith(
      {String? status, String? title, String? description, int? sessionCount}) {
    return KanbanTask(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      updatedAt: DateTime.now().toIso8601String(),
      sessionCount: sessionCount ?? this.sessionCount,
    );
  }

  bool get isDone => status == 'done';
  bool get isInProgress => status == 'in_progress';
  bool get isTodo => status == 'todo';
}

class KanbanTask {
  final String id;
  final String title;
  final String description;
  final String status;
  final String updatedAt;

  KanbanTask({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    required this.updatedAt,
  });

  factory KanbanTask.fromJson(Map<String, dynamic> json) {
    return KanbanTask(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      description: json['description'] ?? '',
      status: json['status'] ?? 'todo',
      updatedAt: json['updated_at'] ?? DateTime.now().toIso8601String(),
    );
  }

  // Issue 1: toJson
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'status': status,
      'updated_at': updatedAt,
    };
  }

  // Issue 2: Helper methods
  KanbanTask copyWith({String? status, String? title, String? description}) {
    return KanbanTask(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      updatedAt: DateTime.now().toIso8601String(),
    );
  }

  bool get isDone => status == 'done';
  bool get isInProgress => status == 'in_progress';
  bool get isTodo => status == 'todo';
}

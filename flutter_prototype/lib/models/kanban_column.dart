class KanbanColumn {
  final String id;
  final String projectId;
  final String name;
  final String color;
  final int position;

  KanbanColumn({
    required this.id,
    required this.projectId,
    required this.name,
    this.color = '#FFFFFF',
    required this.position,
  });

  factory KanbanColumn.fromJson(Map<String, dynamic> json) {
    return KanbanColumn(
      id: json['id']?.toString() ?? '',
      projectId: json['project_id']?.toString() ?? '',
      name: json['name'] ?? '',
      color: json['color'] ?? '#FFFFFF',
      position: json['position'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'project_id': projectId,
      'name': name,
      'color': color,
      'position': position,
    };
  }
}

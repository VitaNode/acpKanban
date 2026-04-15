class KanbanColumn {
  final String id;
  final String projectId;
  final String name;
  final String color;
  final int position;
  final String? promptTemplate;
  final String? approvalMode;

  KanbanColumn({
    required this.id,
    required this.projectId,
    required this.name,
    this.color = '#FFFFFF',
    required this.position,
    this.promptTemplate,
    this.approvalMode,
  });

  factory KanbanColumn.fromJson(Map<String, dynamic> json) {
    return KanbanColumn(
      id: json['id']?.toString() ?? '',
      projectId: json['project_id']?.toString() ?? '',
      name: json['name'] ?? '',
      color: json['color'] ?? '#FFFFFF',
      position: json['position'] ?? 0,
      promptTemplate: json['prompt_template'],
      approvalMode: json['approval_mode'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'project_id': projectId,
      'name': name,
      'color': color,
      'position': position,
      'prompt_template': promptTemplate,
      'approval_mode': approvalMode,
    };
  }
}

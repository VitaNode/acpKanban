class Project {
  final String id;
  final String name;
  final String? workspacePath;
  final String createdAt;
  final String updatedAt;
  final int cardCount;

  Project({
    required this.id,
    required this.name,
    this.workspacePath,
    required this.createdAt,
    required this.updatedAt,
    this.cardCount = 0,
  });

  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      id: json['id'] ?? '',
      name: json['name'] ?? 'Untitled Project',
      workspacePath: json['workspace_path'],
      createdAt: json['created_at'] ?? DateTime.now().toIso8601String(),
      updatedAt: json['updated_at'] ?? DateTime.now().toIso8601String(),
      cardCount: json['card_count'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'workspace_path': workspacePath,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  String get displayName => name;

  String get lastActive {
    final dt = DateTime.tryParse(updatedAt);
    if (dt == null) return 'Unknown';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }
}

class ProjectMilestone {
  final String id;
  final String projectId;
  final String title;
  final String? description;
  final String status;
  final String? targetDate;
  final double progress;
  final List<ProjectFeature> features;

  ProjectMilestone({
    required this.id,
    required this.projectId,
    required this.title,
    this.description,
    required this.status,
    this.targetDate,
    required this.progress,
    required this.features,
  });

  factory ProjectMilestone.fromJson(Map<String, dynamic> json) {
    return ProjectMilestone(
      id: json['id'],
      projectId: json['project_id'],
      title: json['title'],
      description: json['description'],
      status: json['status'],
      targetDate: json['target_date'],
      progress: (json['progress'] as num).toDouble(),
      features: (json['features'] as List)
          .map((f) => ProjectFeature.fromJson(f))
          .toList(),
    );
  }
}

class ProjectFeature {
  final String id;
  final String milestoneId;
  final String title;
  final String? description;
  final String status;
  final double progress;
  final Map<String, int> counts;
  final List<RoadmapCardSummary>? cards;

  ProjectFeature({
    required this.id,
    required this.milestoneId,
    required this.title,
    this.description,
    required this.status,
    required this.progress,
    required this.counts,
    this.cards,
  });

  factory ProjectFeature.fromJson(Map<String, dynamic> json) {
    return ProjectFeature(
      id: json['id'],
      milestoneId: json['milestone_id'],
      title: json['title'],
      description: json['description'],
      status: json['status'],
      progress: (json['progress'] as num).toDouble(),
      counts: Map<String, int>.from(json['counts']),
      cards: json['cards'] != null
          ? (json['cards'] as List)
              .map((c) => RoadmapCardSummary.fromJson(c))
              .toList()
          : null,
    );
  }
}

class RoadmapCardSummary {
  final String id;
  final String title;
  final String planStatus;

  RoadmapCardSummary({
    required this.id,
    required this.title,
    required this.planStatus,
  });

  factory RoadmapCardSummary.fromJson(Map<String, dynamic> json) {
    return RoadmapCardSummary(
      id: json['id'],
      title: json['title'],
      planStatus: json['plan_status'],
    );
  }
}

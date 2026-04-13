enum PlanStepStatus { pending, inProgress, completed, failed }

enum PlanStepPriority { high, medium, low }

class PlanStep {
  final String content;
  final PlanStepStatus status;
  final PlanStepPriority priority;
  final String? description;

  PlanStep({
    required this.content,
    required this.status,
    required this.priority,
    this.description,
  });

  factory PlanStep.fromJson(Map<String, dynamic> json) {
    return PlanStep(
      content: json['content'] ?? json['title'] ?? '',
      status: _parseStatus(json['status']),
      priority: _parsePriority(json['priority']),
      description: json['description'],
    );
  }

  static PlanStepStatus _parseStatus(String? status) {
    switch (status) {
      case 'in_progress': return PlanStepStatus.inProgress;
      case 'completed': return PlanStepStatus.completed;
      case 'failed': return PlanStepStatus.failed;
      default: return PlanStepStatus.pending;
    }
  }

  static PlanStepPriority _parsePriority(String? priority) {
    switch (priority) {
      case 'high': return PlanStepPriority.high;
      case 'low': return PlanStepPriority.low;
      default: return PlanStepPriority.medium;
    }
  }
}

class AgentPlan {
  final List<PlanStep> entries;

  AgentPlan({required this.entries});

  factory AgentPlan.fromJson(Map<String, dynamic> json) {
    final list = (json['entries'] ?? json['steps'] ?? []) as List;
    return AgentPlan(
      entries: list.map((e) => PlanStep.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  double get progress {
    if (entries.isEmpty) return 0.0;
    final completed = entries.where((s) => s.status == PlanStepStatus.completed).length;
    return completed / entries.length;
  }
}

enum TimelineEventType {
  cardCreated,
  cardUpdated,
  cardDeleted,
  cardMoved,
  aiAction,
  userAction,
  columnChanged,
  unknown
}

class TimelineEvent {
  final String id;
  final String projectId;
  final String? cardId;
  final TimelineEventType type;
  final String content;
  final String createdAt;
  final Map<String, dynamic>? metadata;

  TimelineEvent({
    required this.id,
    required this.projectId,
    this.cardId,
    required this.type,
    required this.content,
    required this.createdAt,
    this.metadata,
  });

  factory TimelineEvent.fromJson(Map<String, dynamic> json) {
    return TimelineEvent(
      id: json['id']?.toString() ?? '',
      projectId: json['project_id']?.toString() ?? '',
      cardId: json['card_id']?.toString(),
      type: _parseType(json['event_type']),
      content: json['content'] ?? '',
      createdAt: json['created_at'] ?? DateTime.now().toIso8601String(),
      metadata: json['metadata'],
    );
  }

  static TimelineEventType _parseType(String? type) {
    switch (type) {
      case 'card_created': return TimelineEventType.cardCreated;
      case 'card_updated': return TimelineEventType.cardUpdated;
      case 'card_deleted': return TimelineEventType.cardDeleted;
      case 'card_moved': return TimelineEventType.cardMoved;
      case 'ai_action': return TimelineEventType.aiAction;
      case 'user_action': return TimelineEventType.userAction;
      case 'column_changed': return TimelineEventType.columnChanged;
      default: return TimelineEventType.unknown;
    }
  }

  String get typeString {
    switch (type) {
      case TimelineEventType.cardCreated: return 'card_created';
      case TimelineEventType.cardUpdated: return 'card_updated';
      case TimelineEventType.cardDeleted: return 'card_deleted';
      case TimelineEventType.cardMoved: return 'card_moved';
      case TimelineEventType.aiAction: return 'ai_action';
      case TimelineEventType.userAction: return 'user_action';
      case TimelineEventType.columnChanged: return 'column_changed';
      default: return 'unknown';
    }
  }
}

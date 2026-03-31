import 'dart:convert';

enum TimelineEventType {
  cardCreated,
  cardUpdated,
  cardDeleted,
  cardMoved,
  aiAction,
  userAction,
  columnCreated,
  columnUpdated,
  columnDeleted,
  columnsReordered,
  projectCreated,
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
    Map<String, dynamic>? parsedMetadata;
    if (json['metadata'] != null) {
      if (json['metadata'] is String) {
        try {
          parsedMetadata =
              Map<String, dynamic>.from(jsonDecode(json['metadata']));
        } catch (_) {
          parsedMetadata = null;
        }
      } else if (json['metadata'] is Map) {
        parsedMetadata = Map<String, dynamic>.from(json['metadata']);
      }
    }

    return TimelineEvent(
      id: json['id']?.toString() ?? '',
      projectId: json['project_id']?.toString() ?? '',
      cardId: json['card_id']?.toString(),
      type: _parseType(json['event_type']),
      content: json['content'] ?? '',
      createdAt: json['timestamp'] ??
          json['created_at'] ??
          DateTime.now().toIso8601String(),
      metadata: parsedMetadata,
    );
  }

  static TimelineEventType _parseType(String? type) {
    switch (type) {
      case 'card_created':
        return TimelineEventType.cardCreated;
      case 'card_updated':
        return TimelineEventType.cardUpdated;
      case 'card_deleted':
        return TimelineEventType.cardDeleted;
      case 'card_moved':
        return TimelineEventType.cardMoved;
      case 'ai_action':
        return TimelineEventType.aiAction;
      case 'user_action':
        return TimelineEventType.userAction;
      case 'column_created':
        return TimelineEventType.columnCreated;
      case 'column_updated':
        return TimelineEventType.columnUpdated;
      case 'column_deleted':
        return TimelineEventType.columnDeleted;
      case 'columns_reordered':
        return TimelineEventType.columnsReordered;
      case 'project_created':
        return TimelineEventType.projectCreated;
      default:
        return TimelineEventType.unknown;
    }
  }

  String get typeString {
    switch (type) {
      case TimelineEventType.cardCreated:
        return 'card_created';
      case TimelineEventType.cardUpdated:
        return 'card_updated';
      case TimelineEventType.cardDeleted:
        return 'card_deleted';
      case TimelineEventType.cardMoved:
        return 'card_moved';
      case TimelineEventType.aiAction:
        return 'ai_action';
      case TimelineEventType.userAction:
        return 'user_action';
      case TimelineEventType.columnCreated:
        return 'column_created';
      case TimelineEventType.columnUpdated:
        return 'column_updated';
      case TimelineEventType.columnDeleted:
        return 'column_deleted';
      case TimelineEventType.columnsReordered:
        return 'columns_reordered';
      case TimelineEventType.projectCreated:
        return 'project_created';
      default:
        return 'unknown';
    }
  }
}

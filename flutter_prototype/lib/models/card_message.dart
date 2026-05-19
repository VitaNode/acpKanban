class CardMessage {
  final String id;
  final String cardId;
  final String role;
  final String content;
  final String createdAt;
  final Map<String, dynamic>? metadata;
  final bool isComplete;
  final int? seqId;

  CardMessage({
    required this.id,
    required this.cardId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.metadata,
    this.isComplete = true,
    this.seqId,
  });

  factory CardMessage.fromJson(Map<String, dynamic> json) {
    return CardMessage(
      id: json['id']?.toString() ?? '',
      cardId: json['card_id']?.toString() ?? '',
      role: json['role'] ?? 'assistant',
      content: json['content'] ?? '',
      createdAt: json['created_at'] ?? DateTime.now().toIso8601String(),
      metadata: json['metadata'],
      isComplete: json['is_complete'] == 0 || json['is_complete'] == false
          ? false
          : true,
      seqId: json['seq_id'] is int ? json['seq_id'] : null,
    );
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isSystem => role == 'system';

  CardMessage copyWith({
    String? content,
    bool? isComplete,
    Map<String, dynamic>? metadata,
    int? seqId,
  }) {
    return CardMessage(
      id: id,
      cardId: cardId,
      role: role,
      content: content ?? this.content,
      createdAt: createdAt,
      metadata: metadata ?? this.metadata,
      isComplete: isComplete ?? this.isComplete,
      seqId: seqId ?? this.seqId,
    );
  }
}

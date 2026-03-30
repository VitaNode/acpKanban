class CardMessage {
  final String id;
  final String cardId;
  final String role;
  final String content;
  final String createdAt;
  final Map<String, dynamic>? metadata;

  CardMessage({
    required this.id,
    required this.cardId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.metadata,
  });

  factory CardMessage.fromJson(Map<String, dynamic> json) {
    return CardMessage(
      id: json['id']?.toString() ?? '',
      cardId: json['card_id']?.toString() ?? '',
      role: json['role'] ?? 'assistant',
      content: json['content'] ?? '',
      createdAt: json['created_at'] ?? DateTime.now().toIso8601String(),
      metadata: json['metadata'],
    );
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isSystem => role == 'system';
}

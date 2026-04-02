import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/card_message.dart';
import '../utils/date_formatter.dart';
import '../constants/app_constants.dart';

class MessageBubble extends StatelessWidget {
  final CardMessage message;
  final String? providerId;
  final String? providerName;

  const MessageBubble({
    super.key,
    required this.message,
    this.providerId,
    this.providerName,
  });

  @override
  Widget build(BuildContext context) {
    if (message.isSystem) return const SizedBox.shrink();
    if (message.role == 'tool') return _buildToolLog(context);

    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            _buildHeader(isUser),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isUser ? AppConstants.primaryColor : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
                border: isUser ? null : Border.all(color: Colors.grey[200]!),
              ),
              child: MarkdownBody(
                data: message.content,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    color: isUser ? Colors.white : Colors.black87,
                    fontSize: 14,
                  ),
                  code: TextStyle(
                    backgroundColor:
                        isUser ? Colors.indigo[700] : Colors.grey[100],
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isUser) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isUser) ...[
          Icon(_getProviderIcon(), size: 14, color: AppConstants.primaryColor),
          const SizedBox(width: 4),
          Text(_getProviderName(),
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppConstants.primaryColor)),
        ],
        if (isUser) ...[
          const Text('You',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey)),
          const SizedBox(width: 4),
          const Icon(Icons.person, size: 14, color: Colors.grey),
        ],
        const SizedBox(width: 8),
        Text(
          DateFormatter.formatTimeOnly(message.createdAt),
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }

  IconData _getProviderIcon() {
    final iconMap = {
      'gemini': Icons.bolt,
      'qwen': Icons.code,
      'openclaw': Icons.smart_toy,
      'opencode': Icons.search,
    };
    return iconMap[providerId] ?? Icons.smart_toy;
  }

  String _getProviderName() {
    return providerName ?? 'AI Agent';
  }

  Widget _buildToolLog(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 24),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: ExpansionTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: const Icon(Icons.terminal, size: 16, color: Colors.blueGrey),
        title: Text(
          'Tool Execution: ${message.metadata?['name'] ?? "Unknown"}',
          style: const TextStyle(
              fontSize: 12, fontFamily: 'monospace', color: Colors.blueGrey),
        ),
        subtitle: Text(
          DateFormatter.formatTimeOnly(message.createdAt),
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.black.withOpacity(0.02),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.metadata?['arguments'] != null) ...[
                  const Text('Arguments:',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  _buildCodeBlock(message.metadata!['arguments'].toString()),
                  const SizedBox(height: 8),
                ],
                const Text('Result:',
                    style:
                        TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                _buildCodeBlock(message.content),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeBlock(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.greenAccent,
          fontFamily: 'monospace',
          fontSize: 11,
        ),
      ),
    );
  }
}

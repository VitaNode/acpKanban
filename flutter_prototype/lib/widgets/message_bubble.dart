import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/card_message.dart';
import '../models/content_block.dart';
import '../widgets/content_block_renderer.dart';
import '../utils/date_formatter.dart';
import '../constants/app_constants.dart';
import '../utils/icon_util.dart';

class MessageBubble extends StatelessWidget {
  final CardMessage message;
  final String? providerId;
  final String? providerName;
  final String? providerIcon;

  const MessageBubble({
    super.key,
    required this.message,
    this.providerId,
    this.providerName,
    this.providerIcon,
  });

  List<ContentBlock> _parseContentBlocks() {
    try {
      final decoded = jsonDecode(message.content);
      if (decoded is List) {
        return decoded
            .map((json) => ContentBlock.fromJson(json as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      // Not JSON, treat as plain text
    }
    return [TextContent(text: message.content)];
  }

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
                    color: Colors.black.withAlpha(13),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
                border: isUser ? null : Border.all(color: Colors.grey[200]!),
              ),
              child: _buildMessageContent(isUser),
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

  Widget _buildMessageContent(bool isUser) {
    final blocks = _parseContentBlocks();
    if (blocks.length == 1 && blocks[0] is TextContent) {
      return MarkdownBody(
        data: (blocks[0] as TextContent).text,
        styleSheet: MarkdownStyleSheet(
          p: TextStyle(
            color: isUser ? Colors.white : Colors.black87,
            fontSize: 14,
          ),
          code: TextStyle(
            backgroundColor: isUser ? Colors.indigo[700] : Colors.grey[100],
            fontFamily: 'monospace',
            fontSize: 12,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children:
          blocks.map((block) => ContentBlockRenderer(block: block)).toList(),
    );
  }

  IconData _getProviderIcon() {
    return IconUtil.getProviderIcon(providerIcon);
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
            color: Colors.black.withAlpha(5),
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

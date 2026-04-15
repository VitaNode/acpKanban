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
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        margin: const EdgeInsets.symmetric(vertical: AppConstants.space8, horizontal: AppConstants.space16),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            _buildHeader(isUser),
            const SizedBox(height: AppConstants.space4),
            Container(
              padding: const EdgeInsets.all(AppConstants.space12),
              decoration: BoxDecoration(
                color: isUser ? AppConstants.primaryColor : AppConstants.backgroundColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(AppConstants.space16),
                  topRight: const Radius.circular(AppConstants.space16),
                  bottomLeft: Radius.circular(isUser ? AppConstants.space16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : AppConstants.space16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
                border: isUser ? null : Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isUser && message.metadata?['thought'] != null)
                    _buildThoughtSection(context),
                  _buildMessageContent(isUser),
                ],
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
          Icon(_getProviderIcon(), size: 12, color: AppConstants.primaryColor),
          const SizedBox(width: AppConstants.space4),
          Text(_getProviderName().toUpperCase(),
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  color: AppConstants.primaryColor)),
        ],
        if (isUser) ...[
          const Text('YOU',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  color: AppConstants.textHint)),
          const SizedBox(width: AppConstants.space4),
          const Icon(Icons.person_rounded, size: 12, color: AppConstants.textHint),
        ],
        const SizedBox(width: AppConstants.space8),
        Text(
          DateFormatter.formatTimeOnly(message.createdAt),
          style: const TextStyle(fontSize: 9, color: AppConstants.textHint),
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
            color: isUser ? Colors.white : AppConstants.textPrimary,
            fontSize: 14,
            height: 1.5,
          ),
          code: TextStyle(
            backgroundColor: isUser ? Colors.teal.shade900 : Colors.grey.shade100,
            fontFamily: 'monospace',
            fontSize: 12,
          ),
          codeblockDecoration: BoxDecoration(
            color: isUser ? Colors.teal.shade900 : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(AppConstants.space8),
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

  Widget _buildThoughtSection(BuildContext context) {
    final thought = message.metadata!['thought'].toString();
    if (thought.isEmpty || thought == "...") return const SizedBox.shrink();
    
    return Container(
      margin: const EdgeInsets.only(bottom: AppConstants.space12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50.withOpacity(0.5),
        borderRadius: BorderRadius.circular(AppConstants.space8),
        border: Border.all(color: Colors.amber.shade100),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          initiallyExpanded: false,
          leading: const Icon(Icons.lightbulb_outline_rounded, size: 16, color: Colors.amber),
          title: Text(
            'THOUGHT PROCESS',
            style: TextStyle(
              fontSize: 10, 
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              color: Colors.amber.shade900,
            ),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppConstants.space12, 0, AppConstants.space12, AppConstants.space12),
              child: MarkdownBody(
                data: thought,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade800,
                    fontStyle: FontStyle.italic,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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
      margin: const EdgeInsets.symmetric(vertical: AppConstants.space4, horizontal: AppConstants.space24),
      decoration: BoxDecoration(
        color: AppConstants.surfaceColor,
        borderRadius: BorderRadius.circular(AppConstants.space8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: ExpansionTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: const Icon(Icons.terminal_rounded, size: 16, color: Colors.blueGrey),
        title: Text(
          'TOOL: ${message.metadata?['name']?.toString().toUpperCase() ?? "UNKNOWN"}',
          style: const TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5, fontFamily: 'monospace', color: Colors.blueGrey),
        ),
        subtitle: Text(
          DateFormatter.formatTimeOnly(message.createdAt),
          style: const TextStyle(fontSize: 9, color: AppConstants.textHint),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppConstants.space12),
            color: Colors.black.withOpacity(0.02),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.metadata?['arguments'] != null) ...[
                  const Text('ARGUMENTS',
                      style:
                          TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                  const SizedBox(height: AppConstants.space4),
                  _buildCodeBlock(message.metadata!['arguments'].toString()),
                  const SizedBox(height: AppConstants.space8),
                ],
                const Text('RESULT',
                    style:
                        TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                const SizedBox(height: AppConstants.space4),
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
      padding: const EdgeInsets.all(AppConstants.space8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(AppConstants.space4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFCE9178),
          fontFamily: 'monospace',
          fontSize: 11,
        ),
      ),
    );
  }
}

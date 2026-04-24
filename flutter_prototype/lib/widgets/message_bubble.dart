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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        margin: const EdgeInsets.symmetric(
            vertical: AppConstants.space8, horizontal: AppConstants.space16),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            _buildHeader(context, isUser),
            const SizedBox(height: AppConstants.space4),
            Container(
              padding: const EdgeInsets.all(AppConstants.space12),
              decoration: BoxDecoration(
                color: isUser
                    ? colorScheme.primary
                    : (isDark
                        ? colorScheme.surfaceContainerHigh
                        : colorScheme.surfaceContainer),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(AppConstants.radiusMedium),
                  topRight: const Radius.circular(AppConstants.radiusMedium),
                  bottomLeft: Radius.circular(isUser ? AppConstants.radiusMedium : 4),
                  bottomRight: Radius.circular(isUser ? 4 : AppConstants.radiusMedium),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
                border: isUser ? null : Border.all(color: theme.dividerTheme.color!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isUser && message.metadata?['thought'] != null)
                    _buildThoughtSection(context),
                  _buildMessageContent(context, isUser),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isUser) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isUser) ...[
          Icon(_getProviderIcon(), size: 12, color: colorScheme.primary),
          const SizedBox(width: AppConstants.space4),
          Text(_getProviderName().toUpperCase(),
              style: theme.textTheme.labelLarge),
        ],
        if (isUser) ...[
          Text('YOU',
              style: theme.textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis))),
          const SizedBox(width: AppConstants.space4),
          Icon(Icons.person_rounded,
              size: 12,
              color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis)),
        ],
        const SizedBox(width: AppConstants.space8),
        Text(
          DateFormatter.formatTimeOnly(message.createdAt),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildMessageContent(BuildContext context, bool isUser) {
    final blocks = _parseContentBlocks();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textColor = isUser
        ? colorScheme.onPrimary
        : theme.textTheme.bodyMedium?.color ?? colorScheme.onSurface;

    if (blocks.length == 1 && blocks[0] is TextContent) {
      return Theme(
        data: theme.copyWith(
          textSelectionTheme: TextSelectionThemeData(
            selectionColor: isUser
                ? Colors.white.withOpacity(0.3)
                : colorScheme.primary.withOpacity(0.2),
          ),
        ),
        child: MarkdownBody(
          data: (blocks[0] as TextContent).text,
          selectable: true,
          styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
            p: TextStyle(color: textColor, fontSize: 14, height: 1.5),
            h1: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 22),
            h2: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 20),
            h3: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 18),
            h4: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 16),
            h5: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
            h6: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12),
            em: TextStyle(color: textColor, fontStyle: FontStyle.italic),
            strong: TextStyle(color: textColor, fontWeight: FontWeight.bold),
            listBullet: TextStyle(color: textColor),
            code: TextStyle(
              backgroundColor: isUser
                  ? Colors.black26
                  : (theme.brightness == Brightness.dark
                      ? Colors.black45
                      : colorScheme.surfaceContainerHighest),
              color: isUser
                  ? Colors.white
                  : (theme.brightness == Brightness.dark
                      ? Colors.white
                      : colorScheme.onSurfaceVariant),
              fontFamily: 'monospace',
              fontSize: 12,
            ),
            codeblockDecoration: BoxDecoration(
              color: isUser
                  ? Colors.black26
                  : (theme.brightness == Brightness.dark
                      ? Colors.black45
                      : colorScheme.surfaceContainerHighest),
              borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
            ),
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: AppConstants.space12),
      decoration: BoxDecoration(
        color: isDark
            ? colorScheme.surfaceContainerHighest.withOpacity(0.4) // 使用更高亮度的容器
            : Colors.amber.shade50.withOpacity(0.5),
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
        border: Border.all(
            color: isDark
                ? Colors.amber.withOpacity(0.2) // 深色模式下使用柔和的琥珀色边框
                : Colors.amber.shade100),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          initiallyExpanded: false,
          leading: Icon(Icons.lightbulb_outline_rounded, 
              size: 16, 
              color: isDark ? Colors.amber.shade300 : Colors.amber.shade700),
          title: Text(
            'THOUGHT PROCESS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              color: isDark ? Colors.amber.shade200 : Colors.amber.shade900,
            ),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppConstants.space12, 0,
                  AppConstants.space12, AppConstants.space12),
              child: MarkdownBody(
                data: thought,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: 12,
                    color: isDark ? colorScheme.onSurface.withOpacity(AppConstants.highEmphasis) : Colors.grey.shade800,
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    
    return Container(
      margin: const EdgeInsets.symmetric(
          vertical: AppConstants.space4, horizontal: AppConstants.space24),
      decoration: BoxDecoration(
        color: isDark
            ? colorScheme.surfaceContainer.withOpacity(0.5)
            : colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
        border: Border.all(color: theme.dividerTheme.color!),
      ),
      child: ExpansionTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(Icons.terminal_rounded,
            size: 16,
            color: isDark ? Colors.blueGrey.shade200 : Colors.blueGrey),
        title: Text(
          'TOOL: ${message.metadata?['name']?.toString().toUpperCase() ?? "UNKNOWN"}',
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              fontFamily: 'monospace',
              color: isDark ? Colors.blueGrey.shade200 : Colors.blueGrey),
        ),
        subtitle: Text(
          DateFormatter.formatTimeOnly(message.createdAt),
          style: theme.textTheme.bodySmall,
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
                  Text('ARGUMENTS',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.blueGrey.shade300
                              : Colors.blueGrey)),
                  const SizedBox(height: AppConstants.space4),
                  _buildCodeBlock(message.metadata!['arguments'].toString()),
                  const SizedBox(height: AppConstants.space8),
                ],
                Text('RESULT',
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: isDark
                            ? Colors.blueGrey.shade300
                            : Colors.blueGrey)),
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
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
      ),
      child: SelectableText(
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

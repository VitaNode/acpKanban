import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import '../models/card_message.dart';
import '../models/content_block.dart';
import '../widgets/content_block_renderer.dart';
import '../utils/date_formatter.dart';
import '../constants/app_constants.dart';
import '../utils/icon_util.dart';
import '../theme/app_theme.dart';
import '../widgets/ag_ui/thinking_block.dart';
import '../widgets/ag_ui/tool_pill.dart';
import '../widgets/ag_ui/interactive_request_block.dart';
import '../models/ag_ui_event.dart';

class MessageBubble extends StatelessWidget {
  final CardMessage message;
  final String? providerId;
  final String? providerName;
  final String? providerIcon;
  final Function(String requestId, String optionId)? onOptionSelected;
  final Set<String>? respondedRequestIds;

  const MessageBubble({
    super.key,
    required this.message,
    this.providerId,
    this.providerName,
    this.providerIcon,
    this.onOptionSelected,
    this.respondedRequestIds,
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

    // AG-UI Fix: Don't render blank bubbles for empty messages without metadata info
    // Also ignore redundant "..." placeholder which is filtered by ThinkingBlock
    final thought = message.metadata?['thought']?.toString() ?? "";
    final hasThought = thought.isNotEmpty && thought != "...";
    
    final hasToolCalls = message.metadata?['tool_calls'] != null && (message.metadata!['tool_calls'] as List).isNotEmpty;
    final isReasoning = message.metadata?['type'] == 'reasoning' && message.content.trim().isNotEmpty;
    
    final event = AgUiEvent.fromMessage(message);
    final isInteractiveRequest = event.eventType == 'interactive_request' && event.requestId != null;
    final isPlanUpdate = message.metadata?['type'] == 'plan_update';
    
    if (message.content.trim().isEmpty && !hasThought && !hasToolCalls && !isReasoning && !isInteractiveRequest && !isPlanUpdate) {
      return const SizedBox.shrink();
    }

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
                  if (!isUser && message.metadata?['tool_calls'] != null)
                    _buildToolCallsSection(context),
                  // Check for AG-UI interactive request
                  if (!isUser) _buildInteractiveRequestSection(context),
                  // Check if this independent message is actually a thinking record
                  if (!isUser && message.metadata?['type'] == 'reasoning')
                    _buildThinkingRecordSection(context),
                  
                  // AG-UI Enhancement: Render plan updates in chat
                  if (!isUser && isPlanUpdate)
                    _buildPlanUpdateSection(context),

                  // Only build message content if it's NOT an interactive request
                  // to prevent rendering the raw JSON string.
                  if (!isUser && (message.metadata?['type'] == null || message.metadata?['type'] != 'reasoning') && !isInteractiveRequest && !isPlanUpdate)
                    _buildMessageContent(context, isUser),
                  if (isUser)
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
    final customColors = theme.extension<CustomColors>()!;
    final textColor = isUser
        ? colorScheme.onPrimary
        : theme.textTheme.bodyMedium?.color ?? colorScheme.onSurface;

    // Use primary color for headings and special elements in agent messages
    // For user messages, stick to onPrimary for readability
    final accentColor = isUser ? colorScheme.onPrimary : colorScheme.primary;
    final secondaryTextColor = isUser 
        ? colorScheme.onPrimary.withOpacity(0.8) 
        : colorScheme.onSurfaceVariant;

    if (blocks.length == 1 && blocks[0] is TextContent) {
      String markdownData = (blocks[0] as TextContent).text;

      // Pre-process headers to keep source visible (# Header -> # # Header)
      // The first # is consumed as the block tag, the second # is rendered as content.
      markdownData = markdownData.replaceAllMapped(
        RegExp(r'^(#+)(\s+)', multiLine: true),
        (match) => '${match[1]}${match[2]}${match[1]}${match[2]}'
      );

      return Theme(
        data: theme.copyWith(
          textSelectionTheme: TextSelectionThemeData(
            selectionColor: isUser
                ? Colors.white.withOpacity(0.3)
                : colorScheme.primary.withOpacity(0.2),
          ),
        ),
        child: MarkdownBody(
          data: markdownData,
          styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
            p: TextStyle(color: textColor, fontSize: 14, height: 1.6),
            blockSpacing: 12.0,
            h1: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
            h2: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
            h3: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
            h4: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
            h5: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
            h6: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
            blockquote: TextStyle(color: secondaryTextColor, fontSize: 14),
            blockquoteDecoration: BoxDecoration(
              border: Border(left: BorderSide(color: secondaryTextColor.withOpacity(0.3), width: 3)),
            ),
            horizontalRuleDecoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Colors.transparent, width: 0)),
            ),
            listBullet: TextStyle(color: secondaryTextColor, fontSize: 14),
            em: TextStyle(color: textColor, fontStyle: FontStyle.italic, fontSize: 14),
            strong: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
            a: TextStyle(color: accentColor, decoration: TextDecoration.underline, fontSize: 14),
            code: TextStyle(
              backgroundColor: Colors.transparent,
              color: isUser
                  ? colorScheme.onPrimary
                  : colorScheme.primary,
              fontFamily: 'monospace',
              fontSize: 14,
              fontWeight: FontWeight.w400,
            ),
            codeblockDecoration: BoxDecoration(
              color: isUser
                  ? Colors.black26
                  : customColors.codeBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
              border: isUser ? null : Border.all(color: colorScheme.outlineVariant.withOpacity(0.3)),
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
    final thought = message.metadata?['thought']?.toString();
    if (thought == null || thought.isEmpty || thought == "...") return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: AppConstants.space12),
      child: ThinkingBlock(
        text: thought,
        isCollapsed: true, // 默认折叠
      ),
    );
  }

  Widget _buildThinkingRecordSection(BuildContext context) {
    // This handles the case where a thinking chunk is its own message
    return Padding(
      padding: const EdgeInsets.only(bottom: AppConstants.space12),
      child: ThinkingBlock(
        text: message.content,
        isCollapsed: true,
      ),
    );
  }

  Widget _buildToolCallsSection(BuildContext context) {
    final toolCalls = message.metadata?['tool_calls'] as List<dynamic>?;
    if (toolCalls == null || toolCalls.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: AppConstants.space12),
      child: Wrap(
        spacing: AppConstants.space8,
        runSpacing: AppConstants.space8,
        children: toolCalls.map((tc) {
          final toolName = (tc['name'] ?? 'Unknown').toString();
          final toolStatus = _mapToolStatus(tc['status']?.toString() ?? 'running');
          return ToolPill(name: toolName, status: toolStatus);
        }).toList(),
      ),
    );
  }

  Widget _buildInteractiveRequestSection(BuildContext context) {
    final event = AgUiEvent.fromMessage(message);
    if (event.eventType != 'interactive_request' || event.requestId == null) {
      return const SizedBox.shrink();
    }

    final isResponded = respondedRequestIds?.contains(event.requestId) ?? false;

    return InteractiveRequestBlock(
      event: event,
      isResponded: isResponded,
      onOptionSelected: (optionId) {
        if (onOptionSelected != null) {
          onOptionSelected!(event.requestId!, optionId);
        }
      },
    );
  }

  String _mapToolStatus(String? status) {
    // Map backend status to frontend-compatible status
    switch (status) {
      case 'pending':
      case 'running':
        return 'running';
      case 'completed':
      case 'success':
        return 'success';
      case 'failed':
      case 'cancelled':
      case 'error':
        return 'failed';
      default:
        return 'running';
    }
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
    final toolName = message.metadata?['name']?.toString() ?? "UNKNOWN";
    final toolStatus = message.metadata?['status']?.toString() ?? "pending";
    
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
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: ToolPill(name: toolName, status: toolStatus),
          title: Text(
            'TOOL LOG',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                fontFamily: 'monospace',
                color: isDark ? colorScheme.onSurface : Colors.blueGrey),
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
                                ? colorScheme.primary
                                : Colors.blueGrey)),
                    const SizedBox(height: AppConstants.space4),
                    _buildCodeBlock(context, message.metadata!['arguments'].toString()),
                    const SizedBox(height: AppConstants.space8),
                  ],
                  Text('RESULT',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? colorScheme.primary
                              : Colors.blueGrey)),
                  const SizedBox(height: AppConstants.space4),
                  _buildCodeBlock(context, message.content),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCodeBlock(BuildContext context, String text) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final customColors = theme.extension<CustomColors>()!;
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.space8),
      decoration: BoxDecoration(
        color: isDark ? colorScheme.surfaceContainerHigh : customColors.codeBackground?.withOpacity(0.5),
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
        border: isDark ? Border.all(color: Colors.white.withOpacity(0.05)) : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          color: customColors.codeText,
          fontFamily: 'monospace',
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _buildPlanUpdateSection(BuildContext context) {
    try {
      final rawMap = jsonDecode(message.content);
      // AG-UI event maps the plan data under the 'plan' key
      final planData = rawMap['plan'] as Map<String, dynamic>?;
      if (planData == null) return const SizedBox.shrink();
      
      final plan = AgentPlan.fromJson(planData);
      return PlanPanel(plan: plan);
    } catch (e) {
      debugPrint('Plan rendering error: $e');
      return const Text('Failed to load plan');
    }
  }
}

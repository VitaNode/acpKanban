import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import '../models/card_message.dart';
import '../utils/date_formatter.dart';
import '../constants/app_constants.dart';
import '../utils/icon_util.dart';
import '../theme/app_theme.dart';
import '../constants/ui_copy.dart';
import '../utils/app_logger.dart';
import '../widgets/ag_ui/thinking_block.dart';
import '../widgets/ag_ui/tool_pill.dart';
import '../widgets/ag_ui/interactive_request_block.dart';
import '../models/ag_ui_event.dart';
import '../models/agent_plan.dart';
import 'plan_panel.dart';

String _opKindLabel(String? opKind) {
  switch (opKind) {
    case 'read': return 'Read';
    case 'search': return 'Search';
    case 'edit': return 'Edit';
    case 'execute': return 'Run';
    default: return 'Tool';
  }
}

IconData _opKindIcon(String? opKind) {
  switch (opKind) {
    case 'read': return Icons.description_outlined;
    case 'search': return Icons.search;
    case 'edit': return Icons.edit_outlined;
    case 'execute': return Icons.terminal;
    default: return Icons.build_outlined;
  }
}

String _formatFileTargets(List<dynamic>? targets) {
  if (targets == null || targets.isEmpty) return '';
  if (targets.length == 1) return targets[0].toString();
  return '${targets.length} files  ·  ${targets.first}';
}

final _headingBuilders = <String, MarkdownElementBuilder>{
  'h1': _HeadingBuilder(),
  'h2': _HeadingBuilder(),
  'h3': _HeadingBuilder(),
  'h4': _HeadingBuilder(),
  'h5': _HeadingBuilder(),
  'h6': _HeadingBuilder(),
};

class _HeadingBuilder extends MarkdownElementBuilder {
  _HeadingBuilder();
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final level = int.tryParse(element.tag.substring(1)) ?? 1;
    final marker = '#' * level;
    final buffer = StringBuffer();

    void extractText(md.Node node) {
      if (node is md.Text) {
        buffer.write(node.text);
      } else if (node is md.Element && node.children != null) {
        for (var child in node.children!) {
          extractText(child);
        }
      }
    }

    if (element.children != null) {
      for (var child in element.children!) {
        extractText(child);
      }
    }

    final colorScheme = Theme.of(context).colorScheme;
    final headingText = buffer.toString().trim();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$marker ',
              style: TextStyle(
                color: colorScheme.primary.withOpacity(0.5),
                fontFamily: 'monospace',
                fontSize: 14,
              ),
            ),
            TextSpan(
              text: headingText,
              style: TextStyle(
                color: colorScheme.primary,
                fontSize: 14,
                fontWeight: FontWeight.w400,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final CardMessage message;
  final String providerName;
  final String? providerId;
  final Function(String requestId, String optionId)? onOptionSelected;
  final Set<String>? respondedRequestIds;

  const MessageBubble({
    super.key,
    required this.message,
    required this.providerName,
    this.providerId,
    this.onOptionSelected,
    this.respondedRequestIds,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final role = message.role.toLowerCase();
    final isUser = role == 'user';
    final isAssistant = role == 'assistant';
    final isTool = role == 'tool';
    final isSystem = role == 'system';
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;

    if (isAssistant) {
      final event = AgUiEvent.fromMessage(message);
      if (event.eventType == 'interactive_request') {
        return InteractiveRequestBlock(
          event: event,
          onOptionSelected: (optId) => onOptionSelected?.call(event.requestId!, optId),
          isResponded: respondedRequestIds?.contains(event.requestId) ?? false,
        );
      }
    }

    // Width: user/system = 85%, assistant/tool = 68% (85% * 0.8)
    final double contentMaxWidth = (isUser || isSystem)
        ? screenWidth * 0.85
        : screenWidth * 0.68;

    if (isTool) {
      return Container(
        margin: const EdgeInsets.symmetric(
            horizontal: AppConstants.space16, vertical: AppConstants.space8),
        constraints: BoxConstraints(maxWidth: contentMaxWidth),
        child: _buildToolLog(context, isDark, theme, colorScheme),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(
          horizontal: AppConstants.space16, vertical: AppConstants.space8),
      constraints: BoxConstraints(maxWidth: contentMaxWidth),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _buildHeader(theme, colorScheme, isUser, isSystem),
          const SizedBox(height: AppConstants.space4),
          _buildContent(context, theme, colorScheme, isUser, isDark),
          const SizedBox(height: AppConstants.space4),
          _buildFooter(theme, colorScheme, isUser),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme colorScheme, bool isUser, [bool isSystem = false]) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isUser && !isSystem) ...[
          Icon(IconUtil.getProviderIcon(providerId),
              size: 12, color: colorScheme.primary),
          const SizedBox(width: AppConstants.space4),
          Text(_getProviderName().toUpperCase(),
              style: theme.textTheme.labelLarge),
        ],
        if (isSystem) ...[
          Icon(Icons.settings_rounded,
              size: 12, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: AppConstants.space4),
          Text('SYSTEM CONTEXT',
              style: theme.textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant)),
        ],
        if (isUser) ...[
          Text(UICopy.you,
              style: theme.textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis))),
          const SizedBox(width: AppConstants.space4),
          Icon(Icons.person_rounded,
              size: 12,
              color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis)),
        ],
      ],
    );
  }

  Widget _buildFooter(ThemeData theme, ColorScheme colorScheme, bool isUser) {
    return Text(
      DateFormatter.formatTimeOnly(message.createdAt),
      style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 10,
          color: colorScheme.onSurface.withOpacity(AppConstants.disabledOpacity)),
    );
  }

  Widget _buildContent(BuildContext context, ThemeData theme,
      ColorScheme colorScheme, bool isUser, bool isDark) {
    final List<Widget> children = [];
    final thought = message.metadata?['thought'] as String?;
    final isReasoningType = message.metadata?['type'] == 'reasoning';
    
    // 1. Thinking Process (default expanded)
    if (isReasoningType) {
      children.add(ThinkingBlock(
        text: message.content,
        isCollapsed: false,
        styleSheet: _getMarkdownStyle(context, false),
        builders: _headingBuilders,
      ));
    } else if (thought != null && thought.isNotEmpty) {
      children.add(ThinkingBlock(
        text: thought,
        isCollapsed: false,
        styleSheet: _getMarkdownStyle(context, false),
        builders: _headingBuilders,
      ));
    }

    // 2. Main Content
    if (message.content.isNotEmpty && !isReasoningType) {
      if (message.metadata?['type'] == 'plan_update') {
        children.add(_buildPlanPanel(context));
      } else {
        children.add(
          MarkdownBody(
            data: message.content,
            selectable: true,
            styleSheet: _getMarkdownStyle(context, isUser),
            builders: _headingBuilders,
            onTapLink: (text, href, title) {
              AppLogger.info('Tapped link: $href');
            },
          ),
        );
      }
    }

    // 3. Tool Activity (Structured)
    final List<dynamic>? toolCalls = message.metadata?['tool_calls'];
    if (toolCalls != null && toolCalls.isNotEmpty) {
      children.add(const SizedBox(height: AppConstants.space8));
      for (var tc in toolCalls) {
        final toolName = tc['name'] ?? 'unknown';
        final status = tc['status'] ?? 'completed';
        final cmdPreview = tc['command_preview'] as String?;
        final fileTargets = tc['file_targets'] as List<dynamic>?;
        final opKind = tc['op_kind'] as String?;
        final displayTitle = cmdPreview ?? toolName;
        final subtitle = _formatFileTargets(fileTargets);
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: ToolPill(
            name: displayTitle,
            status: status,
            icon: _opKindIcon(opKind),
            subtitle: subtitle.isNotEmpty ? subtitle : null,
          ),
        ));
      }
    }

    return Container(
      padding: isUser 
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 10)
          : const EdgeInsets.all(0),
      decoration: BoxDecoration(
        color: isUser
            ? (isDark ? colorScheme.primaryContainer.withOpacity(0.3) : colorScheme.primary.withOpacity(0.08))
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: isUser 
          ? Border.all(color: isDark ? colorScheme.primary.withOpacity(0.2) : colorScheme.primary.withOpacity(0.1))
          : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildToolLog(BuildContext context, bool isDark, ThemeData theme, ColorScheme colorScheme) {
    final meta = message.metadata ?? {};
    final toolName = meta['name'] ?? 'unknown';
    final toolStatus = meta['status'] ?? 'completed';
    final commandPreview = meta['command_preview'] as String?;
    final fileTargets = meta['file_targets'] as List<dynamic>?;
    final opKind = meta['op_kind'] as String?;
    final diff = meta['diff'] as Map<String, dynamic>?;
    final arguments = meta['arguments'] as String?;
    final hasResult = message.content.isNotEmpty;
    final hasDiff = diff != null;

    final displayTitle = commandPreview ?? toolName;
    final displaySubtitle = _formatFileTargets(fileTargets);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: ExpansionTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        initiallyExpanded: false,
        leading: ToolPill(name: toolName, status: toolStatus),
        title: Row(
          children: [
            Icon(_opKindIcon(opKind),
                size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                displayTitle,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        subtitle: displaySubtitle.isNotEmpty
            ? Text(
                displaySubtitle,
                style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.onSurfaceVariant),
                overflow: TextOverflow.ellipsis,
              )
            : Text(
                DateFormatter.formatTimeOnly(message.createdAt),
                style: theme.textTheme.bodySmall,
              ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(
                AppConstants.space12, 8, AppConstants.space12, AppConstants.space12),
            color: isDark ? Colors.black.withOpacity(0.15) : Colors.black.withOpacity(0.02),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasDiff)
                  _buildDiffPreview(context, diff, isDark),
                if (hasResult) ...[
                  if (hasDiff) const SizedBox(height: AppConstants.space8),
                  Text(UICopy.result,
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? colorScheme.primary
                              : Colors.blueGrey)),
                  const SizedBox(height: AppConstants.space4),
                  _buildCodeBlock(context, message.content),
                ] else if (!hasDiff && arguments != null && arguments.isNotEmpty) ...[
                  Text(UICopy.arguments,
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? colorScheme.primary
                              : Colors.blueGrey)),
                  const SizedBox(height: AppConstants.space4),
                  _buildCodeBlock(context, arguments),
                ],
                if (!hasResult && !hasDiff && (arguments == null || arguments.isEmpty))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      'Running...',
                      style: TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: colorScheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildDiffPreview(BuildContext context, Map<String, dynamic>? diff, bool isDark) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (diff == null) return const SizedBox.shrink();
    final oldText = diff['old'] as String? ?? '';
    final newText = diff['new'] as String? ?? '';
    final path = diff['path'] as String?;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (path != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined,
                    size: 12, color: colorScheme.primary),
                const SizedBox(width: 4),
                Text(
                  path,
                  style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: colorScheme.primary),
                ),
              ],
            ),
          ),
        if (oldText.isNotEmpty && newText.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? Colors.black38 : Colors.grey[100],
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDiffLine(oldText, '−', colorScheme.error),
                const SizedBox(height: 4),
                _buildDiffLine(newText, '+', Colors.green),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDiffLine(String text, String prefix, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$prefix ',
            style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: color)),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _buildCodeBlock(BuildContext context, String content) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isDark ? Colors.black26 : Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        content,
        style: const TextStyle(
            fontFamily: 'monospace', fontSize: 11, height: 1.4),
      ),
    );
  }

  String _getProviderName() {
    if (providerName.isEmpty) return UICopy.agent;
    return providerName;
  }

  MarkdownStyleSheet _getMarkdownStyle(BuildContext context, bool isUser) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    const baseSize = 14.0;
    const baseHeight = 1.6;
    final bodyColor = isUser
        ? (isDark ? colorScheme.onPrimaryContainer : colorScheme.onSurface)
        : colorScheme.onSurface;

    return MarkdownStyleSheet(
      p: TextStyle(
        fontSize: baseSize,
        height: baseHeight,
        color: bodyColor,
      ),
      h1: const TextStyle(fontSize: baseSize, fontWeight: FontWeight.w400, height: baseHeight, color: Colors.transparent),
      h2: const TextStyle(fontSize: baseSize, fontWeight: FontWeight.w400, height: baseHeight, color: Colors.transparent),
      h3: const TextStyle(fontSize: baseSize, fontWeight: FontWeight.w400, height: baseHeight, color: Colors.transparent),
      h4: const TextStyle(fontSize: baseSize, fontWeight: FontWeight.w400, height: baseHeight, color: Colors.transparent),
      h5: const TextStyle(fontSize: baseSize, fontWeight: FontWeight.w400, height: baseHeight, color: Colors.transparent),
      h6: const TextStyle(fontSize: baseSize, fontWeight: FontWeight.w400, height: baseHeight, color: Colors.transparent),
      h1Align: WrapAlignment.start,
      h2Align: WrapAlignment.start,
      h3Align: WrapAlignment.start,
      h4Align: WrapAlignment.start,
      h5Align: WrapAlignment.start,
      h6Align: WrapAlignment.start,
      h1Padding: EdgeInsets.zero,
      h2Padding: EdgeInsets.zero,
      h3Padding: EdgeInsets.zero,
      h4Padding: EdgeInsets.zero,
      h5Padding: EdgeInsets.zero,
      h6Padding: EdgeInsets.zero,
      code: TextStyle(
        backgroundColor: isDark ? Colors.black38 : Colors.grey[200],
        fontFamily: 'monospace',
        fontSize: baseSize - 1,
        color: colorScheme.primary,
      ),
      codeblockDecoration: BoxDecoration(
        color: isDark ? Colors.black38 : Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.3)),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      blockquote: TextStyle(
        color: colorScheme.onSurfaceVariant,
        fontSize: baseSize,
        height: baseHeight,
      ),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: colorScheme.onSurfaceVariant, width: 2)),
      ),
      listBullet: TextStyle(
        fontSize: baseSize,
        color: colorScheme.onSurfaceVariant,
      ),
      listBulletPadding: const EdgeInsets.only(right: 4),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.transparent, width: 0)),
      ),
      em: TextStyle(
        fontStyle: FontStyle.normal,
        color: bodyColor,
        fontSize: baseSize,
        height: baseHeight,
      ),
      strong: TextStyle(
        fontWeight: FontWeight.w600,
        color: bodyColor,
        fontSize: baseSize,
        height: baseHeight,
      ),
      del: TextStyle(
        decoration: TextDecoration.lineThrough,
        color: colorScheme.onSurfaceVariant,
        fontSize: baseSize,
        height: baseHeight,
      ),
    );
  }

  Widget _buildPlanPanel(BuildContext context) {
    try {
      final rawMap = jsonDecode(message.content);
      final plan = AgentPlan.fromJson(rawMap);
      
      return PlanPanel(
        plan: plan,
        styleSheet: _getMarkdownStyle(context, false),
        builders: _headingBuilders,
      );
    } catch (e) {
      AppLogger.error('Plan rendering error', e);
      return const Text(UICopy.failedToLoadPlan);
    }
  }
}

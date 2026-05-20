import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/card_message.dart';
import '../utils/date_formatter.dart';
import '../constants/app_constants.dart';
import '../utils/icon_util.dart';
import '../constants/ui_copy.dart';
import '../utils/app_logger.dart';
import '../widgets/ag_ui/thinking_block.dart';
import '../widgets/ag_ui/interactive_request_block.dart';
import '../widgets/message_shell.dart';
import '../theme/markdown_theme.dart';
import '../models/ag_ui_event.dart';
import '../models/agent_plan.dart';
import 'plan_panel.dart';

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
    final screenWidth = MediaQuery.of(context).size.width;

    if (isAssistant) {
      final event = AgUiEvent.fromMessage(message);
      if (event.eventType == 'interactive_request') {
        return Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppConstants.space16, vertical: AppConstants.space8),
          child: InteractiveRequestBlock(
            event: event,
            onOptionSelected: (optId) =>
                onOptionSelected?.call(event.requestId!, optId),
            isResponded: respondedRequestIds?.contains(event.requestId) ?? false,
          ),
        );
      }
    }

    final isDesktopPlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
    final bool shouldUseUnifiedDesktopWidth =
        isDesktopPlatform && screenWidth >= 900;

    final double contentMaxWidth = shouldUseUnifiedDesktopWidth
        ? screenWidth * 0.85
        : ((isUser || isSystem) ? screenWidth * 0.85 : screenWidth * 0.75);

    Widget content;
    if (isTool) {
      content = _buildToolLog(context);
    } else {
      content = Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _buildContent(context, isUser, isSystem),
          const SizedBox(height: AppConstants.space4),
          _buildFooter(theme, colorScheme, isUser),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(
          horizontal: AppConstants.space16, vertical: AppConstants.space8),
      constraints: BoxConstraints(maxWidth: contentMaxWidth),
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: SelectionArea(child: content),
    );
  }

  Widget _buildFooter(ThemeData theme, ColorScheme colorScheme, bool isUser) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        DateFormatter.formatTimeOnly(message.createdAt),
        style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 10,
            color:
                colorScheme.onSurface.withOpacity(AppConstants.disabledOpacity)),
      ),
    );
  }

  Widget _buildContent(BuildContext context, bool isUser, bool isSystem) {
    final List<Widget> children = [];
    final thought = message.metadata?['thought'] as String?;
    final isReasoningType = message.metadata?['type'] == 'reasoning';
    final commandPreview = message.metadata?['command_preview'] as String?;

    // 1. Thinking Process
    if (isReasoningType) {
      children.add(ThinkingBlock(
        text: message.content,
        isCollapsed: false,
      ));
    } else if (thought != null && thought.isNotEmpty) {
      children.add(ThinkingBlock(
        text: thought,
        isCollapsed: true,
      ));
    }

    // 2. Main Content
    if (message.content.isNotEmpty && !isReasoningType) {
      // Deduplication logic: If assistant content is just repeating the tool call that we'll show in metadata/tool log, skip it.
      bool isRedundantToolCall = !isUser && !isSystem && 
          commandPreview != null && 
          message.content.trim() == commandPreview.trim();

      if (message.metadata?['type'] == 'plan_update') {
        children.add(_buildPlanPanel(context));
      } else if (!isRedundantToolCall) {
        if (children.isNotEmpty) children.add(const SizedBox(height: 8));
        children.add(MessageShell(
          isUser: isUser,
          headerLeading: isSystem
              ? const Icon(Icons.settings_rounded, size: 14)
              : (isUser
                  ? const Icon(Icons.person_rounded, size: 14)
                  : Icon(IconUtil.getProviderIcon(providerId), size: 14)),
          title: isSystem
              ? 'SYSTEM CONTEXT'
              : (isUser ? UICopy.you : _getProviderName().toUpperCase()),
          child: MarkdownBody(
            data: message.content,
            selectable: false, // Managed by high-level SelectionArea
            styleSheet: MarkdownTheme.getStyle(context, isUser: isUser),
            builders: MarkdownTheme.getBuilders(context),
            onTapLink: (text, href, title) {
              AppLogger.info('Tapped link: $href');
            },
          ),
        ));
      }
    }

    return Column(
      crossAxisAlignment:
          isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: children.map((c) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: c,
      )).toList(),
    );
  }

  Widget _buildToolLog(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
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

    return _ToolLogShell(
      toolName: toolName,
      status: toolStatus,
      opKind: opKind,
      title: displayTitle,
      subtitle: displaySubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasDiff) _buildDiffPreview(context, diff),
          if (hasResult) ...[
            if (hasDiff) const SizedBox(height: AppConstants.space8),
            Text(UICopy.result,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary)),
            const SizedBox(height: AppConstants.space4),
            _buildCodeBlock(context, message.content),
          ] else if (!hasDiff && arguments != null && arguments.isNotEmpty) ...[
            Text(UICopy.arguments,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary)),
            const SizedBox(height: AppConstants.space4),
            _buildCodeBlock(context, arguments),
          ],
          if (!hasResult && !hasDiff && (arguments == null || arguments.isEmpty))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text('Running...',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDiffPreview(BuildContext context, Map<String, dynamic>? diff) {
    final colorScheme = Theme.of(context).colorScheme;
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
              color: colorScheme.surfaceVariant.withOpacity(0.2),
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
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 11, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _buildCodeBlock(BuildContext context, String content) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.space12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withOpacity(0.2),
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
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

  Widget _buildPlanPanel(BuildContext context) {
    try {
      final rawMap = jsonDecode(message.content);
      final plan = AgentPlan.fromJson(rawMap);
      return PlanPanel(plan: plan);
    } catch (e) {
      AppLogger.error('Plan rendering error', e);
      return const Text(UICopy.failedToLoadPlan);
    }
  }
}

IconData _opKindIcon(String? opKind) {
  switch (opKind) {
    case 'read':
      return Icons.description_outlined;
    case 'search':
      return Icons.search;
    case 'edit':
      return Icons.edit_outlined;
    case 'execute':
      return Icons.terminal;
    default:
      return Icons.build_outlined;
  }
}

String _formatFileTargets(List<dynamic>? targets) {
  if (targets == null || targets.isEmpty) return '';
  if (targets.length == 1) return targets[0].toString();
  return '${targets.length} files  ·  ${targets.first}';
}

class _ToolLogShell extends StatefulWidget {
  final String toolName;
  final String status;
  final String? opKind;
  final String title;
  final String? subtitle;
  final Widget child;

  const _ToolLogShell({
    required this.toolName,
    required this.status,
    this.opKind,
    required this.title,
    this.subtitle,
    required this.child,
  });

  @override
  State<_ToolLogShell> createState() => _ToolLogShellState();
}

class _ToolLogShellState extends State<_ToolLogShell> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return MessageShell(
      isExpandable: true,
      isExpanded: _isExpanded,
      onToggleExpand: () => setState(() => _isExpanded = !_isExpanded),
      headerPadding: const EdgeInsets.symmetric(
          horizontal: AppConstants.space12, vertical: 8),
      headerLeading: Icon(_opKindIcon(widget.opKind),
          size: 16, color: colorScheme.primary),
      title: widget.title,
      subtitle: widget.subtitle,
      headerTrailing: _buildCompactStatus(widget.status, colorScheme),
      padding: const EdgeInsets.fromLTRB(
          AppConstants.space12, 0, AppConstants.space12, AppConstants.space12),
      child: widget.child,
    );
  }

  Widget _buildCompactStatus(String status, ColorScheme colorScheme) {
    switch (status.toLowerCase()) {
      case 'completed':
      case 'success':
        return const Icon(Icons.check_circle_outline_rounded,
            size: 14, color: Colors.green);
      case 'failed':
      case 'error':
        return Icon(Icons.error_outline_rounded,
            size: 14, color: colorScheme.error);
      case 'running':
      case 'executing':
        return const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2));
      default:
        return Icon(Icons.help_outline_rounded,
            size: 14, color: colorScheme.onSurfaceVariant.withOpacity(0.5));
    }
  }
}

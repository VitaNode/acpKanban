import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/agent_plan.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';
import '../theme/markdown_theme.dart';
import '../widgets/message_shell.dart';

class PlanPanel extends StatefulWidget {
  final AgentPlan plan;

  const PlanPanel({super.key, required this.plan});

  @override
  State<PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends State<PlanPanel> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final completedCount = widget.plan.entries
        .where((s) => s.status == PlanStepStatus.completed)
        .length;

    return MessageShell(
      isExpandable: true,
      isExpanded: _isExpanded,
      onToggleExpand: () => setState(() => _isExpanded = !_isExpanded),
      headerLeading: Icon(
        widget.plan.progress >= 1.0
            ? Icons.check_circle_rounded
            : Icons.assignment_rounded,
        color: colorScheme.primary,
        size: 18,
      ),
      title: 'Agent Execution Plan ($completedCount/${widget.plan.entries.length})',
      headerTrailing: Text(
        '${(widget.plan.progress * 100).toInt()}%',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: colorScheme.primary,
        ),
      ),
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppConstants.space12, vertical: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
              child: LinearProgressIndicator(
                value: widget.plan.progress,
                backgroundColor: colorScheme.surfaceContainer,
                color: colorScheme.primary,
                minHeight: 4,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppConstants.space12, 0, AppConstants.space12, AppConstants.space12),
            child: Column(
              children: widget.plan.entries
                  .map((step) => _buildStepItem(step))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepItem(PlanStep step) {
    final isCompleted = step.status == PlanStepStatus.completed;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final styleSheet = MarkdownTheme.getStyle(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppConstants.space8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusIcon(step.status),
          const SizedBox(width: AppConstants.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MarkdownBody(
                  data: step.content,
                  selectable: false,
                  styleSheet: styleSheet.copyWith(
                    p: styleSheet.p?.copyWith(
                      color: isCompleted
                          ? colorScheme.onSurface
                              .withOpacity(AppConstants.mediumEmphasis)
                          : colorScheme.onSurface,
                      decoration:
                          isCompleted ? TextDecoration.lineThrough : null,
                      fontWeight: step.status == PlanStepStatus.inProgress
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  builders: MarkdownTheme.getBuilders(context),
                ),
                if (step.priority != PlanStepPriority.medium)
                  Padding(
                    padding: const EdgeInsets.only(top: AppConstants.space4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color:
                            _getPriorityColor(step.priority).withOpacity(0.1),
                        borderRadius:
                            BorderRadius.circular(AppConstants.radiusSmall),
                      ),
                      child: Text(
                        step.priority.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: _getPriorityColor(step.priority),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIcon(PlanStepStatus status) {
    final customColors = Theme.of(context).extension<CustomColors>()!;
    final colorScheme = Theme.of(context).colorScheme;

    switch (status) {
      case PlanStepStatus.completed:
        return Icon(Icons.check_circle_rounded,
            size: 16, color: customColors.success);
      case PlanStepStatus.inProgress:
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: colorScheme.primary),
          ),
        );
      case PlanStepStatus.failed:
        return Icon(Icons.error_rounded, size: 16, color: colorScheme.error);
      default:
        return Icon(Icons.radio_button_unchecked_rounded,
            size: 16,
            color: colorScheme.onSurface
                .withOpacity(AppConstants.disabledOpacity));
    }
  }

  Color _getPriorityColor(PlanStepPriority priority) {
    final customColors = Theme.of(context).extension<CustomColors>()!;
    switch (priority) {
      case PlanStepPriority.high:
        return Theme.of(context).colorScheme.error;
      case PlanStepPriority.low:
        return customColors.info!;
      default:
        return Theme.of(context)
            .colorScheme
            .onSurface
            .withOpacity(AppConstants.mediumEmphasis);
    }
  }
}

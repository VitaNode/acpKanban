import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/agent_plan.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

class PlanPanel extends StatefulWidget {
  final AgentPlan plan;
  final MarkdownStyleSheet? styleSheet;

  const PlanPanel({super.key, required this.plan, this.styleSheet});

  @override
  State<PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends State<PlanPanel> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final completedCount = widget.plan.entries.where((s) => s.status == PlanStepStatus.completed).length;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppConstants.space8),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: theme.dividerTheme.color!),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
            child: Padding(
              padding: const EdgeInsets.all(AppConstants.space16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(
                        widget.plan.progress >= 1.0 ? Icons.check_circle_rounded : Icons.assignment_rounded,
                        color: colorScheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: AppConstants.space12),
                      Expanded(
                        child: Text(
                          'Agent Execution Plan ($completedCount/${widget.plan.entries.length})',
                          style: theme.textTheme.headlineMedium?.copyWith(fontSize: 15),
                        ),
                      ),
                      Text(
                        '${(widget.plan.progress * 100).toInt()}%',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: AppConstants.space8),
                      Icon(
                        _isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                        color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppConstants.space12),
                  // Progress Bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
                    child: LinearProgressIndicator(
                      value: widget.plan.progress,
                      backgroundColor: colorScheme.surfaceContainer,
                      color: colorScheme.primary,
                      minHeight: 4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          if (_isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppConstants.space16, 0, AppConstants.space16, AppConstants.space16),
              child: Column(
                children: widget.plan.entries.map((step) => _buildStepItem(step)).toList(),
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
                if (widget.styleSheet != null)
                  MarkdownBody(
                    data: step.content,
                    styleSheet: widget.styleSheet!.copyWith(
                      p: widget.styleSheet!.p?.copyWith(
                        color: isCompleted ? colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis) : colorScheme.onSurface,
                        decoration: isCompleted ? TextDecoration.lineThrough : null,
                        fontWeight: step.status == PlanStepStatus.inProgress ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  )
                else
                  Text(
                    step.content,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isCompleted ? colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis) : colorScheme.onSurface,
                      decoration: isCompleted ? TextDecoration.lineThrough : null,
                      fontWeight: step.status == PlanStepStatus.inProgress ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                if (step.priority != PlanStepPriority.medium)
                  Padding(
                    padding: const EdgeInsets.only(top: AppConstants.space4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _getPriorityColor(step.priority).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
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
        return Icon(Icons.check_circle_rounded, size: 18, color: customColors.success);
      case PlanStepStatus.inProgress:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: colorScheme.primary),
        );
      case PlanStepStatus.failed:
        return Icon(Icons.error_rounded, size: 18, color: colorScheme.error);
      default:
        return Icon(Icons.radio_button_unchecked_rounded, size: 18, 
            color: colorScheme.onSurface.withOpacity(AppConstants.disabledOpacity));
    }
  }

  Color _getPriorityColor(PlanStepPriority priority) {
    final customColors = Theme.of(context).extension<CustomColors>()!;
    switch (priority) {
      case PlanStepPriority.high: return Theme.of(context).colorScheme.error;
      case PlanStepPriority.low: return customColors.info!;
      default: return Theme.of(context).colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis);
    }
  }
}

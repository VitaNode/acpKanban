import 'package:flutter/material.dart';
import '../models/agent_plan.dart';
import '../constants/app_constants.dart';

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
    final completedCount = widget.plan.entries.where((s) => s.status == PlanStepStatus.completed).length;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppConstants.space8),
      decoration: BoxDecoration(
        color: AppConstants.backgroundColor,
        borderRadius: BorderRadius.circular(AppConstants.space16),
        border: Border.all(color: Colors.grey.shade200),
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
            borderRadius: BorderRadius.circular(AppConstants.space16),
            child: Padding(
              padding: const EdgeInsets.all(AppConstants.space16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(
                        widget.plan.progress >= 1.0 ? Icons.check_circle_rounded : Icons.assignment_rounded,
                        color: AppConstants.primaryColor,
                        size: 20,
                      ),
                      const SizedBox(width: AppConstants.space12),
                      Expanded(
                        child: Text(
                          'Agent Execution Plan ($completedCount/${widget.plan.entries.length})',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 15),
                        ),
                      ),
                      Text(
                        '${(widget.plan.progress * 100).toInt()}%',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppConstants.primaryColor,
                        ),
                      ),
                      const SizedBox(width: AppConstants.space8),
                      Icon(
                        _isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                        color: AppConstants.textHint,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppConstants.space12),
                  // Progress Bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppConstants.space4),
                    child: LinearProgressIndicator(
                      value: widget.plan.progress,
                      backgroundColor: Colors.grey.shade100,
                      color: AppConstants.primaryColor,
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
                Text(
                  step.content,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isCompleted ? AppConstants.textHint : AppConstants.textPrimary,
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
                        borderRadius: BorderRadius.circular(AppConstants.space4),
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
    switch (status) {
      case PlanStepStatus.completed:
        return const Icon(Icons.check_circle_rounded, size: 18, color: AppConstants.successColor);
      case PlanStepStatus.inProgress:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppConstants.primaryColor),
        );
      case PlanStepStatus.failed:
        return const Icon(Icons.error_rounded, size: 18, color: AppConstants.errorColor);
      default:
        return Icon(Icons.radio_button_unchecked_rounded, size: 18, color: Colors.grey.shade300);
    }
  }

  Color _getPriorityColor(PlanStepPriority priority) {
    switch (priority) {
      case PlanStepPriority.high: return AppConstants.errorColor;
      case PlanStepPriority.low: return Colors.blue.shade600;
      default: return Colors.grey;
    }
  }
}

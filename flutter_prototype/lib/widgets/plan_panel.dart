import 'package:flutter/material.dart';
import '../models/agent_plan.dart';

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
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.0),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
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
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12.0)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(
                        widget.plan.progress >= 1.0 ? Icons.check_circle : Icons.assignment,
                        color: const Color(0xFF008080),
                        size: 20,
                      ),
                      const SizedBox(width: 12.0),
                      Expanded(
                        child: Text(
                          '执行计划 ($completedCount/${widget.plan.entries.length})',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF212121),
                          ),
                        ),
                      ),
                      Text(
                        '${(widget.plan.progress * 100).toInt()}%',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF008080),
                        ),
                      ),
                      const SizedBox(width: 8.0),
                      Icon(
                        _isExpanded ? Icons.expand_less : Icons.expand_more,
                        color: Colors.grey,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12.0),
                  // Progress Bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4.0),
                    child: LinearProgressIndicator(
                      value: widget.plan.progress,
                      backgroundColor: Colors.grey.shade100,
                      color: const Color(0xFF008080),
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          if (_isExpanded)
            Padding(
              padding: const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16.0),
              child: Column(
                children: widget.plan.entries.map((step) => _buildStepItem(step)).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStepItem(PlanStep step) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusIcon(step.status),
          const SizedBox(width: 12.0),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.content,
                  style: TextStyle(
                    fontSize: 14,
                    color: step.status == PlanStepStatus.completed 
                        ? Colors.grey 
                        : const Color(0xFF212121),
                    decoration: step.status == PlanStepStatus.completed 
                        ? TextDecoration.lineThrough 
                        : null,
                    fontWeight: step.status == PlanStepStatus.inProgress 
                        ? FontWeight.bold 
                        : FontWeight.normal,
                  ),
                ),
                if (step.priority != PlanStepPriority.medium)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _getPriorityColor(step.priority).withAlpha(25),
                        borderRadius: BorderRadius.circular(4.0),
                      ),
                      child: Text(
                        step.priority.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: _getPriorityColor(step.priority),
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
        return const Icon(Icons.check_circle, size: 18, color: Colors.green);
      case PlanStepStatus.inProgress:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF008080)),
        );
      case PlanStepStatus.failed:
        return const Icon(Icons.error, size: 18, color: Colors.red);
      default:
        return Icon(Icons.radio_button_unchecked, size: 18, color: Colors.grey.shade400);
    }
  }

  Color _getPriorityColor(PlanStepPriority priority) {
    switch (priority) {
      case PlanStepPriority.high: return Colors.orange.shade800;
      case PlanStepPriority.low: return Colors.blue.shade700;
      default: return Colors.grey;
    }
  }
}

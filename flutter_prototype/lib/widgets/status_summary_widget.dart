import 'dart:async';
import 'package:flutter/material.dart';
import '../models/project.dart';
import '../constants/app_constants.dart';

enum AgentState {
  idle,
  working,
  needsAuthorization,
  completed
}

class ProjectAgentStatus {
  final Project project;
  final AgentState state;
  final DateTime? startTime;
  final String? lastMessage;

  ProjectAgentStatus({
    required this.project,
    required this.state,
    this.startTime,
    this.lastMessage,
  });
}

class StatusSummaryWidget extends StatefulWidget {
  final List<ProjectAgentStatus> statuses;

  const StatusSummaryWidget({super.key, required this.statuses});

  @override
  State<StatusSummaryWidget> createState() => _StatusSummaryWidgetState();
}

class _StatusSummaryWidgetState extends State<StatusSummaryWidget> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeStatuses = widget.statuses.where((s) => s.state != AgentState.idle).toList();
    if (activeStatuses.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: AppConstants.backgroundColor,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16),
        itemCount: activeStatuses.length,
        itemBuilder: (context, index) {
          return _buildStatusChip(activeStatuses[index]);
        },
      ),
    );
  }

  Widget _buildStatusChip(ProjectAgentStatus status) {
    Color color;
    String text;
    IconData icon;

    switch (status.state) {
      case AgentState.working:
        color = Colors.orange.shade700;
        icon = Icons.bolt_rounded;
        final duration = DateTime.now().difference(status.startTime ?? DateTime.now());
        text = 'Working (${_formatDuration(duration)})';
        break;
      case AgentState.needsAuthorization:
        color = AppConstants.errorColor;
        icon = Icons.lock_clock_rounded;
        text = 'Needs Auth';
        break;
      case AgentState.completed:
        color = AppConstants.successColor;
        icon = Icons.check_circle_rounded;
        text = 'Completed';
        break;
      default:
        return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(right: AppConstants.space8, top: AppConstants.space8, bottom: AppConstants.space8),
      padding: const EdgeInsets.symmetric(horizontal: AppConstants.space12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppConstants.space6),
          Text(
            status.project.name,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppConstants.textPrimary),
          ),
          const SizedBox(width: AppConstants.space4),
          Text(
            text,
            style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(d.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(d.inSeconds.remainder(60));
    return "${twoDigits(d.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }
}

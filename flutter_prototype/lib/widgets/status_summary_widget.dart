import 'dart:async';
import 'package:flutter/material.dart';
import '../models/project.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

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

    final theme = Theme.of(context);

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: theme.dividerTheme.color!)),
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final customColors = theme.extension<CustomColors>()!;
    
    Color color;
    String text;
    IconData icon;

    switch (status.state) {
      case AgentState.working:
        color = customColors.warning!;
        icon = Icons.bolt_rounded;
        final duration = DateTime.now().difference(status.startTime ?? DateTime.now());
        text = 'Working (${_formatDuration(duration)})';
        break;
      case AgentState.needsAuthorization:
        color = colorScheme.error;
        icon = Icons.lock_clock_rounded;
        text = 'Needs Auth';
        break;
      case AgentState.completed:
        color = customColors.success!;
        icon = Icons.check_circle_rounded;
        text = 'Completed';
        break;
      default:
        return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppConstants.space4,
        vertical: AppConstants.space8,
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppConstants.space12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(AppConstants.radiusFull),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppConstants.space8),
          Text(
            status.project.name,
            style: theme.textTheme.labelLarge?.copyWith(
              fontSize: 11,
              color: colorScheme.onSurface.withOpacity(AppConstants.highEmphasis),
            ),
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

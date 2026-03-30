import 'dart:async';
import 'package:flutter/material.dart';
import '../models/project.dart';

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
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
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
        color = Colors.orange;
        icon = Icons.bolt;
        final duration = DateTime.now().difference(status.startTime ?? DateTime.now());
        text = 'Working (${_formatDuration(duration)})';
        break;
      case AgentState.needsAuthorization:
        color = Colors.red;
        icon = Icons.lock_clock;
        text = 'Needs Auth';
        break;
      case AgentState.completed:
        color = Colors.green;
        icon = Icons.check_circle;
        text = 'Completed';
        break;
      default:
        return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            '${status.project.name}: ',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
          Text(
            text,
            style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
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

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/timeline_event.dart';

class TimelineView extends StatelessWidget {
  final List<TimelineEvent> events;
  final bool isLoading;
  final VoidCallback onRefresh;

  const TimelineView({
    super.key,
    required this.events,
    this.isLoading = false,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading && events.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (events.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No events recorded yet.'),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: events.length,
        separatorBuilder: (context, index) => const SizedBox(height: 16),
        itemBuilder: (context, index) {
          return _buildEventItem(context, events[index]);
        },
      ),
    );
  }

  Widget _buildEventItem(BuildContext context, TimelineEvent event) {
    final iconData = _getIconData(event.type);
    final iconColor = _getIconColor(event.type);
    final timeStr = _formatDateTime(event.createdAt);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(iconData, color: iconColor, size: 18),
            ),
            // Vertical line (simulated)
            Container(
              width: 2,
              height: 40,
              color: Colors.grey[200],
            ),
          ],
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _getEventTitle(event.type),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: iconColor,
                    ),
                  ),
                  Text(
                    timeStr,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                event.content,
                style: const TextStyle(fontSize: 14),
              ),
              if (event.metadata != null && event.metadata!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey[200]!),
                  ),
                  child: Text(
                    event.metadata.toString(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Colors.blueGrey,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  IconData _getIconData(TimelineEventType type) {
    switch (type) {
      case TimelineEventType.cardCreated:
        return Icons.add_task;
      case TimelineEventType.cardUpdated:
        return Icons.edit_note;
      case TimelineEventType.cardDeleted:
        return Icons.delete_outline;
      case TimelineEventType.cardMoved:
        return Icons.move_up;
      case TimelineEventType.aiAction:
        return Icons.smart_toy;
      case TimelineEventType.userAction:
        return Icons.person;
      case TimelineEventType.columnCreated:
        return Icons.add_circle_outline;
      case TimelineEventType.columnUpdated:
        return Icons.edit;
      case TimelineEventType.columnDeleted:
        return Icons.remove_circle_outline;
      case TimelineEventType.columnsReordered:
        return Icons.swap_vert;
      case TimelineEventType.projectCreated:
        return Icons.create_new_folder;
      default:
        return Icons.info_outline;
    }
  }

  Color _getIconColor(TimelineEventType type) {
    switch (type) {
      case TimelineEventType.cardCreated:
        return Colors.green;
      case TimelineEventType.cardUpdated:
        return Colors.blue;
      case TimelineEventType.cardDeleted:
        return Colors.red;
      case TimelineEventType.cardMoved:
        return Colors.orange;
      case TimelineEventType.aiAction:
        return Colors.indigo;
      case TimelineEventType.userAction:
        return Colors.blueGrey;
      case TimelineEventType.columnCreated:
        return Colors.teal;
      case TimelineEventType.columnUpdated:
        return Colors.purple;
      case TimelineEventType.columnDeleted:
        return Colors.red[400]!;
      case TimelineEventType.columnsReordered:
        return Colors.amber;
      case TimelineEventType.projectCreated:
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  String _getEventTitle(TimelineEventType type) {
    switch (type) {
      case TimelineEventType.cardCreated:
        return 'Card Created';
      case TimelineEventType.cardUpdated:
        return 'Card Updated';
      case TimelineEventType.cardDeleted:
        return 'Card Deleted';
      case TimelineEventType.cardMoved:
        return 'Card Moved';
      case TimelineEventType.aiAction:
        return 'AI Action';
      case TimelineEventType.userAction:
        return 'User Action';
      case TimelineEventType.columnCreated:
        return 'Column Created';
      case TimelineEventType.columnUpdated:
        return 'Column Updated';
      case TimelineEventType.columnDeleted:
        return 'Column Deleted';
      case TimelineEventType.columnsReordered:
        return 'Columns Reordered';
      case TimelineEventType.projectCreated:
        return 'Project Created';
      default:
        return 'Project Event';
    }
  }

  String _formatDateTime(String dateStr) {
    try {
      final dt = DateTime.parse(dateStr).toLocal();
      return DateFormat('MM/dd HH:mm').format(dt);
    } catch (e) {
      return dateStr;
    }
  }
}

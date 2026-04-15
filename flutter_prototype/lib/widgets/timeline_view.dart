import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/timeline_event.dart';
import '../constants/app_constants.dart';

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
            const Icon(Icons.history_rounded, size: 64, color: AppConstants.textHint),
            const SizedBox(height: AppConstants.space16),
            Text('No events recorded yet.', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppConstants.textHint)),
            const SizedBox(height: AppConstants.space16),
            TextButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.builder(
        padding: const EdgeInsets.all(AppConstants.space16),
        itemCount: events.length,
        itemBuilder: (context, index) {
          final isLast = index == events.length - 1;
          return _buildEventItem(context, events[index], isLast);
        },
      ),
    );
  }

  Widget _buildEventItem(BuildContext context, TimelineEvent event, bool isLast) {
    final iconData = _getIconData(event.type);
    final iconColor = _getIconColor(event.type);
    final timeStr = _formatDateTime(event.createdAt);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                padding: const EdgeInsets.all(AppConstants.space8),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(iconData, color: iconColor, size: 16),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(vertical: AppConstants.space4),
                    color: Colors.grey.shade200,
                  ),
                ),
            ],
          ),
          const SizedBox(width: AppConstants.space16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _getEventTitle(event.type).toUpperCase(),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        color: iconColor,
                        letterSpacing: 0.5,
                      ),
                    ),
                    Text(
                      timeStr,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
                    ),
                  ],
                ),
                const SizedBox(height: AppConstants.space4),
                Text(
                  event.content,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                if (event.metadata != null && event.metadata!.isNotEmpty) ...[
                  const SizedBox(height: AppConstants.space8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppConstants.space8),
                    decoration: BoxDecoration(
                      color: AppConstants.surfaceColor,
                      borderRadius: BorderRadius.circular(AppConstants.space8),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Text(
                      event.metadata.toString(),
                      style: const TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: AppConstants.textSecondary,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: AppConstants.space24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _getIconData(TimelineEventType type) {
    switch (type) {
      case TimelineEventType.cardCreated:
        return Icons.add_task_rounded;
      case TimelineEventType.cardUpdated:
        return Icons.edit_note_rounded;
      case TimelineEventType.cardDeleted:
        return Icons.delete_outline_rounded;
      case TimelineEventType.cardMoved:
        return Icons.move_up_rounded;
      case TimelineEventType.aiAction:
        return Icons.auto_awesome_rounded;
      case TimelineEventType.userAction:
        return Icons.person_rounded;
      case TimelineEventType.columnCreated:
        return Icons.add_circle_outline_rounded;
      case TimelineEventType.columnUpdated:
        return Icons.edit_rounded;
      case TimelineEventType.columnDeleted:
        return Icons.remove_circle_outline_rounded;
      case TimelineEventType.columnsReordered:
        return Icons.reorder_rounded;
      case TimelineEventType.projectCreated:
        return Icons.create_new_folder_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  Color _getIconColor(TimelineEventType type) {
    switch (type) {
      case TimelineEventType.cardCreated:
        return AppConstants.successColor;
      case TimelineEventType.cardUpdated:
        return Colors.blue.shade600;
      case TimelineEventType.cardDeleted:
        return AppConstants.errorColor;
      case TimelineEventType.cardMoved:
        return Colors.orange.shade700;
      case TimelineEventType.aiAction:
        return AppConstants.primaryColor;
      case TimelineEventType.userAction:
        return Colors.blueGrey.shade600;
      case TimelineEventType.columnCreated:
        return Colors.teal.shade600;
      case TimelineEventType.columnUpdated:
        return Colors.indigo.shade600;
      default:
        return Colors.grey.shade600;
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
        return 'AI Operation';
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
      return DateFormat('MMM dd, HH:mm').format(dt);
    } catch (e) {
      return dateStr;
    }
  }
}

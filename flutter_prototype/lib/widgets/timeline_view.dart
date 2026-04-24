import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/timeline_event.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (isLoading && events.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (events.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history_rounded, size: 64, 
                color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis)),
            const SizedBox(height: AppConstants.space16),
            Text('No events recorded yet.', 
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis))),
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final iconData = _getIconData(event.type);
    final iconColor = _getIconColor(context, event.type);
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
                    color: theme.dividerTheme.color,
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
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                    ),
                  ],
                ),
                const SizedBox(height: AppConstants.space4),
                Text(
                  event.content,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                if (event.metadata != null && event.metadata!.isNotEmpty) ...[
                  const SizedBox(height: AppConstants.space8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppConstants.space8),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
                      border: Border.all(color: theme.dividerTheme.color!),
                    ),
                    child: Text(
                      event.metadata.toString(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 10,
                        fontFamily: 'monospace',
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

  Color _getIconColor(BuildContext context, TimelineEventType type) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final customColors = theme.extension<CustomColors>()!;

    switch (type) {
      case TimelineEventType.cardCreated:
        return customColors.success!;
      case TimelineEventType.cardUpdated:
        return colorScheme.primary;
      case TimelineEventType.cardDeleted:
        return colorScheme.error;
      case TimelineEventType.cardMoved:
        return customColors.warning!;
      case TimelineEventType.aiAction:
        return colorScheme.primary;
      case TimelineEventType.userAction:
        return colorScheme.secondary;
      case TimelineEventType.columnCreated:
        return customColors.success!;
      case TimelineEventType.columnUpdated:
        return colorScheme.primary;
      default:
        return colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis);
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

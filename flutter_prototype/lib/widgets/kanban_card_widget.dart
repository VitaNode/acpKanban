import 'package:flutter/material.dart';
import '../models/kanban_card.dart';
import '../constants/app_constants.dart';
import '../constants/ui_copy.dart';
import '../theme/app_theme.dart';

class KanbanCardWidget extends StatelessWidget {
  final KanbanCard card;
  final VoidCallback onTap;
  final VoidCallback onSessionTap;
  final Function(KanbanCard)? onComplete;
  final Function(KanbanCard)? onUncomplete;
  final Function(KanbanCard)? onDelete;

  const KanbanCardWidget({
    super.key,
    required this.card,
    required this.onTap,
    required this.onSessionTap,
    this.onComplete,
    this.onUncomplete,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isCompleted = card.isCompleted;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final customColors = theme.extension<CustomColors>()!;

    final cardWidget = Card(
      elevation: isCompleted ? 0 : 1,
      margin: const EdgeInsets.symmetric(
          horizontal: AppConstants.space8, vertical: AppConstants.space4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.space12),
          child: Opacity(
            opacity: isCompleted ? AppConstants.mediumEmphasis : 1.0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isCompleted)
                      Padding(
                        padding: const EdgeInsets.only(
                            right: AppConstants.space8, top: 2),
                        child: Icon(Icons.check_circle,
                            size: 16, color: customColors.success),
                      ),
                    Expanded(
                      child: Text(
                        card.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          decoration:
                              isCompleted ? TextDecoration.lineThrough : null,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppConstants.space8),
                Row(
                  children: [
                    if (card.description.isNotEmpty)
                      Icon(
                        Icons.notes_rounded,
                        size: 16,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    if (card.summary != null && card.summary!.isNotEmpty) ...[
                      if (card.description.isNotEmpty)
                        const SizedBox(width: AppConstants.space8),
                      Icon(
                        Icons.article_outlined,
                        size: 16,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ],
                    const Spacer(),
                    InkWell(
                      onTap: onSessionTap,
                      borderRadius:
                          BorderRadius.circular(AppConstants.radiusSmall),
                      child: _buildSessionBadge(context),
                    ),
                    _buildMenu(context),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return LongPressDraggable<KanbanCard>(
      data: card,
      feedback: SizedBox(
        width: 280,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
          child: cardWidget,
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.2,
        child: cardWidget,
      ),
      child: cardWidget,
    );
  }

  Widget _buildMenu(BuildContext context) {
    final customColors = Theme.of(context).extension<CustomColors>()!;
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz,
          size: 18, color: Theme.of(context).textTheme.bodySmall?.color),
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value == 'complete') onComplete?.call(card);
        if (value == 'uncomplete') onUncomplete?.call(card);
        if (value == 'delete') onDelete?.call(card);
      },
      itemBuilder: (context) => [
        if (card.status == 'active')
          PopupMenuItem(
            value: 'complete',
            child: Row(
              children: [
                Icon(Icons.check_circle_outline,
                    size: 18, color: customColors.success),
                const SizedBox(width: 8),
                const Text(UICopy.complete),
              ],
            ),
          ),
        if (card.status == 'completed')
          PopupMenuItem(
            value: 'uncomplete',
            child: Row(
              children: [
                Icon(Icons.history, size: 18, color: customColors.warning),
                const SizedBox(width: 8),
                const Text(UICopy.reactivate),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline,
                  size: 18, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              const Text(UICopy.delete),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSessionBadge(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline_rounded,
              size: 12, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(
            '${card.sessionCount}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

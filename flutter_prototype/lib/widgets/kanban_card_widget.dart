import 'package:flutter/material.dart';
import '../models/kanban_card.dart';
import '../utils/date_formatter.dart';
import '../constants/app_constants.dart';

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

    final cardWidget = Card(
      elevation: isCompleted ? 0 : 2,
      margin: const EdgeInsets.symmetric(horizontal: AppConstants.space8, vertical: AppConstants.space4),
      color: isCompleted ? AppConstants.surfaceColor : AppConstants.backgroundColor,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppConstants.space12),
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.space12),
          child: Opacity(
            opacity: isCompleted ? 0.6 : 1.0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isCompleted)
                      const Padding(
                        padding: EdgeInsets.only(right: AppConstants.space8, top: 2),
                        child: Icon(Icons.check_circle, size: 16, color: AppConstants.successColor),
                      ),
                    Expanded(
                      child: Text(
                        card.title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          decoration: isCompleted ? TextDecoration.lineThrough : null,
                          color: isCompleted ? AppConstants.textSecondary : AppConstants.textPrimary,
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
                      const Icon(
                        Icons.notes_rounded,
                        size: 16,
                        color: AppConstants.textHint,
                      ),
                    if (card.summary != null && card.summary!.isNotEmpty) ...[
                      if (card.description.isNotEmpty) const SizedBox(width: AppConstants.space8),
                      const Icon(
                        Icons.article_outlined,
                        size: 16,
                        color: AppConstants.textHint,
                      ),
                    ],
                    const Spacer(),
                    InkWell(
                      onTap: onSessionTap,
                      borderRadius: BorderRadius.circular(AppConstants.space8),
                      child: _buildSessionBadge(),
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
          borderRadius: BorderRadius.circular(AppConstants.space12),
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
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz, size: 18, color: AppConstants.textHint),
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value == 'complete') onComplete?.call(card);
        if (value == 'uncomplete') onUncomplete?.call(card);
        if (value == 'delete') onDelete?.call(card);
      },
      itemBuilder: (context) => [
        if (card.status == 'active')
          const PopupMenuItem(
            value: 'complete',
            child: Row(
              children: [
                Icon(Icons.check_circle_outline, size: 18, color: AppConstants.successColor),
                SizedBox(width: 8),
                Text('Complete'),
              ],
            ),
          ),
        if (card.status == 'completed')
          const PopupMenuItem(
            value: 'uncomplete',
            child: Row(
              children: [
                Icon(Icons.history, size: 18, color: Colors.orange),
                SizedBox(width: 8),
                Text('Reactivate'),
              ],
            ),
          ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: AppConstants.errorColor),
              SizedBox(width: 8),
              Text('Delete'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSessionBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppConstants.primaryColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chat_bubble_outline_rounded, size: 12, color: AppConstants.primaryColor),
          const SizedBox(width: 4),
          Text(
            '${card.sessionCount}',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: AppConstants.primaryColor,
            ),
          ),
        ],
      ),
    );
  }
}

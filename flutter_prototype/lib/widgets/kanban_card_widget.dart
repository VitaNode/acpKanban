import 'package:flutter/material.dart';
import '../models/kanban_card.dart';
import '../utils/date_formatter.dart';

class KanbanCardWidget extends StatelessWidget {
  final KanbanCard card;
  final VoidCallback onTap;
  final VoidCallback onSessionTap;

  const KanbanCardWidget({
    super.key,
    required this.card,
    required this.onTap,
    required this.onSessionTap,
  });

  @override
  Widget build(BuildContext context) {
    final cardWidget = Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: onTap,
                    borderRadius: BorderRadius.circular(4),
                    child: Text(
                      card.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (card.acpProviderId != null)
                  _buildProviderBadge(card.acpProviderId!),
                InkWell(
                  onTap: onSessionTap,
                  borderRadius: BorderRadius.circular(10),
                  child: _buildSessionBadge(),
                ),
              ],
            ),
            InkWell(
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (card.description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      card.description,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[700],
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        DateFormatter.formatShortDate(card.updatedAt),
                        style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                      ),
                      Icon(Icons.more_horiz, size: 16, color: Colors.grey[400]),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return LongPressDraggable<KanbanCard>(
      data: card,
      feedback: SizedBox(
        width: 260,
        child: Material(
          color: Colors.transparent,
          child: cardWidget,
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: cardWidget,
      ),
      child: cardWidget,
    );
  }

  Widget _buildSessionBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.indigo.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chat_bubble_outline, size: 12, color: Colors.indigo),
          const SizedBox(width: 4),
          Text(
            '${card.sessionCount}',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.indigo,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderBadge(String providerId) {
    IconData icon;
    Color color;
    switch (providerId) {
      case 'gemini':
        icon = Icons.bolt;
        color = Colors.blue;
        break;
      case 'qwen':
        icon = Icons.code;
        color = Colors.orange;
        break;
      case 'openclaw':
        icon = Icons.smart_toy;
        color = Colors.green;
        break;
      default:
        icon = Icons.smart_toy;
        color = Colors.grey;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 14, color: color),
    );
  }
}

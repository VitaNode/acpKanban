import 'package:flutter/material.dart';
import '../models/kanban_card.dart';

class KanbanCardWidget extends StatelessWidget {
  final KanbanCard card;
  final VoidCallback onTap;

  const KanbanCardWidget({
    super.key,
    required this.card,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
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
                  const SizedBox(width: 8),
                  _buildSessionBadge(),
                ],
              ),
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
                    _formatDate(card.updatedAt),
                    style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                  ),
                  Icon(Icons.more_horiz, size: 16, color: Colors.grey[400]),
                ],
              ),
            ],
          ),
        ),
      ),
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

  String _formatDate(String dateStr) {
    final dt = DateTime.tryParse(dateStr);
    if (dt == null) return '';
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

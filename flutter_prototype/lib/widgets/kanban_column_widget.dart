import 'package:flutter/material.dart';
import '../models/kanban_column.dart';
import '../models/kanban_card.dart';
import 'kanban_card_widget.dart';

class KanbanColumnWidget extends StatelessWidget {
  final KanbanColumn column;
  final List<KanbanCard> cards;
  final Function(KanbanCard) onCardTap;
  final VoidCallback onAddCard;
  final Function(KanbanCard, String targetColumnId) onCardMoved;

  const KanbanColumnWidget({
    super.key,
    required this.column,
    required this.cards,
    required this.onCardTap,
    required this.onAddCard,
    required this.onCardMoved,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: _parseColor(column.color).withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _parseColor(column.color).withOpacity(0.1),
          width: 1,
        ),
      ),
      child: DragTarget<KanbanCard>(
        onWillAcceptWithDetails: (details) => details.data.columnId != column.id,
        onAcceptWithDetails: (details) => onCardMoved(details.data, column.id),
        builder: (context, candidateData, rejectedData) {
          final isOver = candidateData.isNotEmpty;
          return Column(
            children: [
              _buildHeader(context, isOver),
              Expanded(
                child: Container(
                  color: isOver ? Colors.indigo.withOpacity(0.05) : Colors.transparent,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: cards.length,
                    itemBuilder: (context, index) {
                      return KanbanCardWidget(
                        card: cards[index],
                        onTap: () => onCardTap(cards[index]),
                      );
                    },
                  ),
                ),
              ),
              _buildFooter(context),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(BuildContext context, [bool isOver = false]) {
    final color = _parseColor(column.color);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: isOver ? BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.indigo.withOpacity(0.2))),
      ) : null,
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              column.name,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${cards.length}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: TextButton.icon(
        onPressed: onAddCard,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add Card'),
        style: TextButton.styleFrom(
          foregroundColor: Colors.grey[700],
          minimumSize: const Size(double.infinity, 40),
          alignment: Alignment.centerLeft,
        ),
      ),
    );
  }

  Color _parseColor(String? colorHex) {
    if (colorHex == null || colorHex.isEmpty) return Colors.grey;
    try {
      final hex = colorHex.replaceAll('#', '');
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      } else if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    } catch (e) {
      debugPrint('Error parsing color: $colorHex');
    }
    return Colors.grey;
  }
}

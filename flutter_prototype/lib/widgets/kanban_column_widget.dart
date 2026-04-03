import 'package:flutter/material.dart';
import '../models/kanban_column.dart';
import '../models/kanban_card.dart';
import 'kanban_card_widget.dart';

class KanbanColumnWidget extends StatefulWidget {
  final KanbanColumn column;
  final List<KanbanCard> cards;
  final Function(KanbanCard) onCardTap;
  final Function(KanbanCard) onCardSessionTap;
  final VoidCallback onAddCard;
  final Function(KanbanCard, String targetColumnId) onCardMoved;
  final Function(KanbanCard)? onCardComplete;
  final Function(KanbanCard)? onCardUncomplete;
  final Function(KanbanCard)? onCardDelete;

  const KanbanColumnWidget({
    super.key,
    required this.column,
    required this.cards,
    required this.onCardTap,
    required this.onCardSessionTap,
    required this.onAddCard,
    required this.onCardMoved,
    this.onCardComplete,
    this.onCardUncomplete,
    this.onCardDelete,
  });

  @override
  State<KanbanColumnWidget> createState() => _KanbanColumnWidgetState();
}

class _KanbanColumnWidgetState extends State<KanbanColumnWidget> {
  bool _showCompleted = false;

  @override
  Widget build(BuildContext context) {
    final activeCards = widget.cards.where((c) => c.status == 'active').toList();
    final completedCards = widget.cards.where((c) => c.status == 'completed').toList();

    debugPrint('Column ${widget.column.name}: total=${widget.cards.length}, active=${activeCards.length}, completed=${completedCards.length}');
    for (var c in widget.cards) {
      debugPrint('  - Card: ${c.title}, status: ${c.status}');
    }

    return Container(
      width: 280,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: _parseColor(widget.column.color).withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _parseColor(widget.column.color).withOpacity(0.1),
          width: 1,
        ),
      ),
      child: DragTarget<KanbanCard>(
        onWillAcceptWithDetails: (details) => details.data.columnId != widget.column.id,
        onAcceptWithDetails: (details) => widget.onCardMoved(details.data, widget.column.id),
        builder: (context, candidateData, rejectedData) {
          final isOver = candidateData.isNotEmpty;
          return Column(
            children: [
              _buildHeader(context, activeCards.length, isOver),
              Expanded(
                child: Container(
                  color: isOver ? Colors.indigo.withOpacity(0.05) : Colors.transparent,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      ...activeCards.map((card) => KanbanCardWidget(
                            key: ValueKey(card.id),
                            card: card,
                            onTap: () => widget.onCardTap(card),
                            onSessionTap: () => widget.onCardSessionTap(card),
                            onComplete: widget.onCardComplete,
                            onUncomplete: widget.onCardUncomplete,
                            onDelete: widget.onCardDelete,
                          )),
                      if (completedCards.isNotEmpty) ...[
                        const Divider(indent: 16, endIndent: 16),
                        _buildCompletedToggleButton(completedCards.length),
                        if (_showCompleted)
                          ...completedCards.map((card) => KanbanCardWidget(
                                key: ValueKey(card.id),
                                card: card,
                                onTap: () => widget.onCardTap(card),
                                onSessionTap: () => widget.onCardSessionTap(card),
                                onComplete: widget.onCardComplete,
                                onUncomplete: widget.onCardUncomplete,
                                onDelete: widget.onCardDelete,
                              )),
                      ],
                    ],
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

  Widget _buildCompletedToggleButton(int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: () => setState(() => _showCompleted = !_showCompleted),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Row(
            children: [
              Icon(
                _showCompleted ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                size: 18,
                color: Colors.grey[600],
              ),
              const SizedBox(width: 4),
              Text(
                'Completed ($count)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int activeCount, [bool isOver = false]) {
    final color = _parseColor(widget.column.color);
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
              widget.column.name,
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
              '$activeCount',
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
        onPressed: widget.onAddCard,
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

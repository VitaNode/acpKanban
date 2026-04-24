import 'package:flutter/material.dart';
import '../models/kanban_column.dart';
import '../models/kanban_card.dart';
import '../constants/app_constants.dart';
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

    return Container(
      width: 300,
      margin: const EdgeInsets.all(AppConstants.space8),
      decoration: BoxDecoration(
        color: AppConstants.surfaceColor,
        borderRadius: BorderRadius.circular(AppConstants.space16),
        border: Border.all(
          color: Colors.grey.shade200,
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
                  decoration: BoxDecoration(
                    color: isOver ? AppConstants.primaryColor.withOpacity(0.05) : Colors.transparent,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(AppConstants.space16)),
                  ),
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: AppConstants.space8, vertical: AppConstants.space4),
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
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: AppConstants.space8),
                          child: Divider(color: Colors.grey.shade300, thickness: 0.5),
                        ),
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
      padding: const EdgeInsets.symmetric(horizontal: AppConstants.space8, vertical: AppConstants.space4),
      child: InkWell(
        onTap: () => setState(() => _showCompleted = !_showCompleted),
        borderRadius: BorderRadius.circular(AppConstants.space8),
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.space8),
          child: Row(
            children: [
              Icon(
                _showCompleted ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                size: 18,
                color: AppConstants.textSecondary,
              ),
              const SizedBox(width: AppConstants.space4),
              Text(
                'COMPLETED ($count)',
                style: Theme.of(context).textTheme.labelLarge,
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
      padding: const EdgeInsets.all(AppConstants.space16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isOver ? AppConstants.primaryColor : Colors.grey.shade200,
            width: isOver ? 2 : 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppConstants.space12),
          Expanded(
            child: Text(
              widget.column.name.toUpperCase(),
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontSize: 14,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppConstants.space8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(AppConstants.space12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.column.acpProviderId != null) ...[
                  _buildProviderBadge(widget.column.acpProviderId!),
                  const SizedBox(width: 4),
                ],
                Text(
                  '$activeCount',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
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
        color = AppConstants.primaryColor;
        break;
      default:
        icon = Icons.auto_awesome;
        color = Colors.grey;
    }
    return Icon(icon, size: 14, color: color);
  }

  Widget _buildFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppConstants.space8),
      child: InkWell(
        onTap: widget.onAddCard,
        borderRadius: BorderRadius.circular(AppConstants.space8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppConstants.space8, horizontal: AppConstants.space12),
          child: const Row(
            children: [
              Icon(Icons.add_rounded, size: 20, color: AppConstants.primaryColor),
              SizedBox(width: AppConstants.space8),
              Text(
                'Add Card',
                style: TextStyle(
                  color: AppConstants.primaryColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
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

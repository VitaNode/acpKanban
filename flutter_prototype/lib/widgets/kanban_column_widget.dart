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
  final Function(KanbanCard, String targetColumnId, {int? targetPosition}) onCardMoved;
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final activeCards = widget.cards.where((c) => c.status == 'active').toList();
    final completedCards = widget.cards.where((c) => c.status == 'completed').toList();

    return Container(
      width: 300,
      margin: const EdgeInsets.all(AppConstants.space8),
      decoration: BoxDecoration(
        // 使用 surfaceContainer 区分页面背景
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
      ),
      child: Column(
        children: [
          _buildHeader(context, activeCards.length),
          Expanded(
            child: ListView.builder(
              key: PageStorageKey('column_list_${widget.column.id}'),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppConstants.space8, vertical: AppConstants.space4),
              itemCount: activeCards.length * 2 + 1 + (completedCards.isNotEmpty ? 2 : 0),
              itemBuilder: (context, index) {
                if (index < activeCards.length * 2 + 1) {
                  if (index % 2 == 0) {
                    final targetPos = index ~/ 2;
                    return _buildDropTarget(context, targetPos);
                  } else {
                    final cardIndex = index ~/ 2;
                    final card = activeCards[cardIndex];
                    return KanbanCardWidget(
                      key: ValueKey(card.id),
                      card: card,
                      onTap: () => widget.onCardTap(card),
                      onSessionTap: () => widget.onCardSessionTap(card),
                      onComplete: widget.onCardComplete,
                      onUncomplete: widget.onCardUncomplete,
                      onDelete: widget.onCardDelete,
                    );
                  }
                }
                
                if (completedCards.isNotEmpty) {
                  final completedIndex = index - (activeCards.length * 2 + 1);
                  if (completedIndex == 0) {
                    return Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: AppConstants.space8),
                          child: SizedBox(height: 1),
                        ),
                        _buildCompletedToggleButton(completedCards.length),
                      ],
                    );
                  } else if (completedIndex == 1 && _showCompleted) {
                    return Column(
                      children: completedCards
                          .map((card) => KanbanCardWidget(
                                key: ValueKey(card.id),
                                card: card,
                                onTap: () => widget.onCardTap(card),
                                onSessionTap: () => widget.onCardSessionTap(card),
                                onComplete: widget.onCardComplete,
                                onUncomplete: widget.onCardUncomplete,
                                onDelete: widget.onCardDelete,
                              ))
                          .toList(),
                    );
                  }
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropTarget(BuildContext context, int position) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeCards = widget.cards.where((c) => c.status == 'active').toList();
    
    return DragTarget<KanbanCard>(
      onWillAcceptWithDetails: (details) {
        final card = details.data;
        if (card.columnId == widget.column.id) {
          // If it's the same column, we hide targets immediately above and below the card
          final cardIndexInActive = activeCards.indexWhere((c) => c.id == card.id);
          if (cardIndexInActive != -1) {
            if (position == cardIndexInActive || position == cardIndexInActive + 1) {
              return false;
            }
          }
        }
        return true;
      },
      onAcceptWithDetails: (details) {
        int? actualTargetPosition;
        if (position < activeCards.length) {
          // Drop before card at index 'position'
          actualTargetPosition = activeCards[position].position;
        } else if (activeCards.isNotEmpty) {
          // Drop after last card
          actualTargetPosition = activeCards.last.position + 1;
        }
        
        widget.onCardMoved(details.data, widget.column.id,
            targetPosition: actualTargetPosition);
      },
      builder: (context, candidateData, rejectedData) {
        final isOver = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: isOver ? 40 : 8,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: isOver
                ? colorScheme.primary.withOpacity(0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
            border: isOver
                ? Border.all(color: colorScheme.primary, width: 1)
                : null,
          ),
          child: isOver
              ? Center(
                  child: Icon(Icons.add_circle_outline,
                      color: colorScheme.primary, size: 20))
              : null,
        );
      },
    );
  }

  Widget _buildCompletedToggleButton(int count) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppConstants.space8, vertical: AppConstants.space4),
      child: InkWell(
        onTap: () => setState(() => _showCompleted = !_showCompleted),
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.space8),
          child: Row(
            children: [
              Icon(
                _showCompleted ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                size: 18,
                color: theme.textTheme.bodySmall?.color,
              ),
              const SizedBox(width: AppConstants.space4),
              Text(
                'COMPLETED ($count)',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int activeCount) {
    final theme = Theme.of(context);
    final color = _parseColor(widget.column.color);
    final colorScheme = theme.colorScheme;
    
    return Container(
      padding: const EdgeInsets.fromLTRB(AppConstants.space16, AppConstants.space8, AppConstants.space8, AppConstants.space8),
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
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    widget.column.name.toUpperCase(),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontSize: 14,
                      letterSpacing: 1.2,
                      overflow: TextOverflow.ellipsis,
                      color: colorScheme.onSurface.withOpacity(AppConstants.highEmphasis),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(AppConstants.radiusFull),
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
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: widget.onAddCard,
            icon: Icon(Icons.add_rounded, size: 20, color: colorScheme.primary),
            visualDensity: VisualDensity.compact,
            tooltip: 'Add Card',
          ),
        ],
      ),
    );
  }

  Widget _buildProviderBadge(String providerId) {
    IconData icon;
    Color color;
    final theme = Theme.of(context);
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
        color = theme.colorScheme.primary;
        break;
      default:
        icon = Icons.auto_awesome;
        color = Colors.grey;
    }
    return Icon(icon, size: 14, color: color);
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

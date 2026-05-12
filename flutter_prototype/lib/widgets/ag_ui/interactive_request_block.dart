import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../models/ag_ui_event.dart';
import '../../constants/app_constants.dart';

class InteractiveRequestBlock extends StatelessWidget {
  final AgUiEvent event;
  final Function(String optionId) onOptionSelected;
  final bool isResponded;
  final MarkdownStyleSheet? styleSheet;

  const InteractiveRequestBlock({
    super.key,
    required this.event,
    required this.onOptionSelected,
    this.isResponded = false,
    this.styleSheet,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Icon(
                  _getIconForMethod(event.method), 
                  size: 18, 
                  color: colorScheme.primary
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    event.title ?? 'Action Required',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                if (isResponded)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'RESPONDED',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          
          // Body
          if ((event.text != null && event.text!.isNotEmpty) || (event.title != null && event.title!.isNotEmpty))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: MarkdownBody(
                data: (event.text != null && event.text!.isNotEmpty) ? event.text! : event.title!,
                selectable: true,
                styleSheet: styleSheet ?? MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: theme.textTheme.bodyMedium?.copyWith(height: 1.5, fontSize: 13),
                  code: TextStyle(
                    backgroundColor: colorScheme.surfaceContainer,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            
          // Buttons
          if (!isResponded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: (event.options ?? []).map((opt) {
                  final optionId = opt['id']?.toString() ?? '';
                  final label = opt['label']?.toString() ?? 'Option';
                  final isPrimary = opt['primary'] == true;
                  
                  if (isPrimary) {
                    return FilledButton.tonal(
                      onPressed: () => onOptionSelected(optionId),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                        minimumSize: const Size(0, 32),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(label),
                    );
                  } else {
                    return OutlinedButton(
                      onPressed: () => onOptionSelected(optionId),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                        minimumSize: const Size(0, 32),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(label),
                    );
                  }
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  IconData _getIconForMethod(String? method) {
    if (method == null) return Icons.security_rounded;
    if (method.startsWith('fs/')) return Icons.file_present_rounded;
    if (method.startsWith('terminal/')) return Icons.terminal_rounded;
    if (method.contains('question')) return Icons.help_outline_rounded;
    return Icons.security_rounded;
  }
}

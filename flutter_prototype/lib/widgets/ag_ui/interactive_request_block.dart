import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../models/ag_ui_event.dart';
import '../../constants/app_constants.dart';
import '../../theme/markdown_theme.dart';
import '../message_shell.dart';

class InteractiveRequestBlock extends StatelessWidget {
  final AgUiEvent event;
  final Function(String optionId) onOptionSelected;
  final bool isResponded;

  const InteractiveRequestBlock({
    super.key,
    required this.event,
    required this.onOptionSelected,
    this.isResponded = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return MessageShell(
      headerLeading: Icon(_getIconForMethod(event.method),
          size: 16, color: colorScheme.primary),
      title: event.title ?? 'Action Required',
      headerTrailing: isResponded
          ? Container(
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
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Body
          if ((event.text != null && event.text!.isNotEmpty) ||
              (event.title != null && event.title!.isNotEmpty))
            MarkdownBody(
              data: (event.text != null && event.text!.isNotEmpty)
                  ? event.text!
                  : event.title!,
              selectable: false, // Managed by high-level SelectionArea
              styleSheet: MarkdownTheme.getStyle(context),
            ),

          // Buttons
          if (!isResponded) ...[
            const SizedBox(height: AppConstants.space12),
            Wrap(
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 0),
                      minimumSize: const Size(0, 32),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(label),
                  );
                } else {
                  return OutlinedButton(
                    onPressed: () => onOptionSelected(optionId),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 0),
                      minimumSize: const Size(0, 32),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(label),
                  );
                }
              }).toList(),
            ),
          ],
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

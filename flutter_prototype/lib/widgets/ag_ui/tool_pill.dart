import 'package:flutter/material.dart';

class ToolPill extends StatelessWidget {
  final String name;
  final String status;

  const ToolPill({
    Key? key,
    required this.name,
    required this.status,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Determine colors and icon based on status
    Color backgroundColor;
    Color foregroundColor;
    IconData icon;
    String label;

    switch (status) {
      case 'running':
        backgroundColor = Theme.of(context).colorScheme.primary.withOpacity(0.1);
        foregroundColor = Theme.of(context).colorScheme.primary;
        icon = Icons.refresh;
        label = '$name...';
        break;
      case 'success':
        backgroundColor = Theme.of(context).colorScheme.secondary.withOpacity(0.1);
        foregroundColor = Theme.of(context).colorScheme.secondary;
        icon = Icons.check_circle;
        label = '$name ✓';
        break;
      case 'failed':
        backgroundColor = Theme.of(context).colorScheme.error.withOpacity(0.1);
        foregroundColor = Theme.of(context).colorScheme.error;
        icon = Icons.error;
        label = '$name ✗';
        break;
      default:
        backgroundColor = Theme.of(context).colorScheme.surfaceVariant;
        foregroundColor = Theme.of(context).colorScheme.onSurfaceVariant;
        icon = Icons.help_outline;
        label = name;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: foregroundColor.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foregroundColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: foregroundColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
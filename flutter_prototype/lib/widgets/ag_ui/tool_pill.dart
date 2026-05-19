import 'package:flutter/material.dart';

class ToolPill extends StatelessWidget {
  final String name;
  final String status;
  final IconData? icon;
  final String? subtitle;

  const ToolPill({
    Key? key,
    required this.name,
    required this.status,
    this.icon,
    this.subtitle,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    Color backgroundColor;
    Color foregroundColor;
    IconData statusIcon;
    String label;

    switch (status) {
      case 'running':
        backgroundColor =
            Theme.of(context).colorScheme.primary.withOpacity(0.1);
        foregroundColor = Theme.of(context).colorScheme.primary;
        statusIcon = Icons.refresh;
        label = '$name...';
        break;
      case 'success':
        backgroundColor =
            Theme.of(context).colorScheme.secondary.withOpacity(0.1);
        foregroundColor = Theme.of(context).colorScheme.secondary;
        statusIcon = Icons.check_circle;
        label = '$name ✓';
        break;
      case 'failed':
        backgroundColor = Theme.of(context).colorScheme.error.withOpacity(0.1);
        foregroundColor = Theme.of(context).colorScheme.error;
        statusIcon = Icons.error;
        label = '$name ✗';
        break;
      default:
        backgroundColor = Theme.of(context).colorScheme.surfaceVariant;
        foregroundColor = Theme.of(context).colorScheme.onSurfaceVariant;
        statusIcon = Icons.help_outline;
        label = name;
        break;
    }

    final displayIcon = icon ?? statusIcon;

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
          Icon(displayIcon, size: 16, color: foregroundColor),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: foregroundColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: foregroundColor.withOpacity(0.7),
                      fontSize: 10,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

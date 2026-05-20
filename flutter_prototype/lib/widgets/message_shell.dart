import 'package:flutter/material.dart';
import '../constants/app_constants.dart';

class MessageShell extends StatelessWidget {
  final Widget child;
  final Widget? headerLeading;
  final String? title;
  final Widget? headerTrailing;
  final bool isUser;
  final bool isExpandable;
  final bool isExpanded;
  final VoidCallback? onToggleExpand;
  final EdgeInsets? padding;
  final EdgeInsets? headerPadding;

  const MessageShell({
    super.key,
    required this.child,
    this.headerLeading,
    this.title,
    this.headerTrailing,
    this.isUser = false,
    this.isExpandable = false,
    this.isExpanded = true,
    this.onToggleExpand,
    this.padding,
    this.headerPadding,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final backgroundColor = isUser
        ? (isDark
            ? colorScheme.primaryContainer.withOpacity(0.2)
            : colorScheme.primary.withOpacity(0.06))
        : (isDark
            ? colorScheme.surfaceContainerHighest.withOpacity(0.3)
            : colorScheme.surfaceContainer.withOpacity(0.5));

    final borderColor = isUser
        ? (isDark
            ? colorScheme.primary.withOpacity(0.2)
            : colorScheme.primary.withOpacity(0.1))
        : colorScheme.outlineVariant.withOpacity(0.4);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null || headerLeading != null || isExpandable)
            InkWell(
              onTap: isExpandable ? onToggleExpand : null,
              borderRadius: BorderRadius.vertical(
                top: const Radius.circular(AppConstants.radiusMedium),
                bottom: Radius.circular((isExpandable && !isExpanded)
                    ? AppConstants.radiusMedium
                    : 0),
              ),
              child: Padding(
                padding: headerPadding ?? const EdgeInsets.symmetric(
                  horizontal: AppConstants.space12,
                  vertical: AppConstants.space8,
                ),
                child: Row(
                  children: [
                    if (headerLeading != null) ...[
                      headerLeading!,
                      const SizedBox(width: 8),
                    ],
                    if (title != null)
                      Expanded(
                        child: Text(
                          title!,
                          softWrap: true,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: isUser
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurfaceVariant,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    if (headerTrailing != null) headerTrailing!,
                    if (isExpandable)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Icon(
                          isExpanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: colorScheme.onSurfaceVariant.withOpacity(0.5),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (isExpanded)
            Padding(
              padding: padding ?? const EdgeInsets.all(AppConstants.space12),
              child: child,
            ),
        ],
      ),
    );
  }
}

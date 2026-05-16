import 'package:flutter/material.dart';
import '../constants/ui_copy.dart';

class AppStateView extends StatelessWidget {
  final String? title;
  final String? message;
  final IconData? icon;
  final VoidCallback? onRetry;
  final bool isLoading;
  final Widget? action;

  const AppStateView({
    super.key,
    this.title,
    this.message,
    this.icon,
    this.onRetry,
    this.isLoading = false,
    this.action,
  });

  factory AppStateView.loading({String? message}) {
    return AppStateView(
      isLoading: true,
      message: message ?? UICopy.loading,
    );
  }

  factory AppStateView.error({
    String? title,
    required String message,
    VoidCallback? onRetry,
  }) {
    return AppStateView(
      icon: Icons.error_outline,
      title: title ?? 'Error',
      message: message,
      onRetry: onRetry,
    );
  }

  factory AppStateView.empty({
    String? title,
    required String message,
    IconData icon = Icons.inbox_outlined,
    Widget? action,
  }) {
    return AppStateView(
      icon: icon,
      title: title ?? 'Empty',
      message: message,
      action: action,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    if (isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (message != null) ...[
              const SizedBox(height: 16),
              Text(message!, style: theme.textTheme.bodyMedium),
            ],
          ],
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(icon, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            if (title != null)
              Text(title!, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 24),
            if (onRetry != null)
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text(UICopy.retry),
              )
            else if (action != null)
              action!,
          ],
        ),
      ),
    );
  }
}

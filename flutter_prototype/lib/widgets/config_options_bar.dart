import 'package:flutter/material.dart';
import '../models/config_option.dart';
import '../services/session_websocket_service.dart';
import '../constants/app_constants.dart';

class ConfigOptionsBar extends StatelessWidget {
  final List<ConfigOption> options;

  const ConfigOptionsBar({super.key, required this.options});

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: theme.dividerTheme.color!)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16),
        itemCount: options.length,
        separatorBuilder: (context, index) => const SizedBox(width: AppConstants.space8),
        itemBuilder: (context, index) {
          final option = options[index];
          return _buildOptionChip(context, option);
        },
      ),
    );
  }

  Widget _buildOptionChip(BuildContext context, ConfigOption option) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final currentValue = option.options.firstWhere(
      (o) => o.value == option.currentValue,
      orElse: () => ConfigOptionValue(value: option.currentValue, name: option.currentValue),
    );

    return Center(
      child: InkWell(
        onTap: () => _showOptionPicker(context, option),
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppConstants.space12, vertical: AppConstants.space6),
          decoration: BoxDecoration(
            color: theme.cardTheme.color,
            borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
            border: Border.all(color: theme.dividerTheme.color!),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_getIconForOption(option.category), size: 14, color: colorScheme.primary),
              const SizedBox(width: AppConstants.space8),
              Text(
                currentValue.name,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface.withOpacity(AppConstants.highEmphasis),
                ),
              ),
              const SizedBox(width: AppConstants.space4),
              Icon(Icons.keyboard_arrow_down_rounded, 
                  size: 16, 
                  color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis)),
            ],
          ),
        ),
      ),
    );
  }

  void _showOptionPicker(BuildContext context) {
    // This seems to be a mistake in original code, _showOptionPicker takes two args
  }

  void _showOptionPickerInternal(BuildContext context, ConfigOption option) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isModeCategory = option.category == 'mode';

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppConstants.radiusMedium)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppConstants.space16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(_getIconForOption(option.category),
                            size: 20, color: colorScheme.primary),
                        const SizedBox(width: AppConstants.space8),
                        Text(
                          option.name,
                          style: theme.textTheme.headlineMedium,
                        ),
                      ],
                    ),
                    if (option.description != null) ...[
                      const SizedBox(height: AppConstants.space4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          option.description!,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: option.options.length,
                  itemBuilder: (context, index) {
                    final val = option.options[index];
                    final isSelected = val.value == option.currentValue;
                    return ListTile(
                      leading: isModeCategory
                          ? Icon(_getModeIcon(val.value),
                              color: isSelected
                                  ? colorScheme.primary
                                  : colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis))
                          : null,
                      title: Text(val.name,
                          style: TextStyle(
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                          )),
                      subtitle: val.description != null
                          ? Text(val.description!,
                              style: theme.textTheme.bodySmall)
                          : null,
                      trailing: isSelected
                          ? Icon(Icons.check_rounded, color: colorScheme.primary)
                          : null,
                      onTap: () {
                        SessionWebSocketService()
                            .setConfigOption(option.id, val.value);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showOptionPicker(BuildContext context, ConfigOption option) {
    _showOptionPickerInternal(context, option);
  }

  IconData _getIconForOption(String category) {
    switch (category) {
      case 'mode':
        return Icons.security_rounded;
      case 'model':
        return Icons.smart_toy_rounded;
      case 'thought_level':
        return Icons.psychology_rounded;
      default:
        return Icons.settings_rounded;
    }
  }

  IconData _getModeIcon(String mode) {
    final m = mode.toLowerCase();
    if (m.contains('ask') || m.contains('autoedit')) return Icons.question_answer_rounded;
    if (m.contains('code') || m.contains('yolo')) return Icons.code_rounded;
    if (m.contains('plan') || m.contains('architect')) return Icons.architecture_rounded;
    return Icons.security_rounded;
  }
}

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

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: AppConstants.backgroundColor,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
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
    final currentValue = option.options.firstWhere(
      (o) => o.value == option.currentValue,
      orElse: () => ConfigOptionValue(value: option.currentValue, name: option.currentValue),
    );

    return Center(
      child: InkWell(
        onTap: () => _showOptionPicker(context, option),
        borderRadius: BorderRadius.circular(AppConstants.space8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppConstants.space12, vertical: AppConstants.space6),
          decoration: BoxDecoration(
            color: AppConstants.surfaceColor,
            borderRadius: BorderRadius.circular(AppConstants.space8),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_getIconForOption(option.category), size: 14, color: AppConstants.primaryColor),
              const SizedBox(width: AppConstants.space8),
              Text(
                currentValue.name,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppConstants.textPrimary,
                ),
              ),
              const SizedBox(width: AppConstants.space4),
              const Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: AppConstants.textHint),
            ],
          ),
        ),
      ),
    );
  }

  void _showOptionPicker(BuildContext context, ConfigOption option) {
    final isModeCategory = option.category == 'mode';

    showModalBottomSheet(
      context: context,
      backgroundColor: AppConstants.backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
                            size: 20, color: AppConstants.primaryColor),
                        const SizedBox(width: AppConstants.space8),
                        Text(
                          option.name,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ],
                    ),
                    if (option.description != null) ...[
                      const SizedBox(height: AppConstants.space4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          option.description!,
                          style: Theme.of(context).textTheme.bodySmall,
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
                                  ? AppConstants.primaryColor
                                  : AppConstants.textHint)
                          : null,
                      title: Text(val.name,
                          style: TextStyle(
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? AppConstants.primaryColor : AppConstants.textPrimary,
                          )),
                      subtitle: val.description != null
                          ? Text(val.description!,
                              style: Theme.of(context).textTheme.bodySmall)
                          : null,
                      trailing: isSelected
                          ? const Icon(Icons.check_rounded, color: AppConstants.primaryColor)
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

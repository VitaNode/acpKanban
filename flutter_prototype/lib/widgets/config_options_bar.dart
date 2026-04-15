import 'package:flutter/material.dart';
import '../models/config_option.dart';
import '../services/session_websocket_service.dart';

class ConfigOptionsBar extends StatelessWidget {
  final List<ConfigOption> options;

  const ConfigOptionsBar({super.key, required this.options});

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        itemCount: options.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8.0),
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

    return InkWell(
      onTap: () => _showOptionPicker(context, option),
      borderRadius: BorderRadius.circular(8.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_getIconForOption(option.category), size: 16, color: const Color(0xFF008080)),
            const SizedBox(width: 8.0),
            Text(
              currentValue.name,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF424242),
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 20, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  void _showOptionPicker(BuildContext context, ConfigOption option) {
    final isModeCategory = option.category == 'mode';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(_getIconForOption(option.category),
                            size: 20, color: const Color(0xFF008080)),
                        const SizedBox(width: 8),
                        Text(
                          option.name,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    if (option.description != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        option.description!,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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
                                  ? const Color(0xFF008080)
                                  : Colors.grey)
                          : null,
                      title: Text(val.name,
                          style: TextStyle(
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? const Color(0xFF008080) : null,
                          )),
                      subtitle: val.description != null
                          ? Text(val.description!,
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey[600]))
                          : null,
                      trailing: isSelected
                          ? const Icon(Icons.check, color: Color(0xFF008080))
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
        return Icons.security;
      case 'model':
        return Icons.smart_toy;
      case 'thought_level':
        return Icons.psychology;
      default:
        return Icons.settings;
    }
  }

  IconData _getModeIcon(String mode) {
    final m = mode.toLowerCase();
    if (m.contains('ask') || m.contains('autoedit')) return Icons.question_answer;
    if (m.contains('code') || m.contains('yolo')) return Icons.code;
    if (m.contains('plan') || m.contains('architect')) return Icons.architecture;
    return Icons.security;
  }
}

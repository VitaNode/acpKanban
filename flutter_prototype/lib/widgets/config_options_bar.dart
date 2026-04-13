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
    final selectedValue = option.options.firstWhere(
      (v) => v.value == option.value,
      orElse: () => option.options.first,
    );

    return InkWell(
      onTap: () => _showOptionPicker(context, option),
      borderRadius: BorderRadius.circular(8.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_getIconForOption(option.name), size: 16, color: const Color(0xFF008080)),
            const SizedBox(width: 8.0),
            Text(
              selectedValue.label,
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
                child: Text(
                  '选择 ${option.label}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: option.options.length,
                  itemBuilder: (context, index) {
                    final val = option.options[index];
                    final isSelected = val.value == option.value;
                    return ListTile(
                      title: Text(val.label, style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? const Color(0xFF008080) : null,
                      )),
                      subtitle: val.description != null ? Text(val.description!) : null,
                      trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF008080)) : null,
                      onTap: () {
                        SessionWebSocketService().setConfigOption(option.name, val.value);
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

  IconData _getIconForOption(String name) {
    if (name.contains('model')) return Icons.smart_toy;
    if (name.contains('mode')) return Icons.security;
    if (name.contains('thought')) return Icons.psychology;
    return Icons.settings;
  }
}

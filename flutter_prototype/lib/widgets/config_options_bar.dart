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
    return InkWell(
      onTap: () => _showOptionPicker(context, option),
      borderRadius: BorderRadius.circular(8.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_getIconForOption(option.id), size: 16, color: const Color(0xFF008080)),
            const SizedBox(width: 8.0),
            Text(
              option.currentValue,
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
                  '选择 ${option.name}',
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
                    final isSelected = val == option.currentValue;
                    return ListTile(
                      title: Text(val, style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? const Color(0xFF008080) : null,
                      )),
                      trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF008080)) : null,
                      onTap: () {
                        SessionWebSocketService().setConfigOption(option.id, val);
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

  IconData _getIconForOption(String id) {
    if (id.contains('model')) return Icons.smart_toy;
    if (id.contains('mode')) return Icons.security;
    if (id.contains('thought')) return Icons.psychology;
    return Icons.settings;
  }
}

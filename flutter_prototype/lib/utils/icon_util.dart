import 'package:flutter/material.dart';

class IconUtil {
  static IconData getProviderIcon(String? icon) {
    if (icon == null) return Icons.smart_toy;

    final iconMap = {
      'bolt': Icons.bolt,
      'code': Icons.code,
      'smart_toy': Icons.smart_toy,
      'search': Icons.search,
      'settings': Icons.settings,
      'build': Icons.build,
      'terminal': Icons.terminal,
      'extension': Icons.extension,
      'auto_awesome': Icons.auto_awesome,
      'psychology': Icons.psychology,
      'rocket_launch': Icons.rocket_launch,
      'memory': Icons.memory,
      'hub': Icons.hub,
      'api': Icons.api,
      'cloud': Icons.cloud,
      'devices': Icons.devices,
    };
    return iconMap[icon.toLowerCase()] ?? Icons.smart_toy;
  }
}

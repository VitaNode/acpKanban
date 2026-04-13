class ConfigOption {
  final String id;
  final String name;
  final String category;
  final String currentValue;
  final List<String> options;

  ConfigOption({
    required this.id,
    required this.name,
    required this.category,
    required this.currentValue,
    required this.options,
  });

  factory ConfigOption.fromJson(Map<String, dynamic> json) {
    return ConfigOption(
      id: json['id'] ?? json['name'] ?? '',
      name: json['name'] ?? json['label'] ?? '',
      category: json['category'] ?? 'general',
      currentValue: (json['currentValue'] ?? json['value'] ?? '').toString(),
      options: List<String>.from(json['options'] ?? []),
    );
  }
}

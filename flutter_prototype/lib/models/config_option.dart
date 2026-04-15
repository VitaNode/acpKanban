class ConfigOption {
  final String id;
  final String name;
  final String? description;
  final String category;
  final String type;
  final String currentValue;
  final List<ConfigOptionValue> options;

  ConfigOption({
    required this.id,
    required this.name,
    this.description,
    required this.category,
    required this.type,
    required this.currentValue,
    required this.options,
  });

  factory ConfigOption.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'] as List? ?? [];
    final parsedOptions = rawOptions
        .map((o) {
          if (o is String) {
            return ConfigOptionValue(value: o, name: o);
          }
          if (o is Map) {
            return ConfigOptionValue.fromJson(Map<String, dynamic>.from(o));
          }
          return null;
        })
        .whereType<ConfigOptionValue>()
        .toList();

    return ConfigOption(
      id: json['id'] ?? json['name'] ?? '',
      name: json['name'] ?? json['label'] ?? '',
      description: json['description'],
      category: json['category'] ?? 'general',
      type: json['type'] ?? 'select',
      currentValue: (json['currentValue'] ?? json['value'] ?? '').toString(),
      options: parsedOptions,
    );
  }
}

class ConfigOptionValue {
  final String value;
  final String name;
  final String? description;

  ConfigOptionValue({
    required this.value,
    required this.name,
    this.description,
  });

  factory ConfigOptionValue.fromJson(Map<String, dynamic> json) {
    return ConfigOptionValue(
      value: json['value'] ?? '',
      name: json['name'] ?? json['value'] ?? '',
      description: json['description'],
    );
  }
}

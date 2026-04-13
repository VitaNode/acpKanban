class ConfigOptionValue {
  final String label;
  final String value;
  final String? description;

  ConfigOptionValue({required this.label, required this.value, this.description});

  factory ConfigOptionValue.fromJson(Map<String, dynamic> json) {
    return ConfigOptionValue(
      label: json['label'] ?? '',
      value: json['value'] ?? '',
      description: json['description'],
    );
  }
}

class ConfigOption {
  final String name;
  final String label;
  final String? value;
  final String type; // e.g. "choice"
  final List<ConfigOptionValue> options;

  ConfigOption({
    required this.name,
    required this.label,
    this.value,
    required this.type,
    this.options = const [],
  });

  factory ConfigOption.fromJson(Map<String, dynamic> json) {
    return ConfigOption(
      name: json['name'] ?? '',
      label: json['label'] ?? '',
      value: json['value'],
      type: json['type'] ?? 'choice',
      options: (json['options'] as List?)
              ?.map((e) => ConfigOptionValue.fromJson(e as Map<String, dynamic>))
              .toList() ?? [],
    );
  }

  ConfigOption copyWith({String? value}) {
    return ConfigOption(
      name: name,
      label: label,
      value: value ?? this.value,
      type: type,
      options: options,
    );
  }
}

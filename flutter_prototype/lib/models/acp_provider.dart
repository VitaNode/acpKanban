class ACPProvider {
  final String id;
  final String name;
  final String? description;
  final String? icon;

  ACPProvider({
    required this.id,
    required this.name,
    this.description,
    this.icon,
  });

  factory ACPProvider.fromJson(Map<String, dynamic> json) {
    return ACPProvider(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      description: json['description'],
      icon: json['icon'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'icon': icon,
    };
  }
}

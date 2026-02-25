/// Album model for organizing vault items
class Album {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<String> itemIds; // IDs of vault items in this album
  
  Album({
    required this.id,
    required this.name,
    required this.createdAt,
    List<String>? itemIds,
  }) : itemIds = itemIds ?? [];
  
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'itemIds': itemIds,
    };
  }
  
  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      itemIds: (json['itemIds'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
    );
  }
  
  Album copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    List<String>? itemIds,
  }) {
    return Album(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      itemIds: itemIds ?? this.itemIds,
    );
  }
}

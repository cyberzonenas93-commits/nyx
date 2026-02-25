/// Metadata for a vault instance
/// PIN hash and salt are stored in secure storage (not in this metadata)
class VaultMetadata {
  final String id;
  final String name;
  final String triggerCode;
  final DateTime createdAt;
  final bool isPrimary;
  
  VaultMetadata({
    required this.id,
    required this.name,
    required this.triggerCode,
    required this.createdAt,
    this.isPrimary = false,
  });
  
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'triggerCode': triggerCode,
      'createdAt': createdAt.toIso8601String(),
      'isPrimary': isPrimary,
    };
  }
  
  factory VaultMetadata.fromJson(Map<String, dynamic> json) {
    return VaultMetadata(
      id: json['id'] as String,
      name: json['name'] as String,
      triggerCode: json['triggerCode'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      isPrimary: json['isPrimary'] as bool? ?? false,
    );
  }
  
  VaultMetadata copyWith({
    String? id,
    String? name,
    String? triggerCode,
    DateTime? createdAt,
    bool? isPrimary,
  }) {
    return VaultMetadata(
      id: id ?? this.id,
      name: name ?? this.name,
      triggerCode: triggerCode ?? this.triggerCode,
      createdAt: createdAt ?? this.createdAt,
      isPrimary: isPrimary ?? this.isPrimary,
    );
  }
}

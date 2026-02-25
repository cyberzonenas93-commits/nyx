/// Folder model for organizing vault items
class VaultFolder {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime? dateModified;
  final String? parentFolderId; // For nested folders (future)
  final List<String> itemIds; // IDs of vault items in this folder
  final List<String> subFolderIds; // IDs of subfolders (future)
  
  VaultFolder({
    required this.id,
    required this.name,
    required this.createdAt,
    this.dateModified,
    this.parentFolderId,
    List<String>? itemIds,
    List<String>? subFolderIds,
  }) : itemIds = itemIds ?? [],
       subFolderIds = subFolderIds ?? [];
  
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'dateModified': dateModified?.toIso8601String(),
      'parentFolderId': parentFolderId,
      'itemIds': itemIds,
      'subFolderIds': subFolderIds,
    };
  }
  
  factory VaultFolder.fromJson(Map<String, dynamic> json) {
    return VaultFolder(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      dateModified: json['dateModified'] != null 
          ? DateTime.parse(json['dateModified'] as String) 
          : null,
      parentFolderId: json['parentFolderId'] as String?,
      itemIds: (json['itemIds'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
      subFolderIds: (json['subFolderIds'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
    );
  }
  
  VaultFolder copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    DateTime? dateModified,
    String? parentFolderId,
    List<String>? itemIds,
    List<String>? subFolderIds,
  }) {
    return VaultFolder(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      dateModified: dateModified ?? this.dateModified,
      parentFolderId: parentFolderId ?? this.parentFolderId,
      itemIds: itemIds ?? this.itemIds,
      subFolderIds: subFolderIds ?? this.subFolderIds,
    );
  }
}

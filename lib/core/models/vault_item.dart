/// Vault item model - represents any file stored in the vault
/// Supports all file types including unknown binaries
class VaultItem {
  final String id; // Cryptographically random ID (never filename-based)
  final String originalFilename; // Original filename if known
  final String? customName; // User-renamed filename
  final VaultItemType type;
  final String? mimeType; // MIME type if detected (optional)
  final int sizeBytes; // File size in bytes
  final DateTime dateAdded;
  final DateTime? dateModified;
  final VaultItemSource source; // Where the item came from
  final String? sourceUrl; // Original URL if from browser/download
  final String? sourceSite; // Site name (e.g., "YouTube", "example.com")
  final String? thumbnailId; // ID of thumbnail if available (deprecated - use thumbnailPath)
  final String? thumbnailPath; // Relative path to thumbnail file (e.g., "thumbnails/{id}_thumb.jpg")
  final String? vaultRelativePath; // Relative path to vault file (e.g., "{id}" or "{id}.ext")
  final Map<String, dynamic>? metadata; // Additional metadata (duration, dimensions, etc.)
  final bool isEncrypted; // Whether file is encrypted (future-ready)
  
  VaultItem({
    required this.id,
    required this.originalFilename,
    this.customName,
    required this.type,
    this.mimeType,
    required this.sizeBytes,
    required this.dateAdded,
    this.dateModified,
    required this.source,
    this.sourceUrl,
    this.sourceSite,
    this.thumbnailId,
    this.thumbnailPath,
    this.vaultRelativePath,
    this.metadata,
    this.isEncrypted = false,
  });
  
  /// Get thumbnail path (prefers thumbnailPath, falls back to thumbnailId for backward compatibility)
  String? get effectiveThumbnailPath => thumbnailPath ?? (thumbnailId != null ? 'thumbnails/$thumbnailId.jpg' : null);
  
  /// Get vault file path (prefers vaultRelativePath, falls back to id for backward compatibility)
  String get effectiveVaultPath => vaultRelativePath ?? id;
  
  /// Get width from metadata (for images/videos)
  int? get width => metadata?['width'] as int?;
  
  /// Get height from metadata (for images/videos)
  int? get height => metadata?['height'] as int?;
  
  /// Get duration in milliseconds from metadata (for videos/audio)
  int? get durationMs => metadata?['durationMs'] as int?;
  
  /// Display name (custom name if set, otherwise original filename)
  String get displayName => customName ?? originalFilename;
  
  /// File extension (if available)
  String? get extension {
    final parts = originalFilename.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : null;
  }
  
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'originalFilename': originalFilename,
      'customName': customName,
      'type': type.toString().split('.').last,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'dateAdded': dateAdded.toIso8601String(),
      'dateModified': dateModified?.toIso8601String(),
      'source': source.toString().split('.').last,
      'sourceUrl': sourceUrl,
      'sourceSite': sourceSite,
      'thumbnailId': thumbnailId,
      'thumbnailPath': thumbnailPath,
      'vaultRelativePath': vaultRelativePath,
      'metadata': metadata,
      'isEncrypted': isEncrypted,
    };
  }
  
  factory VaultItem.fromJson(Map<String, dynamic> json) {
    return VaultItem(
      id: json['id'] as String,
      originalFilename: json['originalFilename'] as String,
      customName: json['customName'] as String?,
      type: VaultItemType.values.firstWhere(
        (e) => e.toString().split('.').last == json['type'],
        orElse: () => VaultItemType.unknown,
      ),
      mimeType: json['mimeType'] as String?,
      sizeBytes: json['sizeBytes'] as int,
      dateAdded: DateTime.parse(json['dateAdded'] as String),
      dateModified: json['dateModified'] != null 
          ? DateTime.parse(json['dateModified'] as String) 
          : null,
      source: VaultItemSource.values.firstWhere(
        (e) => e.toString().split('.').last == json['source'],
        orElse: () => VaultItemSource.unknown,
      ),
      sourceUrl: json['sourceUrl'] as String?,
      sourceSite: json['sourceSite'] as String?,
      thumbnailId: json['thumbnailId'] as String?,
      thumbnailPath: json['thumbnailPath'] as String?,
      vaultRelativePath: json['vaultRelativePath'] as String?,
      metadata: json['metadata'] != null 
          ? Map<String, dynamic>.from(json['metadata'] as Map)
          : null,
      isEncrypted: json['isEncrypted'] as bool? ?? false,
    );
  }
  
  VaultItem copyWith({
    String? id,
    String? originalFilename,
    String? customName,
    VaultItemType? type,
    String? mimeType,
    int? sizeBytes,
    DateTime? dateAdded,
    DateTime? dateModified,
    VaultItemSource? source,
    String? sourceUrl,
    String? sourceSite,
    String? thumbnailId,
    String? thumbnailPath,
    String? vaultRelativePath,
    Map<String, dynamic>? metadata,
    bool? isEncrypted,
  }) {
    return VaultItem(
      id: id ?? this.id,
      originalFilename: originalFilename ?? this.originalFilename,
      customName: customName ?? this.customName,
      type: type ?? this.type,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      dateAdded: dateAdded ?? this.dateAdded,
      dateModified: dateModified ?? this.dateModified,
      source: source ?? this.source,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      sourceSite: sourceSite ?? this.sourceSite,
      thumbnailId: thumbnailId ?? this.thumbnailId,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      vaultRelativePath: vaultRelativePath ?? this.vaultRelativePath,
      metadata: metadata ?? this.metadata,
      isEncrypted: isEncrypted ?? this.isEncrypted,
    );
  }
}

/// Type of vault item
enum VaultItemType {
  photo,
  video,
  audio,
  document,
  archive,
  unknown, // For unidentifiable file types
}

/// Source of vault item
enum VaultItemSource {
  camera, // Direct camera capture
  browser, // Browser download/extraction
  import, // File import from device
  share, // Share sheet import
  unknown,
}

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:image/image.dart' as img;
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:video_player/video_player.dart';
import '../models/vault_item.dart';
import '../models/album.dart';
import '../models/vault_folder.dart';
import 'encryption_service.dart';
import 'thumbnail_cache_service.dart';

/// Process image thumbnail in isolate (must be top-level function)
Uint8List? _processImageThumbnail(Uint8List imageData) {
  try {
    final image = img.decodeImage(imageData);
    if (image != null) {
      final thumbnail = img.copyResize(
        image, 
        width: 200,
        height: 200, 
        interpolation: img.Interpolation.linear,
      );
      return Uint8List.fromList(img.encodeJpg(thumbnail, quality: 75));
    }
  } catch (e) {
    debugPrint('[VaultService] Error in isolate image processing: $e');
  }
  return null;
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

/// Comprehensive vault service for managing media storage
/// Supports all file types including unknown binaries
/// Files are stored unencrypted (raw) - vault access is protected by PIN unlock
class VaultService extends ChangeNotifier {
  static const String _kSha256MetadataKey = 'sha256';
  static const String _kTimestampMsMetadataKey = 'timestampMs';
  static const String _kTagsMetadataKey = 'tags';

  final EncryptionService _encryptionService; // Used for PIN authentication, not file encryption
  final ThumbnailCacheService _thumbnailCacheService;
  
  Directory? _vaultDirectory; // Always local storage
  Directory? _thumbnailsDirectory;
  Directory? _indexDirectory;
  Directory? _iCloudBackupDirectory; // iCloud backup location (if enabled)
  File? _indexFile;
  File? _albumsFile;
  
  final List<VaultItem> _items = [];
  final List<Album> _albums = [];
  final List<VaultFolder> _folders = [];
  final Map<String, Uint8List> _thumbnailMemoryCache = {};
  static const int _maxThumbnailCacheSize = 30 * 1024 * 1024; // Reduced to 30MB for better performance
  int _thumbnailCacheSize = 0;
  
  File? _foldersFile;
  
  bool _isInitialized = false;
  Uint8List? _currentMasterKey;
  String? _currentVaultId; // null = primary vault
  bool? _useICloudBackup; // null = auto-detect, true = enable iCloud backup, false = local only
  bool _isSyncingToICloud = false;
  final Queue<String> _iCloudSyncQueue = Queue<String>(); // Queue of file IDs to sync
  
  // Debounced index saving
  Timer? _indexSaveTimer;
  bool _indexNeedsSaving = false;
  static const Duration _indexSaveDebounceDelay = Duration(seconds: 2);
  
  // Thumbnail cache initialization lock (prevents race conditions)
  Completer<void>? _thumbnailCacheInitCompleter;
  bool _thumbnailCacheInitialized = false;

  // Thumbnail generation queue (prevents iOS crashes during bulk imports)
  // Video frame extraction is memory-heavy; running many at once can crash the app.
  Future<void> _thumbnailGenerationChain = Future.value();
  int _pendingThumbnailJobs = 0;

  Future<String> _computeSha256ForFilePath(String filePath) async {
    final file = File(filePath);
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<String> _computeSha256ForBytes(Uint8List data) async {
    // Fast in-memory hash (used for WiFi uploads / share data).
    return sha256.convert(data).toString();
  }

  String? _getItemSha256(VaultItem item) {
    final v = item.metadata?[_kSha256MetadataKey];
    return v is String && v.isNotEmpty ? v : null;
  }

  Map<String, dynamic> _mergeMetadataWithDefaults({
    required Map<String, dynamic>? metadata,
    int? timestampMs,
    String? sha256Digest,
  }) {
    final merged = Map<String, dynamic>.from(metadata ?? const {});
    if (timestampMs != null && (merged[_kTimestampMsMetadataKey] == null)) {
      merged[_kTimestampMsMetadataKey] = timestampMs;
    }
    if (sha256Digest != null && sha256Digest.isNotEmpty && (merged[_kSha256MetadataKey] == null)) {
      merged[_kSha256MetadataKey] = sha256Digest;
    }
    return merged;
  }

  bool _backfillTimestampMetadataIfMissing() {
    bool changed = false;
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      final meta = Map<String, dynamic>.from(item.metadata ?? const {});
      if (meta[_kTimestampMsMetadataKey] == null) {
        meta[_kTimestampMsMetadataKey] = item.dateAdded.millisecondsSinceEpoch;
        _items[i] = item.copyWith(metadata: meta);
        changed = true;
      }
    }
    return changed;
  }

  List<String> _normalizeTagIds(dynamic raw) {
    if (raw == null) return const [];
    if (raw is String) {
      final trimmed = raw.trim();
      return trimmed.isEmpty ? const [] : <String>[trimmed];
    }
    if (raw is List) {
      return raw.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }
    return const [];
  }

  /// Returns the tag IDs stored on this item (color-coded tags live in metadata).
  List<String> getItemTagIds(String itemId) {
    if (!_isInitialized) return const [];
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx < 0) return const [];
    return _normalizeTagIds(_items[idx].metadata?[_kTagsMetadataKey]);
  }

  /// Overwrites the tag IDs for an item. Persists to the vault index.
  Future<bool> setItemTagIds(String itemId, List<String> tagIds) async {
    if (!_isInitialized) return false;
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx < 0) return false;

    final normalized = tagIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList()
      ..sort();
    final current = _items[idx];
    final meta = Map<String, dynamic>.from(current.metadata ?? const {});
    if (normalized.isEmpty) {
      meta.remove(_kTagsMetadataKey);
    } else {
      meta[_kTagsMetadataKey] = normalized;
    }
    _items[idx] = current.copyWith(metadata: meta);
    await _saveIndex();
    notifyListeners();
    return true;
  }

  /// Toggles a single tag ID on an item.
  Future<bool> toggleItemTagId(String itemId, String tagId) async {
    final id = tagId.trim();
    if (id.isEmpty) return false;
    final current = getItemTagIds(itemId);
    final set = current.toSet();
    if (set.contains(id)) {
      set.remove(id);
    } else {
      set.add(id);
    }
    return setItemTagIds(itemId, set.toList());
  }

  Future<String?> _ensureItemSha256(VaultItem item) async {
    final existing = _getItemSha256(item);
    if (existing != null) return existing;

    final filePath = _resolveVaultFilePathForItem(item);
    if (filePath == null) return null;
    final file = File(filePath);
    if (!await file.exists()) return null;

    try {
      final digest = await _computeSha256ForFilePath(filePath);
      final idx = _items.indexWhere((i) => i.id == item.id);
      if (idx >= 0) {
        final current = _items[idx];
        final updated = Map<String, dynamic>.from(current.metadata ?? const {});
        updated[_kSha256MetadataKey] = digest;
        _items[idx] = current.copyWith(metadata: updated);
        _scheduleIndexSave();
      }
      return digest;
    } catch (e) {
      debugPrint('[VaultService] SHA-256 failed for ${item.id}: $e');
      return null;
    }
  }

  Future<VaultItem?> _findDuplicateBySizeAndHash({
    required int sizeBytes,
    required String sha256Digest,
  }) async {
    // Narrow by size first; only hash-compare candidates.
    final candidates = _items.where((i) => i.sizeBytes == sizeBytes).toList(growable: false);
    for (final candidate in candidates) {
      final hash = _getItemSha256(candidate) ?? await _ensureItemSha256(candidate);
      if (hash != null && hash == sha256Digest) {
        return candidate;
      }
    }
    return null;
  }

  Future<String?> _enqueueThumbnailGeneration(Future<String?> Function() job) {
    final completer = Completer<String?>();
    _pendingThumbnailJobs++;

    _thumbnailGenerationChain = _thumbnailGenerationChain.then((_) async {
      try {
        final result = await job();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _pendingThumbnailJobs--;
      }
    }).catchError((_) {
      // Swallow errors to keep queue alive.
    });

    return completer.future;
  }

  /// Run a "heavy media" job serialized behind the thumbnail queue.
  /// This prevents concurrent video decode/IO spikes (anti-crash).
  Future<void> _enqueueMediaJob(Future<void> Function() job) async {
    try {
      await _enqueueThumbnailGeneration(() async {
        await job();
        return null;
      });
    } catch (_) {
      // Best-effort; never crash the app due to background metadata work.
    }
  }

  Future<void> _extractAndStoreVideoMetadata(String itemId, String filePath) async {
    // Only run if item still exists and duration isn't already known.
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx < 0) return;
    final item = _items[idx];
    if (item.type != VaultItemType.video) return;
    if (item.durationMs != null && item.durationMs! > 0) return;

    final file = File(filePath);
    if (!await file.exists()) return;

    final sizeBytes = await file.length().catchError((_) => 0);
    if (sizeBytes <= 0) return;

    // Conservative iOS safety gate (avoid known native crashes on odd containers/huge files).
    if (Platform.isIOS) {
      final lower = filePath.toLowerCase();
      final isCommonContainer = lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.m4v');
      if (!isCommonContainer) return;
      // Duration extraction is less crash-prone than thumbnail extraction; allow larger files.
      // Keep a cap to avoid pathological cases.
      if (sizeBytes > 1024 * 1024 * 1024) return; // 1GB
    }

    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.file(file);
      await controller
          .initialize()
          .timeout(Platform.isIOS ? const Duration(seconds: 6) : const Duration(seconds: 8));
      final duration = controller.value.duration;
      final size = controller.value.size;

      final updated = Map<String, dynamic>.from(item.metadata ?? const {});
      if (duration.inMilliseconds > 0) {
        updated['durationMs'] = duration.inMilliseconds;
      }
      if (size.width > 0 && size.height > 0) {
        updated['width'] = size.width.round();
        updated['height'] = size.height.round();
      }

      _items[idx] = item.copyWith(metadata: updated);
      _scheduleIndexSave();
      notifyListeners();
      debugPrint('[VaultService] Extracted video metadata: $itemId durationMs=${updated['durationMs']}');
    } catch (e) {
      debugPrint('[VaultService] Video metadata extraction failed for $itemId: $e');
    } finally {
      try {
        await controller?.dispose();
      } catch (_) {}
    }
  }
  
  List<VaultItem> get items => List.unmodifiable(_items);
  List<Album> get albums => List.unmodifiable(_albums);
  List<VaultFolder> get folders => List.unmodifiable(_folders);
  bool get isInitialized => _isInitialized;
  String? get currentVaultId => _currentVaultId;
  
  /// Get current storage preference
  /// Returns null if not set (auto-detect), true for iCloud backup, false for local only
  /// Note: Files are always stored locally first, iCloud is used for backup/sync
  Future<bool?> getStoragePreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey('vault_storage_preference')) {
      return null; // Auto-detect
    }
    return prefs.getBool('vault_storage_preference');
  }
  
  /// Set storage preference
  /// null = auto-detect, true = enable iCloud backup, false = local only
  /// Note: Files are always stored locally first for performance, iCloud is used for backup
  Future<void> setStoragePreference(bool? useICloud) async {
    final prefs = await SharedPreferences.getInstance();
    if (useICloud == null) {
      await prefs.remove('vault_storage_preference');
    } else {
      await prefs.setBool('vault_storage_preference', useICloud);
    }
    _useICloudBackup = useICloud;
    
    // Initialize iCloud backup directory if enabled
    if (useICloud == true && Platform.isIOS) {
      _initializeICloudBackup();
    } else {
      _iCloudBackupDirectory = null;
    }
    
    notifyListeners();
  }
  
  VaultService(this._encryptionService) : _thumbnailCacheService = ThumbnailCacheService();
  
  /// Cleanup resources
  @override
  void dispose() {
    _indexSaveTimer?.cancel();
    _indexSaveTimer = null;
    super.dispose();
  }
  
  /// Initialize vault directory structure
  /// [masterKey] - Master key for authentication (not used for file encryption - files are stored raw)
  /// [vaultId] - ID of the vault (null = primary vault)
  /// [forceReinit] - Force reinitialization even if already initialized (for switching vaults)
  Future<void> initialize({Uint8List? masterKey, String? vaultId, bool forceReinit = false}) async {
    if (_isInitialized && !forceReinit) {
      // If already initialized for same vault ID, don't reinitialize
      if (_currentVaultId == vaultId) return;
      // If switching vaults, force reinit
      forceReinit = true;
    }
    
    if (forceReinit) {
      // Reset state before reinitializing
      _items.clear();
      _albums.clear();
      _folders.clear();
      _thumbnailMemoryCache.clear();
      _thumbnailCacheSize = 0;
      _isInitialized = false;
    }
    
    _currentMasterKey = masterKey;
    _currentVaultId = vaultId;
    
    // Load storage preference (now means iCloud backup, not primary storage)
    _useICloudBackup = await getStoragePreference();
    
    // ALWAYS use local storage for primary vault directory (for performance)
    // iCloud will be used for backup/sync in the background
    Directory appDir;
    try {
      appDir = await getApplicationDocumentsDirectory();
      debugPrint('[VaultService] Using local documents directory for vault storage (always local-first)');
    } catch (e) {
      debugPrint('[VaultService] Error getting directory: $e');
      rethrow;
    }
    
    // Defer iCloud backup init to background so vault UI can show sooner
    final doICloudBackup = _useICloudBackup == true && Platform.isIOS;
    
    // Determine vault directory name based on vault type and ID
    String vaultName;
    if (vaultId != null) {
      // Secondary vault - use vault ID
      vaultName = 'vault_$vaultId';
    } else {
      // Primary vault
      vaultName = 'vault';
    }
    
    _vaultDirectory = Directory('${appDir.path}/$vaultName');
    _thumbnailsDirectory = Directory('${_vaultDirectory!.path}/thumbnails');
    _indexDirectory = Directory('${_vaultDirectory!.path}/index');
    
    // Create directories
    await _vaultDirectory!.create(recursive: true);
    await _thumbnailsDirectory!.create(recursive: true);
    await _indexDirectory!.create(recursive: true);
    
    _indexFile = File('${_indexDirectory!.path}/items.json');
    _albumsFile = File('${_indexDirectory!.path}/albums.json');
    _foldersFile = File('${_indexDirectory!.path}/folders.json');
    
    await _loadIndex();
    await _loadAlbums();
    await _loadFolders();
    
    _isInitialized = true;
    notifyListeners();
    
    // Defer heavy work so vault launches faster; run in background
    unawaited(_ensureThumbnailCacheInitialized().then((_) {
      debugPrint('[VaultService] Thumbnail cache ready');
    }).catchError((e) {
      debugPrint('[VaultService] Thumbnail cache init error: $e');
    }));
    if (doICloudBackup) {
      unawaited(_initializeICloudBackup().catchError((e) {
        debugPrint('[VaultService] iCloud backup init error: $e');
      }));
    }
  }
  
  /// Ensure thumbnail cache is initialized (thread-safe, prevents race conditions)
  Future<void> _ensureThumbnailCacheInitialized() async {
    if (_thumbnailCacheInitialized) return;
    
    // If initialization is already in progress, wait for it
    if (_thumbnailCacheInitCompleter != null) {
      return _thumbnailCacheInitCompleter!.future;
    }
    
    // Start initialization
    _thumbnailCacheInitCompleter = Completer<void>();
    
    try {
      await _thumbnailCacheService.initialize();
      _thumbnailCacheInitialized = true;
      debugPrint('[VaultService] Thumbnail cache initialized');
      _thumbnailCacheInitCompleter!.complete();
    } catch (e) {
      debugPrint('[VaultService] Error initializing thumbnail cache: $e');
      _thumbnailCacheInitCompleter!.completeError(e);
      _thumbnailCacheInitCompleter = null;
      rethrow;
    }
  }
  
  /// Initialize iCloud backup directory (for background sync)
  /// Files are stored locally first, then synced to iCloud in background
  Future<void> _initializeICloudBackup() async {
    if (!Platform.isIOS) return;
    
    try {
      // Use platform channel to get iCloud container URL
      const platform = MethodChannel('com.angelonartey.nyx/icloud');
      final String? containerPath = await platform.invokeMethod('getICloudContainerPath');
      
      if (containerPath != null && containerPath.isNotEmpty) {
        // Determine vault directory name
        String vaultName;
        if (_currentVaultId != null) {
          vaultName = 'vault_${_currentVaultId}_backup';
        } else {
          vaultName = 'vault_backup';
        }
        
        final backupDir = Directory('$containerPath/$vaultName');
        if (await backupDir.exists() || await backupDir.create(recursive: true).then((_) => true)) {
          _iCloudBackupDirectory = backupDir;
          debugPrint('[VaultService] iCloud backup directory initialized: ${backupDir.path}');
          
          // Start background sync of existing files
          _startBackgroundICloudSync();
        } else {
          debugPrint('[VaultService] Failed to create iCloud backup directory');
        }
      } else {
        debugPrint('[VaultService] iCloud container not available - backup disabled');
        _iCloudBackupDirectory = null;
      }
    } catch (e) {
      debugPrint('[VaultService] Error initializing iCloud backup: $e');
      _iCloudBackupDirectory = null;
    }
  }
  
  /// Start background sync to iCloud (non-blocking)
  void _startBackgroundICloudSync() {
    if (_iCloudBackupDirectory == null || _isSyncingToICloud) return;
    
    // Queue all existing files for sync
    for (final item in _items) {
      _iCloudSyncQueue.add(item.id);
    }
    
    // Start sync process in background
    _processICloudSyncQueue();
  }
  
  /// Process iCloud sync queue in background
  Future<void> _processICloudSyncQueue() async {
    if (_isSyncingToICloud || _iCloudBackupDirectory == null) return;
    _isSyncingToICloud = true;
    
    while (_iCloudSyncQueue.isNotEmpty) {
      final fileId = _iCloudSyncQueue.removeFirst();
      
      try {
        await _syncFileToICloud(fileId);
      } catch (e) {
        debugPrint('[VaultService] Error syncing file $fileId to iCloud: $e');
        // Re-queue for retry (with limit to prevent infinite loops)
        if (!_iCloudSyncQueue.contains(fileId) && _iCloudSyncQueue.length < 100) {
          _iCloudSyncQueue.add(fileId);
        }
      }
      
      // Yield to prevent blocking
      await Future.delayed(const Duration(milliseconds: 50));
    }
    
    _isSyncingToICloud = false;
  }
  
  /// Sync a single file to iCloud backup
  Future<void> _syncFileToICloud(String fileId) async {
    if (_iCloudBackupDirectory == null || _vaultDirectory == null) return;
    
    final localFile = File('${_vaultDirectory!.path}/$fileId');
    if (!await localFile.exists()) return;
    
    final backupFile = File('${_iCloudBackupDirectory!.path}/$fileId');
    
    // Check if backup is up to date
    if (await backupFile.exists()) {
      final localModified = await localFile.lastModified();
      final backupModified = await backupFile.lastModified();
      if (backupModified.isAfter(localModified) || backupModified.isAtSameMomentAs(localModified)) {
        // Backup is up to date
        return;
      }
    }
    
    // Copy file to iCloud backup (in background)
    await localFile.copy(backupFile.path);
    debugPrint('[VaultService] Synced file $fileId to iCloud backup');
  }
  
  /// Save index to disk (public method for batch operations)
  /// If [immediate] is true, saves immediately; otherwise uses debounced save
  Future<void> saveIndex({bool immediate = false}) async {
    if (immediate) {
      _indexSaveTimer?.cancel();
      _indexSaveTimer = null;
      _indexNeedsSaving = false;
      await _saveIndex();
    } else {
      _scheduleIndexSave();
    }
  }
  
  /// Schedule a debounced index save
  void _scheduleIndexSave() {
    _indexNeedsSaving = true;
    _indexSaveTimer?.cancel();
    _indexSaveTimer = Timer(_indexSaveDebounceDelay, () {
      if (_indexNeedsSaving) {
        _indexNeedsSaving = false;
        _saveIndex().catchError((e) {
          debugPrint('[VaultService] Error in debounced index save: $e');
        });
      }
    });
  }
  
  /// Load vault index from disk
  Future<void> _loadIndex() async {
    if (_indexFile == null || !await _indexFile!.exists()) {
      _items.clear();
      return;
    }
    
    try {
      final content = await _indexFile!.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final itemsJson = json['items'] as List<dynamic>? ?? [];
      
      _items.clear();
      _items.addAll(
        itemsJson.map((item) => VaultItem.fromJson(item as Map<String, dynamic>))
      );

      // Ensure every item has a stable chronological timestamp for UI sorting.
      // (Older vaults may not have this metadata key.)
      final changed = _backfillTimestampMetadataIfMissing();
      if (changed) {
        _scheduleIndexSave();
      }
    } catch (e) {
      debugPrint('[VaultService] Error loading index: $e');
      _items.clear();
    }
  }
  
  /// Save vault index to disk (atomic write)
  /// Uses streaming JSON encoding for large indexes to reduce memory usage
  Future<void> _saveIndex() async {
    if (_indexFile == null) return;
    
    try {
      // For large indexes, use streaming approach
      if (_items.length > 1000) {
        final tempFile = File('${_indexFile!.path}.tmp');
        final sink = tempFile.openWrite();
        try {
          sink.write('{"version":1,"lastUpdated":"${DateTime.now().toIso8601String()}","items":[');
          for (int i = 0; i < _items.length; i++) {
            if (i > 0) sink.write(',');
            sink.write(jsonEncode(_items[i].toJson()));
            // Flush periodically for large indexes
            if (i % 100 == 0) {
              await sink.flush();
            }
          }
          sink.write(']}');
          await sink.flush();
        } finally {
          await sink.close();
        }
        // Atomic rename
        await tempFile.rename(_indexFile!.path);
      } else {
        // Small index - use standard approach
        final json = {
          'version': 1,
          'lastUpdated': DateTime.now().toIso8601String(),
          'items': _items.map((item) => item.toJson()).toList(),
        };
        
        final content = jsonEncode(json);
        final tempFile = File('${_indexFile!.path}.tmp');
        
        // Atomic write: write to temp, then rename
        await tempFile.writeAsString(content);
        await tempFile.rename(_indexFile!.path);
      }
    } catch (e) {
      debugPrint('[VaultService] Error saving index: $e');
    }
  }
  
  /// Load albums from disk
  Future<void> _loadAlbums() async {
    if (_albumsFile == null || !await _albumsFile!.exists()) {
      _albums.clear();
      // Create default smart albums
      _createDefaultAlbums();
      // Save default albums to disk
      await _saveAlbums();
        notifyListeners();
      debugPrint('[VaultService] Created ${_albums.length} default albums (file didn\'t exist)');
      return;
    }
    
    try {
      final content = await _albumsFile!.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final albumsJson = json['albums'] as List<dynamic>? ?? [];
      
      _albums.clear();
      _albums.addAll(
        albumsJson.map((album) => Album.fromJson(album as Map<String, dynamic>))
      );
      
      // Ensure default albums exist
      final hadMissingAlbums = _albums.length < 6; // We should have at least 6 smart albums
      _ensureDefaultAlbums();
      
      // If we added missing albums, save them
      if (hadMissingAlbums && _albums.length > albumsJson.length) {
        await _saveAlbums();
      }
      
      notifyListeners();
      } catch (e) {
      debugPrint('[VaultService] Error loading albums: $e');
      _albums.clear();
      _createDefaultAlbums();
      // Save default albums to disk
      await _saveAlbums();
      notifyListeners();
      debugPrint('[VaultService] Created ${_albums.length} default albums after error');
    }
  }
  
  /// Save albums to disk (atomic write)
  Future<void> _saveAlbums() async {
    if (_albumsFile == null) return;
    
    try {
      final json = {
        'version': 1,
        'lastUpdated': DateTime.now().toIso8601String(),
        'albums': _albums.map((album) => album.toJson()).toList(),
      };
      
      final content = jsonEncode(json);
      final tempFile = File('${_albumsFile!.path}.tmp');
      
      await tempFile.writeAsString(content);
      await tempFile.rename(_albumsFile!.path);
    } catch (e) {
      debugPrint('[VaultService] Error saving albums: $e');
    }
  }
  
  /// Load folders from disk
  Future<void> _loadFolders() async {
    if (_foldersFile == null || !await _foldersFile!.exists()) {
      _folders.clear();
      notifyListeners();
      return;
    }
    
    try {
      final content = await _foldersFile!.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final foldersJson = json['folders'] as List<dynamic>? ?? [];
      
      _folders.clear();
      _folders.addAll(
        foldersJson.map((folder) => VaultFolder.fromJson(folder as Map<String, dynamic>))
      );
      
      notifyListeners();
    } catch (e) {
      debugPrint('[VaultService] Error loading folders: $e');
      _folders.clear();
      notifyListeners();
    }
  }
  
  /// Save folders to disk (atomic write)
  Future<void> _saveFolders() async {
    if (_foldersFile == null) return;
    
    try {
      final json = {
        'version': 1,
        'lastUpdated': DateTime.now().toIso8601String(),
        'folders': _folders.map((folder) => folder.toJson()).toList(),
      };
      
      final content = jsonEncode(json);
      final tempFile = File('${_foldersFile!.path}.tmp');
      
      await tempFile.writeAsString(content);
      await tempFile.rename(_foldersFile!.path);
    } catch (e) {
      debugPrint('[VaultService] Error saving folders: $e');
    }
  }
  
  /// Create a new folder
  Future<VaultFolder> createFolder(String name, {String? parentFolderId}) async {
    if (!_isInitialized) throw StateError('Vault not initialized');
    
    final folder = VaultFolder(
      id: _generateFileId(),
      name: name,
      createdAt: DateTime.now(),
      parentFolderId: parentFolderId,
    );
    
    _folders.add(folder);
    await _saveFolders();
    notifyListeners();
    
    return folder;
  }
  
  /// Rename a folder
  Future<bool> renameFolder(String folderId, String newName) async {
    if (!_isInitialized) return false;
    if (newName.trim().isEmpty) return false;
    
    final folderIndex = _folders.indexWhere((f) => f.id == folderId);
    if (folderIndex == -1) return false;
    
    // Check if name already exists (case-insensitive)
    final trimmedName = newName.trim();
    final existingFolder = _folders.firstWhere(
      (f) => f.id != folderId && f.name.toLowerCase() == trimmedName.toLowerCase(),
      orElse: () => VaultFolder(id: '', name: '', createdAt: DateTime.now()),
    );
    if (existingFolder.id.isNotEmpty) {
      throw StateError('A folder with this name already exists');
    }
    
    _folders[folderIndex] = _folders[folderIndex].copyWith(
      name: trimmedName,
      dateModified: DateTime.now(),
    );
    await _saveFolders();
    notifyListeners();
    
    return true;
  }
  
  /// Delete a folder
  Future<bool> deleteFolder(String folderId) async {
    if (!_isInitialized) return false;
    
    final folderIndex = _folders.indexWhere((f) => f.id == folderId);
    if (folderIndex == -1) return false;
    
    final folderToDelete = _folders[folderIndex];
    
    try {
      // Strategy: Re-parent children folders to the deleted folder's parent
      // This prevents orphaned subfolders
      final parentFolderId = folderToDelete.parentFolderId;
      
      // Find all child folders (folders that have this folder as parent)
      final childFolders = _folders.where((f) => f.parentFolderId == folderId).toList();
      
      // Re-parent child folders to the deleted folder's parent (or null for root)
      for (final childFolder in childFolders) {
        final childIndex = _folders.indexWhere((f) => f.id == childFolder.id);
        if (childIndex != -1) {
          _folders[childIndex] = childFolder.copyWith(
            parentFolderId: parentFolderId,
            dateModified: DateTime.now(),
          );
          debugPrint('[VaultService] Re-parented folder "${childFolder.name}" to ${parentFolderId ?? "root"}');
        }
      }
      
      // Move items from deleted folder to parent folder (or root if no parent)
      if (folderToDelete.itemIds.isNotEmpty) {
        if (parentFolderId != null) {
          // Move items to parent folder
          final parentIndex = _folders.indexWhere((f) => f.id == parentFolderId);
          if (parentIndex != -1) {
            final parentFolder = _folders[parentIndex];
            final updatedItemIds = List<String>.from(parentFolder.itemIds)
              ..addAll(folderToDelete.itemIds);
            _folders[parentIndex] = parentFolder.copyWith(
              itemIds: updatedItemIds,
              dateModified: DateTime.now(),
            );
            debugPrint('[VaultService] Moved ${folderToDelete.itemIds.length} items to parent folder');
          } else {
            // Parent folder not found - items become root items (no folder)
            debugPrint('[VaultService] Warning: Parent folder not found, items removed from folder structure');
          }
        } else {
          // No parent - items become root items (no folder)
          debugPrint('[VaultService] Items from deleted folder are now root items');
        }
      }
      
      // Remove the folder
      _folders.removeAt(folderIndex);
      debugPrint('[VaultService] Deleted folder: ${folderToDelete.name}');
      
      // Persist changes
      await _saveFolders();
      
      // Notify listeners
      notifyListeners();
      
      return true;
    } catch (e, stackTrace) {
      debugPrint('[VaultService] Error deleting folder: $e');
      debugPrint('[VaultService] Stack trace: $stackTrace');
      return false;
    }
  }
  
  /// Add item to folder
  Future<bool> addItemToFolder(String itemId, String folderId) async {
    if (!_isInitialized) return false;
    
    final folderIndex = _folders.indexWhere((f) => f.id == folderId);
    if (folderIndex == -1) return false;
    
    if (!_folders[folderIndex].itemIds.contains(itemId)) {
      _folders[folderIndex] = _folders[folderIndex].copyWith(
        itemIds: [..._folders[folderIndex].itemIds, itemId],
        dateModified: DateTime.now(),
      );
      await _saveFolders();
      notifyListeners();
    }
    
    return true;
  }
  
  /// Remove item from folder
  Future<bool> removeItemFromFolder(String itemId, String folderId) async {
    if (!_isInitialized) return false;
    
    final folderIndex = _folders.indexWhere((f) => f.id == folderId);
    if (folderIndex == -1) return false;
    
    final itemIds = List<String>.from(_folders[folderIndex].itemIds);
    itemIds.remove(itemId);
    
    _folders[folderIndex] = _folders[folderIndex].copyWith(
      itemIds: itemIds,
      dateModified: DateTime.now(),
    );
    await _saveFolders();
    notifyListeners();
    
    return true;
  }
  
  /// Get items in a folder
  /// Filters out any items that no longer exist (orphaned references)
  List<VaultItem> getFolderItems(String folderId) {
    final folder = _folders.firstWhere((f) => f.id == folderId, orElse: () => throw StateError('Folder not found'));
    
    // Filter out missing items and collect valid items
    final validItems = <VaultItem>[];
    final orphanedIds = <String>[];
    
    for (final id in folder.itemIds) {
      try {
        final item = _items.firstWhere((i) => i.id == id);
        validItems.add(item);
      } catch (e) {
        // Item doesn't exist - mark as orphaned
        orphanedIds.add(id);
        debugPrint('[VaultService] Found orphaned item reference in folder ${folder.name}: $id');
      }
    }
    
    // Clean up orphaned references if any were found
    if (orphanedIds.isNotEmpty) {
      final updatedItemIds = folder.itemIds.where((id) => !orphanedIds.contains(id)).toList();
      if (updatedItemIds.length != folder.itemIds.length) {
        // Update folder with cleaned item IDs
        final updatedFolder = VaultFolder(
          id: folder.id,
          name: folder.name,
          createdAt: folder.createdAt,
          dateModified: DateTime.now(),
          parentFolderId: folder.parentFolderId,
          itemIds: updatedItemIds,
        );
        final index = _folders.indexWhere((f) => f.id == folderId);
        if (index >= 0) {
          _folders[index] = updatedFolder;
          _saveFolders().catchError((e) {
            debugPrint('[VaultService] Error saving folders after cleanup: $e');
          });
        }
      }
    }
    
    return validItems;
  }
  
  /// Get items not in any folder (root items)
  List<VaultItem> getRootItems() {
    final allFolderItemIds = _folders.expand((f) => f.itemIds).toSet();
    return _items.where((item) => !allFolderItemIds.contains(item.id)).toList();
  }
  
  /// Create default smart albums
  void _createDefaultAlbums() {
    _albums.clear();
    _albums.addAll([
      Album(id: 'smart_photos', name: 'Photos', createdAt: DateTime.now()),
      Album(id: 'smart_videos', name: 'Videos', createdAt: DateTime.now()),
      Album(id: 'smart_audio', name: 'Audio', createdAt: DateTime.now()),
      Album(id: 'smart_documents', name: 'Documents', createdAt: DateTime.now()),
      Album(id: 'smart_downloads', name: 'Downloads', createdAt: DateTime.now()),
      Album(id: 'smart_recent', name: 'Recent', createdAt: DateTime.now()),
    ]);
  }
  
  /// Ensure default albums exist
  void _ensureDefaultAlbums() {
    final defaultIds = ['smart_photos', 'smart_videos', 'smart_audio', 'smart_documents', 'smart_downloads', 'smart_recent'];
    for (final id in defaultIds) {
      if (!_albums.any((a) => a.id == id)) {
        _albums.add(Album(id: id, name: _getSmartAlbumName(id), createdAt: DateTime.now()));
      }
    }
    // Sort albums to ensure smart albums come first, then user albums alphabetically
    _albums.sort((a, b) {
      final aIsSmart = a.id.startsWith('smart_');
      final bIsSmart = b.id.startsWith('smart_');
      if (aIsSmart && !bIsSmart) return -1;
      if (!aIsSmart && bIsSmart) return 1;
      // For smart albums, maintain order: Recent, Photos, Videos, Audio, Documents, Downloads
      if (aIsSmart && bIsSmart) {
        final order = {'smart_recent': 0, 'smart_photos': 1, 'smart_videos': 2, 'smart_audio': 3, 'smart_documents': 4, 'smart_downloads': 5};
        return (order[a.id] ?? 99).compareTo(order[b.id] ?? 99);
      }
      // For user albums, sort alphabetically
      return a.name.compareTo(b.name);
    });
  }
  
  String _getSmartAlbumName(String id) {
    switch (id) {
      case 'smart_photos': return 'Photos';
      case 'smart_videos': return 'Videos';
      case 'smart_audio': return 'Audio';
      case 'smart_documents': return 'Documents';
      case 'smart_downloads': return 'Downloads';
      case 'smart_recent': return 'Recent';
      default: return 'Album';
    }
  }
  
  /// Generate cryptographically random file ID
  String _generateFileId() {
    return const Uuid().v4();
  }
  
  /// Detect file type from filename and MIME type
  VaultItemType _detectFileType(String filename, String? mimeType) {
    final ext = filename.split('.').last.toLowerCase();
    
    // Check MIME type first
    if (mimeType != null) {
      if (mimeType.startsWith('image/')) return VaultItemType.photo;
      if (mimeType.startsWith('video/')) return VaultItemType.video;
      if (mimeType.startsWith('audio/')) return VaultItemType.audio;
      if (mimeType.contains('pdf') || mimeType.contains('document') || mimeType.contains('text')) {
        return VaultItemType.document;
      }
    }
    
    // Check extension
    final photoExts = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp'];
    final videoExts = ['mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v', 'flv', 'wmv', '3gp'];
    final audioExts = ['mp3', 'wav', 'aac', 'flac', 'm4a', 'ogg', 'wma'];
    final docExts = ['pdf', 'doc', 'docx', 'txt', 'rtf', 'odt', 'pages'];
    final archiveExts = ['zip', 'rar', '7z', 'tar', 'gz', 'bz2'];
    
    if (photoExts.contains(ext)) return VaultItemType.photo;
    if (videoExts.contains(ext)) return VaultItemType.video;
    if (audioExts.contains(ext)) return VaultItemType.audio;
    if (docExts.contains(ext)) return VaultItemType.document;
    if (archiveExts.contains(ext)) return VaultItemType.archive;
    
    return VaultItemType.unknown;
  }
  
  /// Store file data in vault
  /// Returns the created VaultItem
  /// [folderId] - Optional folder ID to store the file in. If provided, the file will be added to that folder.
  Future<VaultItem> storeFile({
    required Uint8List data,
    required String filename,
    String? mimeType,
    VaultItemSource source = VaultItemSource.unknown,
    String? sourceUrl,
    String? sourceSite,
    Map<String, dynamic>? metadata,
    String? folderId, // Optional folder ID to store the file in
  }) async {
    if (!_isInitialized) {
      throw StateError('Vault not initialized');
    }

    // Dedup: hash the incoming bytes and skip if already in vault.
    final incomingDigest = await _computeSha256ForBytes(data);
    final duplicate = await _findDuplicateBySizeAndHash(
      sizeBytes: data.length,
      sha256Digest: incomingDigest,
    );
    if (duplicate != null) {
      debugPrint('[VaultService] Duplicate detected (storeFile), skipping: $filename -> keep ${duplicate.id}');
      return duplicate;
    }
    
    final fileId = _generateFileId();
    final fileType = _detectFileType(filename, mimeType);
    
    // Determine file extension for better organization
    String? extension;
    if (filename.contains('.')) {
      extension = filename.split('.').last.toLowerCase();
    }
    final vaultFileName = extension != null ? '$fileId.$extension' : fileId;
    final vaultRelativePath = vaultFileName; // Relative to vault directory
    
    // Write file to vault directory (unencrypted - raw storage)
    // For large files, use streaming write to reduce memory pressure
    final filePath = '${_vaultDirectory!.path}/$vaultRelativePath';
    final file = File(filePath);
    
    if (data.length > 5 * 1024 * 1024) {
      // Large file - use streaming write with smaller chunks to reduce memory pressure
      // This is especially important when video is playing simultaneously
      final sink = file.openWrite();
      try {
        // Use smaller chunks to reduce memory pressure
        const chunkSize = 512 * 1024; // 512KB chunks (smaller for better memory management)
        for (int i = 0; i < data.length; i += chunkSize) {
          final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
          sink.add(data.sublist(i, end));
          // Yield more frequently to prevent memory pressure and allow video playback
          if (i % (chunkSize * 2) == 0) {
            await sink.flush();
            await Future.delayed(const Duration(milliseconds: 5)); // Allow memory cleanup and video playback
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } else {
      // Small file - write all at once
      await file.writeAsBytes(data);
    }
    
    // Defer thumbnail generation - create item first, generate thumbnail later
    // This allows UI to update immediately while thumbnails generate in background
    
    // Create vault item immediately (without thumbnail)
    // timestampMs: best-effort (data-based uploads rarely have original capture time)
    final mergedMetadata = _mergeMetadataWithDefaults(
      metadata: metadata,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      sha256Digest: incomingDigest,
    );
    final item = VaultItem(
      id: fileId,
      originalFilename: filename,
      type: fileType,
      mimeType: mimeType,
      sizeBytes: data.length,
      dateAdded: DateTime.now(),
      source: source,
      sourceUrl: sourceUrl,
      sourceSite: sourceSite,
      thumbnailId: null, // Deprecated - use thumbnailPath
      thumbnailPath: null, // Will be set later
      vaultRelativePath: vaultRelativePath, // Store relative path
      metadata: mergedMetadata,
      isEncrypted: false, // Files are stored unencrypted (vault access is still protected)
    );
    
    _items.add(item);

    // Extract video metadata (duration/size) in the background (serialized, anti-crash).
    if (fileType == VaultItemType.video) {
      _enqueueMediaJob(() => _extractAndStoreVideoMetadata(fileId, filePath));
    }
    
    // Generate thumbnail in background (don't await - let it complete asynchronously)
    // For photos, pass data directly; for videos, use file path
    final thumbnailData = (fileType == VaultItemType.photo) ? data : null;
    final videoThumbnailPath = (fileType == VaultItemType.video) ? filePath : null;
    
    // For videos, always generate thumbnail (even if async)
    // For other types, generate in background
    if (fileType == VaultItemType.video) {
      // Videos MUST have thumbnails - generate immediately but don't block.
      // This runs serialized behind the thumbnail queue to prevent crashes.
      _enqueueThumbnailGeneration(() => _generateThumbnailAsync(fileId, videoThumbnailPath ?? filePath, fileType, thumbnailData))
          .then((generatedThumbnailPath) {
        if (generatedThumbnailPath != null) {
          // Update item with thumbnail path
          final itemIndex = _items.indexWhere((i) => i.id == fileId);
          if (itemIndex >= 0) {
            _items[itemIndex] = _items[itemIndex].copyWith(thumbnailPath: generatedThumbnailPath);
            _scheduleIndexSave(); // Use debounced save
            notifyListeners();
            debugPrint('[VaultService] Video thumbnail generated and saved: $fileId -> $generatedThumbnailPath');
          }
        } else {
          debugPrint('[VaultService] WARNING: Video thumbnail generation failed for: $fileId');
        }
      }).catchError((e, stackTrace) {
        debugPrint('[VaultService] Error generating video thumbnail in background: $e');
        debugPrint('[VaultService] Stack trace: $stackTrace');
      });
    } else {
      // For non-videos, generate in background (photos, etc.)
      _enqueueThumbnailGeneration(() => _generateThumbnailAsync(fileId, videoThumbnailPath ?? filePath, fileType, thumbnailData))
          .then((generatedThumbnailPath) {
        if (generatedThumbnailPath != null) {
          // Update item with thumbnail path
          final itemIndex = _items.indexWhere((i) => i.id == fileId);
          if (itemIndex >= 0) {
            _items[itemIndex] = _items[itemIndex].copyWith(thumbnailPath: generatedThumbnailPath);
            _scheduleIndexSave(); // Use debounced save
            notifyListeners();
          }
        }
      }).catchError((e) {
        debugPrint('[VaultService] Error generating thumbnail in background: $e');
      });
    }
    
    // Use debounced index saving - more efficient than saving after each file
    _scheduleIndexSave();
    
    // Queue file for iCloud backup sync (if enabled) - happens in background
    if (_useICloudBackup == true && _iCloudBackupDirectory != null) {
      _iCloudSyncQueue.add(fileId);
      // Start sync if not already running (non-blocking)
      if (!_isSyncingToICloud) {
        _processICloudSyncQueue();
      }
    }
    
    // If folderId is provided, add the item to that folder
    if (folderId != null) {
      try {
        await addItemToFolder(fileId, folderId);
        debugPrint('[VaultService] Added file $fileId to folder $folderId');
    } catch (e) {
        debugPrint('[VaultService] Error adding file to folder: $e');
        // Continue even if folder addition fails
      }
    }
    
    // Batch notifyListeners - only notify if not in rapid import mode
    // (We'll notify at batch level in the import loop)
    notifyListeners();
    return item;
  }
  
  /// Store file from source file path (streaming copy - no memory loading)
  /// This is the preferred method for imports to avoid loading entire files into memory
  Future<VaultItem> storeFileFromPath({
    required String sourceFilePath,
    required String filename,
    String? mimeType,
    VaultItemSource source = VaultItemSource.unknown,
    String? sourceUrl,
    String? sourceSite,
    Map<String, dynamic>? metadata,
    String? folderId,
    bool queueThumbnailGeneration = true,
    bool awaitVideoMetadataExtraction = false,
  }) async {
    if (!_isInitialized) {
      throw StateError('Vault not initialized');
    }
    
    final sourceFile = File(sourceFilePath);
    if (!await sourceFile.exists()) {
      throw StateError('Source file does not exist: $sourceFilePath');
    }

    // Best-effort "chronological timestamp" for sorting.
    // Prefer any caller-provided metadata['timestampMs'], otherwise use source file modified time.
    int? sourceTimestampMs;
    try {
      final stat = await sourceFile.stat();
      sourceTimestampMs = stat.modified.millisecondsSinceEpoch;
    } catch (_) {
      // Ignore; we'll fall back to DateTime.now() below.
    }
    
    final fileId = _generateFileId();
    final fileType = _detectFileType(filename, mimeType);
    
    // Determine file extension
    String? extension;
    if (filename.contains('.')) {
      extension = filename.split('.').last.toLowerCase();
    }
    final vaultFileName = extension != null ? '$fileId.$extension' : fileId;
    final vaultRelativePath = vaultFileName;
    
    final destPath = '${_vaultDirectory!.path}/$vaultRelativePath';
    final destFile = File(destPath);
    
    // Stream copy from source to destination (no memory loading).
    // Do NOT rely on `length()` for iCloud-only files (it may be 0 until read begins).
    // We count bytes as we copy and enforce an "idle" timeout to prevent hangs where nothing happens.
    int? expectedSize;
    try {
      expectedSize = await sourceFile.length();
    } catch (_) {
      expectedSize = null;
    }

    if (expectedSize != null && expectedSize > 0) {
      debugPrint('[VaultService] Copying file (expected ${(expectedSize / 1024 / 1024).toStringAsFixed(2)} MB): $sourceFilePath -> $destPath');
    } else {
      debugPrint('[VaultService] Copying file (size unknown yet): $sourceFilePath -> $destPath');
    }

    final hashSink = _SingleDigestSink();
    final hashInput = sha256.startChunkedConversion(hashSink);
    final destSink = destFile.openWrite();
    int bytesCopied = 0;
    bool copySucceeded = false;
    final idleTimeout = Platform.isIOS ? const Duration(seconds: 120) : const Duration(seconds: 30);
    final iterator = StreamIterator<List<int>>(sourceFile.openRead());
    try {
      while (await iterator.moveNext().timeout(
        idleTimeout,
        onTimeout: () {
          throw TimeoutException('File copy stalled (no data received for ${idleTimeout.inSeconds}s)');
        },
      )) {
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        hashInput.add(chunk);
        destSink.add(chunk);
        bytesCopied += chunk.length;

        // Yield periodically so UI remains responsive during huge copies.
        if (bytesCopied % (4 * 1024 * 1024) < chunk.length) {
          await destSink.flush();
          await Future.delayed(const Duration(milliseconds: 1));
        }
      }
      await destSink.flush();
      copySucceeded = true;
      debugPrint('[VaultService] File copy completed: $destPath (${(bytesCopied / 1024 / 1024).toStringAsFixed(2)} MB)');
    } on TimeoutException catch (e) {
      debugPrint('[VaultService] Copy timeout: $e');
      if (Platform.isIOS) {
        throw StateError(
          'File copy stalled while downloading from iCloud. '
          'Make sure the file is fully downloaded in Photos/Files, then try again.',
        );
      }
      rethrow;
    } catch (e) {
      debugPrint('[VaultService] Copy error: $e');
      if (Platform.isIOS) {
        throw StateError(
          'Could not copy file. It may be in iCloud and not fully available. '
          'Open it in Photos or Files first, then try again.',
        );
      }
      rethrow;
    } finally {
      await iterator.cancel();
      await destSink.close();
      hashInput.close();
      // If copy failed, remove partially written file (best-effort cleanup).
      if (!copySucceeded) {
        if (await destFile.exists()) {
          try {
            await destFile.delete();
          } catch (_) {
            // Ignore cleanup failures.
          }
        }
      }
    }

    final incomingDigest = hashSink.digest?.toString() ?? '';
    if (incomingDigest.isNotEmpty) {
      final duplicate = await _findDuplicateBySizeAndHash(
        sizeBytes: bytesCopied,
        sha256Digest: incomingDigest,
      );
      if (duplicate != null) {
        debugPrint('[VaultService] Duplicate detected (storeFileFromPath), skipping: $filename -> keep ${duplicate.id}');
        try {
          if (await destFile.exists()) {
            await destFile.delete();
          }
        } catch (_) {}
        return duplicate;
      }
    }
    
    // Create vault item
    final mergedMetadata = _mergeMetadataWithDefaults(
      metadata: metadata,
      timestampMs: sourceTimestampMs ?? DateTime.now().millisecondsSinceEpoch,
      sha256Digest: incomingDigest.isNotEmpty ? incomingDigest : null,
    );
    final item = VaultItem(
      id: fileId,
      originalFilename: filename,
      type: fileType,
      mimeType: mimeType,
      sizeBytes: bytesCopied,
      dateAdded: DateTime.now(),
      source: source,
      sourceUrl: sourceUrl,
      sourceSite: sourceSite,
      thumbnailPath: null, // Will be set later
      vaultRelativePath: vaultRelativePath,
      metadata: mergedMetadata,
      isEncrypted: false,
    );
    
    _items.add(item);

    // Extract video metadata (duration/size) in the background (serialized, anti-crash).
    if (fileType == VaultItemType.video) {
      if (awaitVideoMetadataExtraction) {
        await _enqueueMediaJob(() => _extractAndStoreVideoMetadata(fileId, destPath));
      } else {
        _enqueueMediaJob(() => _extractAndStoreVideoMetadata(fileId, destPath));
      }
    }
    
    // Generate thumbnail in background (use file path, not data).
    // For bulk imports, callers can disable this and explicitly generate thumbnails in a controlled manner.
    if (queueThumbnailGeneration) {
      _enqueueThumbnailGeneration(() => _generateThumbnailAsync(fileId, destPath, fileType, null)).then((generatedThumbnailPath) {
        if (generatedThumbnailPath != null) {
          final itemIndex = _items.indexWhere((i) => i.id == fileId);
          if (itemIndex >= 0) {
            _items[itemIndex] = _items[itemIndex].copyWith(thumbnailPath: generatedThumbnailPath);
            _scheduleIndexSave();
            notifyListeners();
          }
        }
      }).catchError((e) {
        debugPrint('[VaultService] Error generating thumbnail in background: $e');
      });
    }
    
    _scheduleIndexSave();
    
    // Queue for iCloud backup if enabled
    if (_useICloudBackup == true && _iCloudBackupDirectory != null) {
      _iCloudSyncQueue.add(fileId);
      if (!_isSyncingToICloud) {
        _processICloudSyncQueue();
      }
    }
    
    // Add to folder if specified
    if (folderId != null) {
      try {
        await addItemToFolder(fileId, folderId);
      } catch (e) {
        debugPrint('[VaultService] Error adding file to folder: $e');
      }
    }
    
    notifyListeners();
    return item;
  }
  
  /// Generate thumbnail asynchronously (non-blocking)
  Future<String?> _generateThumbnailAsync(String fileId, String filePath, VaultItemType type, Uint8List? originalData) async {
    // Yield to allow UI to update first
    await Future.delayed(const Duration(milliseconds: 50));
    return _generateThumbnail(fileId, filePath, type, originalData);
  }
  
  /// Generate thumbnail for all file types
  Future<String?> _generateThumbnail(String fileId, String filePath, VaultItemType type, Uint8List? originalData) async {
    try {
      Uint8List? thumbnailData;
      
      if (type == VaultItemType.photo) {
        // Generate thumbnail from image using compute for heavy processing
        if (originalData != null) {
          try {
            // Use compute to process image in isolate (prevents UI blocking)
            thumbnailData = await compute(_processImageThumbnail, originalData);
          } catch (e) {
            debugPrint('[VaultService] Error processing image thumbnail in isolate: $e');
            // Fallback to main thread if compute fails
            final image = img.decodeImage(originalData);
            if (image != null) {
              final thumbnail = img.copyResize(
                image, 
                width: 200,
                height: 200, 
                interpolation: img.Interpolation.linear,
              );
              thumbnailData = Uint8List.fromList(img.encodeJpg(thumbnail, quality: 75));
            }
          }
        }
      } else if (type == VaultItemType.video) {
        // Generate video thumbnail screenshot from FIRST FRAME (0ms) - performance requirement
        debugPrint('[VaultService] Generating video thumbnail from first frame (0ms): $filePath');
        try {
          // Verify file exists before attempting thumbnail generation
          final videoFile = File(filePath);
          if (!await videoFile.exists()) {
            debugPrint('[VaultService] ERROR: Video file does not exist: $filePath');
            thumbnailData = null;
          } else {
            final fileSize = await videoFile.length();
            debugPrint('[VaultService] Video file exists, size: $fileSize bytes');
            
            if (fileSize == 0) {
              debugPrint('[VaultService] ERROR: Video file is empty: $filePath');
              thumbnailData = null;
            } else {
              // Anti-crash guard: skip extremely large videos on iOS (native extractor can OOM/crash)
              if (Platform.isIOS && fileSize > 750 * 1024 * 1024) {
                debugPrint('[VaultService] iOS: skipping thumbnail for huge video (>750MB): $filePath');
                thumbnailData = null;
              } else {
              // Generate thumbnail at FIRST FRAME (0ms) - requirement for instant poster display
              try {
                thumbnailData = await VideoThumbnail.thumbnailData(
                  video: filePath,
                  imageFormat: ImageFormat.JPEG,
                  // Reduce memory pressure on iOS
                  maxWidth: Platform.isIOS ? 240 : 320,
                  quality: Platform.isIOS ? 60 : 75,
                  timeMs: 0, // FIRST FRAME ONLY - no 1-second strategy
                ).timeout(
                  Platform.isIOS ? const Duration(seconds: 6) : const Duration(seconds: 10),
                  onTimeout: () {
                    debugPrint('[VaultService] Video thumbnail generation timed out: $filePath');
                    return null;
                  },
                );
                
                if (thumbnailData != null) {
                  debugPrint('[VaultService] Successfully generated video thumbnail from first frame: ${thumbnailData.length} bytes');
                } else {
                  debugPrint('[VaultService] ERROR: Video thumbnail generation returned null for: $filePath');
                }
              } catch (e) {
                debugPrint('[VaultService] Error generating video thumbnail from first frame: $e');
                thumbnailData = null;
              }
              }
            }
          }
        } catch (e, stackTrace) {
          debugPrint('[VaultService] CRITICAL ERROR generating video thumbnail: $e');
          debugPrint('[VaultService] Stack trace: $stackTrace');
          thumbnailData = null; // Ensure null on error
        }
      } else if (type == VaultItemType.audio) {
        // Generate audio waveform or icon thumbnail
        // For now, we'll use a placeholder icon (could generate waveform later)
        thumbnailData = null; // Will use placeholder
      } else if (type == VaultItemType.document) {
        // Generate document preview thumbnail
        // For PDFs, could extract first page as image
        // For now, use placeholder
        thumbnailData = null; // Will use placeholder
      } else {
        // Unknown file type - use placeholder
        thumbnailData = null; // Will use placeholder
      }
      
      if (thumbnailData != null) {
        final thumbnailId = '${fileId}_thumb';
        final thumbnailFileName = '$thumbnailId.jpg';
        final thumbnailFile = File('${_thumbnailsDirectory!.path}/$thumbnailFileName');
        await thumbnailFile.writeAsBytes(thumbnailData);
        final thumbnailRelativePath = 'thumbnails/$thumbnailFileName';
        debugPrint('[VaultService] Generated thumbnail for ${type == VaultItemType.video ? "video" : "file"}: $thumbnailRelativePath (${thumbnailData.length} bytes)');
        // Return relative path for storage in VaultItem
        return thumbnailRelativePath;
      }
      
      // If thumbnail generation failed, return null (UI will show placeholder)
      // No special markers - videos should always have screenshot thumbnails
    } catch (e) {
      debugPrint('[VaultService] Error generating thumbnail: $e');
    }
    
      return null;
    }
  
  /// Update smart albums based on item
  Future<void> _updateSmartAlbums(VaultItem item) async {
    // Smart albums are virtual - items are added based on type/source
    // No need to modify album.itemIds for smart albums
    notifyListeners();
  }
  
  /// Get file path from vault (path-first design - preferred for viewing/playback)
  /// Returns absolute file path, or null if not found
  String? getFilePath(String itemId) {
    if (!_isInitialized) return null;
    
    try {
      final item = _items.firstWhere((i) => i.id == itemId, orElse: () => throw StateError('Item not found'));
      return _resolveVaultFilePathForItem(item);
    } catch (e) {
      debugPrint('[VaultService] Error getting file path for $itemId: $e');
      return null;
    }
  }

  String? _resolveVaultFilePathForItem(VaultItem item) {
    if (_vaultDirectory == null) return null;

    // New format: explicit relative path.
    final rel = item.vaultRelativePath;
    if (rel != null && rel.isNotEmpty) {
      final p = '${_vaultDirectory!.path}/$rel';
      return p;
    }

    // Legacy fallback: items may have been stored as "<id>.<ext>" without persisting vaultRelativePath.
    // Try "<id>" first.
    final noExt = '${_vaultDirectory!.path}/${item.id}';
    if (File(noExt).existsSync()) return noExt;

    // Try original extension (if any).
    final originalExt = item.extension;
    if (originalExt != null && originalExt.isNotEmpty) {
      final withOriginalExt = '${_vaultDirectory!.path}/${item.id}.$originalExt';
      if (File(withOriginalExt).existsSync()) return withOriginalExt;
    }

    // Try a small set of common extensions by type (cheap, avoids directory scan).
    final commonExts = switch (item.type) {
      VaultItemType.video => <String>['mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm'],
      VaultItemType.photo => <String>['jpg', 'jpeg', 'png', 'heic', 'webp', 'gif'],
      VaultItemType.audio => <String>['m4a', 'mp3', 'wav', 'aac', 'ogg', 'flac'],
      VaultItemType.document => <String>['pdf', 'txt', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx'],
      VaultItemType.archive => <String>['zip', 'rar', '7z', 'tar'],
      _ => <String>['bin'],
    };
    for (final ext in commonExts) {
      if (originalExt != null && ext == originalExt) continue;
      final p = '${_vaultDirectory!.path}/${item.id}.$ext';
      if (File(p).existsSync()) return p;
    }

    // Not found.
    return noExt; // best-effort path for callers that want a deterministic value
  }
  
  /// Get thumbnail file path (path-first design)
  /// Returns absolute file path, or null if not found
  String? getThumbnailPath(String itemId) {
    if (!_isInitialized) return null;
    
    try {
      final item = _items.firstWhere((i) => i.id == itemId, orElse: () => throw StateError('Item not found'));
      final thumbnailPath = item.effectiveThumbnailPath;
      if (thumbnailPath == null) return null;
      
      final fullPath = '${_vaultDirectory!.path}/$thumbnailPath';
      return fullPath;
    } catch (e) {
      debugPrint('[VaultService] Error getting thumbnail path for $itemId: $e');
      return null;
    }
  }
  
  /// Get file data from vault (legacy - only for share/export, not for viewing)
  /// For viewing/playback, use getFilePath() instead
  Future<Uint8List?> getFileData(String itemId, {Uint8List? masterKey}) async {
    final startTime = DateTime.now();
    if (!_isInitialized) return null;
    
    final filePath = getFilePath(itemId);
    if (filePath == null) return null;
    
    final file = File(filePath);
    if (!await file.exists()) return null;
    
    final readStart = DateTime.now();
    final data = await file.readAsBytes();
    final readDuration = DateTime.now().difference(readStart);
    debugPrint('[VaultService] Reading file from disk took: ${readDuration.inMilliseconds}ms (${(data.length / 1024 / 1024).toStringAsFixed(2)} MB)');
    
    // Files are stored unencrypted (vault access is still protected by PIN unlock)
    final totalDuration = DateTime.now().difference(startTime);
    debugPrint('[VaultService] getFileData total time: ${totalDuration.inMilliseconds}ms');
    
    return data;
  }
  
  /// Get thumbnail data (for static thumbnails)
  /// Videos now use screenshot thumbnails generated from video frames
  Future<Uint8List?> getThumbnail(String itemId, String? thumbnailId) async {
    if (thumbnailId == null) return null;
    
    // Check memory cache
    if (_thumbnailMemoryCache.containsKey(thumbnailId)) {
      return _thumbnailMemoryCache[thumbnailId];
    }
    
    // Load from vault first (faster than disk cache lookup for local storage)
    try {
      final thumbnailFile = File('${_thumbnailsDirectory!.path}/$thumbnailId.jpg');
      if (await thumbnailFile.exists()) {
        final data = await thumbnailFile.readAsBytes();
        _addToMemoryCache(thumbnailId, data);
        // Store in disk cache asynchronously (don't await - non-blocking)
        // Cache is already initialized, so we can directly store
        _ensureThumbnailCacheInitialized().then((_) {
          _thumbnailCacheService.storeThumbnail(itemId, thumbnailId, data).catchError((e) {
            debugPrint('[VaultService] Error storing thumbnail in cache: $e');
          });
        }).catchError((e) {
          debugPrint('[VaultService] Error ensuring thumbnail cache initialized: $e');
        });
        return data;
      }
      } catch (e) {
      debugPrint('[VaultService] Error loading thumbnail from vault: $e');
    }
    
    // Fallback to disk cache if not found in vault
    try {
      // Ensure cache is initialized (thread-safe, won't re-initialize if already done)
      await _ensureThumbnailCacheInitialized();
      
      final cached = await _thumbnailCacheService.getThumbnail(itemId, thumbnailId);
      if (cached != null) {
        _addToMemoryCache(thumbnailId, cached);
        return cached;
      }
        } catch (e) {
      debugPrint('[VaultService] Error loading thumbnail from cache: $e');
    }
    
    return null;
  }
  
  /// Add thumbnail to memory cache with size limits
  void _addToMemoryCache(String thumbnailId, Uint8List data) {
    // Check if adding this would exceed cache limit
    while (_thumbnailCacheSize + data.length > _maxThumbnailCacheSize && _thumbnailMemoryCache.isNotEmpty) {
      // Remove oldest entry (FIFO)
      final firstKey = _thumbnailMemoryCache.keys.first;
      final removed = _thumbnailMemoryCache.remove(firstKey);
      if (removed != null) {
        _thumbnailCacheSize -= removed.length;
      }
    }
    
    // Add new entry
    _thumbnailMemoryCache[thumbnailId] = data;
    _thumbnailCacheSize += data.length;
  }
  
  /// Get video file path for animated thumbnail (legacy - use getFilePath instead)
  /// Returns the path to the video file if it exists
  /// Files are stored unencrypted, so we can always return the path
  @Deprecated('Use getFilePath() instead')
  Future<String?> getVideoThumbnailPath(String itemId) async {
    // Use the new path-based method
    return getFilePath(itemId);
  }
  
  /// Generate thumbnail for an existing item (on-demand generation)
  /// Useful for items that were added before thumbnail generation was implemented
  /// For encrypted videos, temporarily decrypts to generate thumbnail
  /// [forceRegenerate] - If true, regenerates thumbnail even if one already exists
  Future<String?> generateThumbnailForItem(String itemId, {bool forceRegenerate = false}) async {
    if (!_isInitialized) return null;
    
    final itemIndex = _items.indexWhere((i) => i.id == itemId);
    if (itemIndex == -1) return null;
    
    final item = _items[itemIndex];
    
    // If thumbnail already exists and not forcing regeneration, return it
    final existingThumbnailPath = item.effectiveThumbnailPath;
    if (existingThumbnailPath != null && !forceRegenerate) {
      return existingThumbnailPath;
    }
    
    // If forcing regeneration, delete old thumbnail file
    if (forceRegenerate && existingThumbnailPath != null) {
      try {
        final oldThumbnailFile = File('${_vaultDirectory!.path}/$existingThumbnailPath');
        if (await oldThumbnailFile.exists()) {
          await oldThumbnailFile.delete();
          debugPrint('[VaultService] Deleted old thumbnail file: $existingThumbnailPath');
        }
      } catch (e) {
        debugPrint('[VaultService] Error deleting old thumbnail: $e');
      }
    }
    
    // Get file path (handles legacy "<id>.<ext>" items too)
    final filePath = _resolveVaultFilePathForItem(item);
    if (filePath == null) return null;
    final file = File(filePath);
    if (!await file.exists()) {
      debugPrint('[VaultService] File not found for thumbnail generation: $filePath');
      return null;
    }
    
    // Files are stored unencrypted, so we can directly use the file path
    // Generate thumbnail
    final thumbnailPath = await _enqueueThumbnailGeneration(
      () => _generateThumbnail(itemId, filePath, item.type, null),
    );
    
    if (thumbnailPath != null) {
      // Update item with thumbnail path
      _items[itemIndex] = item.copyWith(thumbnailPath: thumbnailPath);
      _scheduleIndexSave();
      notifyListeners();
      debugPrint('[VaultService] Generated thumbnail on-demand for item: $itemId -> $thumbnailPath');
    }
    
    return thumbnailPath;
  }
  
  /// Delete item from vault
  Future<bool> deleteItem(String itemId) async {
    if (!_isInitialized) return false;
    
    final itemIndex = _items.indexWhere((i) => i.id == itemId);
    if (itemIndex == -1) return false;
    
    final item = _items[itemIndex];
    
    try {
      // Delete file
      final resolvedPath = _resolveVaultFilePathForItem(item);
      if (resolvedPath != null) {
        final file = File(resolvedPath);
        if (await file.exists()) {
          await file.delete();
          debugPrint('[VaultService] Deleted item file: $resolvedPath');
        } else {
          debugPrint('[VaultService] Item file did not exist: $resolvedPath');
        }
      }
      
      // Delete thumbnail file and clear from memory cache
      final thumbRel = item.effectiveThumbnailPath;
      if (thumbRel != null) {
        final thumbnailFile = File('${_vaultDirectory!.path}/$thumbRel');
        if (await thumbnailFile.exists()) {
          await thumbnailFile.delete();
          debugPrint('[VaultService] Deleted thumbnail file: ${thumbnailFile.path}');
        }
      }
      
      // Remove from folders (using copyWith to avoid mutating immutable lists)
      bool foldersChanged = false;
      for (int i = 0; i < _folders.length; i++) {
        if (_folders[i].itemIds.contains(itemId)) {
          final updatedItemIds = List<String>.from(_folders[i].itemIds)..remove(itemId);
          _folders[i] = _folders[i].copyWith(
            itemIds: updatedItemIds,
            dateModified: DateTime.now(),
          );
          foldersChanged = true;
          debugPrint('[VaultService] Removed item from folder: ${_folders[i].name}');
        }
      }
      
      // Remove from albums (using copyWith, skip smart albums)
      bool albumsChanged = false;
      for (int i = 0; i < _albums.length; i++) {
        final album = _albums[i];
        // Skip smart albums - they are virtual and shouldn't be modified
        if (album.id.startsWith('smart_')) {
          continue;
        }
        
        if (album.itemIds.contains(itemId)) {
          final updatedItemIds = List<String>.from(album.itemIds)..remove(itemId);
          _albums[i] = album.copyWith(itemIds: updatedItemIds);
          albumsChanged = true;
          debugPrint('[VaultService] Removed item from album: ${album.name}');
        }
      }
      
      // Remove from items list
      _items.removeAt(itemIndex);
      debugPrint('[VaultService] Removed item from items list: $itemId');
      
      // Persist all changes
      await _saveIndex();
      if (foldersChanged) {
        await _saveFolders();
      }
      if (albumsChanged) {
        await _saveAlbums();
      }
      
      // Notify listeners once at the end
      notifyListeners();
      
      debugPrint('[VaultService] Successfully deleted item: $itemId');
      return true;
    } catch (e, stackTrace) {
      debugPrint('[VaultService] Error deleting item: $e');
      debugPrint('[VaultService] Stack trace: $stackTrace');
      return false;
    }
  }
  
  /// Rename item
  Future<bool> renameItem(String itemId, String newName) async {
    if (!_isInitialized) return false;
    
    final itemIndex = _items.indexWhere((i) => i.id == itemId);
    if (itemIndex == -1) return false;
    
    _items[itemIndex] = _items[itemIndex].copyWith(customName: newName);
    await _saveIndex();
      notifyListeners();
    
      return true;
  }

  /// Scan the vault and delete duplicate items (exact SHA-256 match).
  /// Keeps the earliest-added item by default.
  Future<int> removeDuplicates({
    void Function(int current, int total, String status)? onProgress,
    bool keepOldest = true,
  }) async {
    if (!_isInitialized) return 0;

    final items = List<VaultItem>.from(_items);
    items.sort((a, b) => keepOldest ? a.dateAdded.compareTo(b.dateAdded) : b.dateAdded.compareTo(a.dateAdded));

    final seen = <String, String>{}; // sha256 -> kept itemId
    final toDelete = <String>[];

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      onProgress?.call(i + 1, items.length, 'Checking ${item.displayName}...');

      final digest = await _ensureItemSha256(item);
      if (digest == null) continue;

      final existingKept = seen[digest];
      if (existingKept == null) {
        seen[digest] = item.id;
      } else {
        toDelete.add(item.id);
      }
    }

    int removed = 0;
    for (int i = 0; i < toDelete.length; i++) {
      final id = toDelete[i];
      onProgress?.call(i + 1, toDelete.length, 'Deleting duplicate ${i + 1} / ${toDelete.length}...');
      final ok = await deleteItem(id);
      if (ok) removed++;
    }

    onProgress?.call(removed, removed, 'Removed $removed duplicate(s)');
    return removed;
  }
  
  /// Remove custom name (revert to original)
  Future<bool> removeCustomName(String itemId) async {
    if (!_isInitialized) return false;
    
    final itemIndex = _items.indexWhere((i) => i.id == itemId);
    if (itemIndex == -1) return false;
    
    _items[itemIndex] = _items[itemIndex].copyWith(customName: null);
    await _saveIndex();
    notifyListeners();
    
    return true;
  }
  
  /// Create album
  Future<Album> createAlbum(String name) async {
    if (!_isInitialized) throw StateError('Vault not initialized');
  
      final album = Album(
      id: _generateFileId(),
        name: name,
        createdAt: DateTime.now(),
      );
      
      _albums.add(album);
    await _saveAlbums();
      notifyListeners();
    
      return album;
  }
  
  /// Delete album
  Future<bool> deleteAlbum(String albumId) async {
    if (!_isInitialized) return false;
    
    // Don't delete smart albums
    if (albumId.startsWith('smart_')) return false;
    
    final albumIndex = _albums.indexWhere((a) => a.id == albumId);
    if (albumIndex == -1) return false;
    
    _albums.removeAt(albumIndex);
    await _saveAlbums();
      notifyListeners();
    
      return true;
  }
  
  /// Add item to album
  Future<bool> addItemToAlbum(String itemId, String albumId) async {
    if (!_isInitialized) return false;
    
    final albumIndex = _albums.indexWhere((a) => a.id == albumId);
    if (albumIndex == -1) return false;
    
    if (!_albums[albumIndex].itemIds.contains(itemId)) {
      _albums[albumIndex].itemIds.add(itemId);
      await _saveAlbums();
      notifyListeners();
    }
    
    return true;
  }
  
  /// Remove item from album
  Future<bool> removeItemFromAlbum(String itemId, String albumId) async {
    if (!_isInitialized) return false;
    
    final albumIndex = _albums.indexWhere((a) => a.id == albumId);
    if (albumIndex == -1) return false;
    
    _albums[albumIndex].itemIds.remove(itemId);
    await _saveAlbums();
      notifyListeners();
    
      return true;
  }
  
  /// Get items for smart album
  List<VaultItem> getSmartAlbumItems(String albumId) {
    switch (albumId) {
      case 'smart_photos':
        return _items.where((i) => i.type == VaultItemType.photo).toList()
          ..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      case 'smart_videos':
        return _items.where((i) => i.type == VaultItemType.video).toList()
          ..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      case 'smart_audio':
        return _items.where((i) => i.type == VaultItemType.audio).toList()
          ..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      case 'smart_documents':
        return _items.where((i) => i.type == VaultItemType.document || i.type == VaultItemType.archive).toList()
          ..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      case 'smart_downloads':
        return _items.where((i) => i.source == VaultItemSource.browser).toList()
          ..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      case 'smart_recent':
        return List.from(_items)..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      default:
        return [];
    }
  }
  
  /// Get items in album
  List<VaultItem> getAlbumItems(String albumId) {
    if (albumId.startsWith('smart_')) {
      return getSmartAlbumItems(albumId);
    }
    
    final album = _albums.firstWhere((a) => a.id == albumId, orElse: () => throw StateError('Album not found'));
    
    // Filter out missing items (orphaned references)
    final validItems = <VaultItem>[];
    for (final id in album.itemIds) {
      try {
        final item = _items.firstWhere((i) => i.id == id);
        validItems.add(item);
      } catch (e) {
        // Item doesn't exist - skip it
        debugPrint('[VaultService] Found orphaned item reference in album ${album.name}: $id');
      }
    }
    
    return validItems;
  }
  
  /// Search items
  List<VaultItem> searchItems(String query) {
    final lowerQuery = query.toLowerCase();
    return _items.where((item) {
      return item.displayName.toLowerCase().contains(lowerQuery) ||
          item.originalFilename.toLowerCase().contains(lowerQuery) ||
          (item.sourceSite?.toLowerCase().contains(lowerQuery) ?? false);
    }).toList();
  }
  
  /// Filter items by type
  List<VaultItem> filterByType(VaultItemType? type) {
    if (type == null) return List.from(_items);
    return _items.where((item) => item.type == type).toList();
  }
  
  /// Reload index with master key (for authentication - files are not encrypted)
  Future<void> reloadIndexWithKey(Uint8List? masterKey) async {
    _currentMasterKey = masterKey;
    await _loadIndex();
    notifyListeners();
  }
  
  /// Get vault statistics
  Map<String, dynamic> getStatistics() {
    return {
      'totalItems': _items.length,
      'totalSize': _items.fold<int>(0, (sum, item) => sum + item.sizeBytes),
      'photos': _items.where((i) => i.type == VaultItemType.photo).length,
      'videos': _items.where((i) => i.type == VaultItemType.video).length,
      'audio': _items.where((i) => i.type == VaultItemType.audio).length,
      'documents': _items.where((i) => i.type == VaultItemType.document || i.type == VaultItemType.archive).length,
      'unknown': _items.where((i) => i.type == VaultItemType.unknown).length,
    };
  }
}

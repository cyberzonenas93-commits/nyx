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
import '../models/vault_item.dart';
import '../models/album.dart';
import '../models/vault_folder.dart';
import 'background_execution_service.dart';
import 'encryption_service.dart';
import 'thumbnail_cache_service.dart';
import 'vault_cipher.dart';

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

class _VaultFileCryptoParams {
  final Uint8List masterKey;
  final String fileId;
  final String sourcePath;
  final String destPath;

  const _VaultFileCryptoParams({
    required this.masterKey,
    required this.fileId,
    required this.sourcePath,
    required this.destPath,
  });
}

class _VaultFileCopyParams {
  final String sourcePath;
  final String destPath;

  const _VaultFileCopyParams({
    required this.sourcePath,
    required this.destPath,
  });
}

class _VaultPathImportParams {
  final Uint8List masterKey;
  final String fileId;
  final String sourcePath;
  final String destPath;
  final int idleTimeoutSeconds;
  final bool computeSha256;

  const _VaultPathImportParams({
    required this.masterKey,
    required this.fileId,
    required this.sourcePath,
    required this.destPath,
    required this.idleTimeoutSeconds,
    required this.computeSha256,
  });
}

class _VaultPathImportResult {
  final int bytesCopied;
  final String sha256Digest;

  const _VaultPathImportResult({
    required this.bytesCopied,
    required this.sha256Digest,
  });
}

Future<void> _encryptVaultFileInWorker(_VaultFileCryptoParams params) async {
  final cipher = VaultCipher(EncryptionService());
  await cipher.encryptStreamToFile(
    masterKey: params.masterKey,
    fileId: params.fileId,
    source: File(params.sourcePath),
    dest: File(params.destPath),
    yieldBetweenChunks: true,
  );
}

Future<void> _decryptVaultFileInWorker(_VaultFileCryptoParams params) async {
  final cipher = VaultCipher(EncryptionService());
  await cipher.decryptStreamToFile(
    masterKey: params.masterKey,
    fileId: params.fileId,
    source: File(params.sourcePath),
    dest: File(params.destPath),
  );
}

Future<void> _copyVaultFileInWorker(_VaultFileCopyParams params) async {
  final source = File(params.sourcePath);
  final dest = File(params.destPath);
  final sink = dest.openWrite();
  var chunksCopied = 0;
  try {
    await for (final chunk in source.openRead()) {
      sink.add(chunk);
      chunksCopied++;
      if (chunksCopied % 2 == 0) {
        await sink.flush();
        await Future<void>.delayed(Duration.zero);
      }
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
}

Future<_VaultPathImportResult> _encryptVaultImportInWorker(
    _VaultPathImportParams params) async {
  final cipher = VaultCipher(EncryptionService());
  final sourceFile = File(params.sourcePath);
  final destFile = File(params.destPath);
  final hashSink = params.computeSha256 ? _SingleDigestSink() : null;
  final hashInput =
      hashSink != null ? sha256.startChunkedConversion(hashSink) : null;
  final destSink = destFile.openWrite();
  final encrypter = cipher.beginEncrypt(
    masterKey: params.masterKey,
    fileId: params.fileId,
    dest: destSink,
  );
  final iterator = StreamIterator<List<int>>(sourceFile.openRead());
  var bytesCopied = 0;

  try {
    while (await iterator.moveNext().timeout(
      Duration(seconds: params.idleTimeoutSeconds),
      onTimeout: () {
        throw TimeoutException(
          'File copy stalled (no data received for ${params.idleTimeoutSeconds}s)',
        );
      },
    )) {
      final chunk = iterator.current;
      if (chunk.isEmpty) continue;
      hashInput?.add(chunk);
      encrypter.add(chunk);
      bytesCopied += chunk.length;

      if (bytesCopied % (4 * 1024 * 1024) < chunk.length) {
        await destSink.flush();
        await Future<void>.delayed(Duration.zero);
      }
    }
    encrypter.finalize();
    await destSink.flush();
  } finally {
    await iterator.cancel();
    await destSink.close();
    hashInput?.close();
  }

  return _VaultPathImportResult(
    bytesCopied: bytesCopied,
    sha256Digest: hashSink?.digest?.toString() ?? '',
  );
}

@immutable
class ICloudBackfillResult {
  final int localFilesEncrypted;
  final int cloudFilesWritten;
  final int deletedPlaintextCloudFiles;
  final int skippedMissingLocalFiles;

  const ICloudBackfillResult({
    this.localFilesEncrypted = 0,
    this.cloudFilesWritten = 0,
    this.deletedPlaintextCloudFiles = 0,
    this.skippedMissingLocalFiles = 0,
  });

  bool get changed =>
      localFilesEncrypted > 0 ||
      cloudFilesWritten > 0 ||
      deletedPlaintextCloudFiles > 0;

  @override
  String toString() {
    return 'ICloudBackfillResult('
        'localFilesEncrypted: $localFilesEncrypted, '
        'cloudFilesWritten: $cloudFilesWritten, '
        'deletedPlaintextCloudFiles: $deletedPlaintextCloudFiles, '
        'skippedMissingLocalFiles: $skippedMissingLocalFiles)';
  }
}

@immutable
class ICloudBackfillProgress {
  final int current;
  final int total;
  final String phase;
  final String? filename;

  const ICloudBackfillProgress({
    required this.current,
    required this.total,
    required this.phase,
    this.filename,
  });

  String get statusText {
    final count = total > 0 ? '$current/$total' : '0/0';
    if (filename == null || filename!.isEmpty) {
      return '$phase $count';
    }
    return '$phase $count: $filename';
  }
}

typedef ICloudBackfillProgressCallback = void Function(
  ICloudBackfillProgress progress,
);

/// Comprehensive vault service for managing media storage.
///
/// Vault payloads, index files, and iCloud backup copies must be ciphertext.
/// Temporary decrypted files are created only under the OS temp directory while
/// the vault is unlocked and are cleared on lock.
class VaultService extends ChangeNotifier {
  static const String _kSha256MetadataKey = 'sha256';
  static const String _kTimestampMsMetadataKey = 'timestampMs';
  static const String _kTagsMetadataKey = 'tags';

  final EncryptionService
      _encryptionService; // Used for PIN authentication and file encryption primitives
  final ThumbnailCacheService _thumbnailCacheService;
  final VaultCipher _cipher;
  static const String kEncryptionVersion = 'aes-gcm-v1';
  static const String kEncryptionMetadataKey = 'encryption';

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
  static const int _maxThumbnailCacheSize =
      30 * 1024 * 1024; // Reduced to 30MB for better performance
  int _thumbnailCacheSize = 0;

  File? _foldersFile;

  bool _isInitialized = false;

  /// Set when the on-disk index could not be read. While true, saves are
  /// refused so a partial/empty in-memory list can never overwrite a vault
  /// index that may still be intact on disk.
  bool _indexLoadFailed = false;
  Uint8List? _currentMasterKey;
  String? _currentVaultId; // null = primary vault
  bool?
      _useICloudBackup; // null = auto-detect, true = enable iCloud backup, false = local only
  bool _isSyncingToICloud = false;
  bool _isICloudBackfillRunning = false;
  Future<ICloudBackfillResult>? _activeICloudBackfill;
  Future<void>? _iCloudInitialization;
  int? _iCloudInitializationGeneration;
  Future<void>? _activeICloudSync;
  Timer? _iCloudSyncRetryTimer;
  final Map<String, int> _iCloudSyncRetryAttempts = <String, int>{};
  int _iCloudConfigurationGeneration = 0;
  final Queue<String> _iCloudSyncQueue =
      Queue<String>(); // Queue of file IDs to sync
  Future<int> _encryptionMigrationChain = Future<int>.value(0);

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

  // Decrypted-to-temp file cache. Maps vault item id → live temp file path.
  // Files in this map live in `getTemporaryDirectory()` (not iCloud-backed).
  // Cleared on lock; deleted on dispose.
  final Map<String, String> _decryptedTempPaths = {};
  // Coalesce playback, poster, and metadata requests for the same encrypted
  // item. Without this lock, concurrent cache misses can truncate/write the
  // same temp file while AVFoundation is trying to parse it.
  final Map<String, Future<String?>> _decryptedTempJobs = {};
  Directory? _decryptedTempDir;

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
    if (sha256Digest != null &&
        sha256Digest.isNotEmpty &&
        (merged[_kSha256MetadataKey] == null)) {
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
      return raw
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
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

    final normalized = tagIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
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

  /// Thumbnails are poster frames of the user's private media and live under
  /// Documents, which iCloud/iTunes back up by default — so a recognizable
  /// frame of every vault video would leave the device in a backup even though
  /// the media itself is encrypted at rest. Mark the directory excluded.
  ///
  /// Best-effort and iOS-only; failure must never block vault initialization.
  Future<void> _excludeThumbnailsFromBackup() async {
    if (!Platform.isIOS) return;
    final dir = _thumbnailsDirectory;
    if (dir == null) return;
    try {
      const platform = MethodChannel('com.angelonartey.nyx/icloud');
      final excluded = await platform.invokeMethod<bool>(
        'excludeFromBackup',
        <String, dynamic>{'path': dir.path},
      );
      debugPrint('[VaultService] Thumbnails excluded from backup: $excluded');
    } catch (e) {
      debugPrint('[VaultService] Could not exclude thumbnails from backup: $e');
    }
  }

  Future<String?> _ensureItemSha256(VaultItem item) async {
    final existing = _getItemSha256(item);
    if (existing != null) return existing;

    // Dedup compares against the *plaintext* digest recorded at import time.
    // Hashing an encrypted item's on-disk bytes would digest ciphertext with a
    // random per-chunk nonce — a value that can never match, and which would
    // then be cached into metadata permanently. Leave it null instead.
    if (_isItemEncrypted(item)) return null;

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
    final candidates =
        _items.where((i) => i.sizeBytes == sizeBytes).toList(growable: false);
    for (final candidate in candidates) {
      final hash =
          _getItemSha256(candidate) ?? await _ensureItemSha256(candidate);
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

  List<VaultItem> get items => List.unmodifiable(_items);
  List<Album> get albums => List.unmodifiable(_albums);
  List<VaultFolder> get folders => List.unmodifiable(_folders);
  bool get isInitialized => _isInitialized;
  bool get isICloudBackfillRunning => _isICloudBackfillRunning;
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
    _iCloudConfigurationGeneration++;

    // Initialize iCloud backup directory if enabled or in auto mode.
    if (useICloud != false && Platform.isIOS) {
      unawaited(_initializeICloudBackup());
    } else {
      _iCloudSyncQueue.clear();
      _iCloudSyncRetryAttempts.clear();
      _iCloudSyncRetryTimer?.cancel();
      _iCloudSyncRetryTimer = null;
      _iCloudBackupDirectory = null;
    }

    notifyListeners();
  }

  VaultService(this._encryptionService)
      : _thumbnailCacheService = ThumbnailCacheService(),
        _cipher = VaultCipher(_encryptionService);

  /// Cleanup resources
  @override
  void dispose() {
    _indexSaveTimer?.cancel();
    _indexSaveTimer = null;
    _iCloudSyncRetryTimer?.cancel();
    _iCloudSyncRetryTimer = null;
    // Decrypted plaintext must not outlive the service. Lock paths already
    // clear this, but an app teardown without an explicit lock did not.
    unawaited(clearDecryptedCache());
    super.dispose();
  }

  /// Initialize vault directory structure.
  /// [masterKey] - Master key used for vault file and metadata encryption.
  /// [vaultId] - ID of the vault (null = primary vault)
  /// [forceReinit] - Force reinitialization even if already initialized (for switching vaults)
  Future<void> initialize(
      {Uint8List? masterKey, String? vaultId, bool forceReinit = false}) async {
    if (_isInitialized && !forceReinit) {
      // If already initialized for same vault ID, don't reinitialize
      if (_currentVaultId == vaultId) return;
      // If switching vaults, force reinit
      forceReinit = true;
    }

    // Any outstanding iCloud initialization/sync belongs to the previous
    // vault configuration. Workers check this generation before committing.
    _iCloudConfigurationGeneration++;
    _iCloudSyncQueue.clear();
    _iCloudSyncRetryAttempts.clear();
    _iCloudSyncRetryTimer?.cancel();
    _iCloudSyncRetryTimer = null;
    _iCloudBackupDirectory = null;

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
      debugPrint(
          '[VaultService] Using local documents directory for vault storage (always local-first)');
    } catch (e) {
      debugPrint('[VaultService] Error getting directory: $e');
      rethrow;
    }

    // Defer iCloud backup init to background so vault UI can show sooner
    final doICloudBackup = _useICloudBackup != false && Platform.isIOS;

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

    // Sweep any plaintext left in tmp/ by a session that was killed before it
    // could lock (iOS purges tmp/ eventually, but not promptly).
    unawaited(clearDecryptedCache().catchError((Object e) {
      debugPrint('[VaultService] Startup decrypted-cache sweep failed: $e');
    }));

    unawaited(_excludeThumbnailsFromBackup());

    notifyListeners();

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

  /// Walk every item; if its local payload is not ciphertext, encrypt the
  /// on-disk file in place and update metadata. Returns the number of local
  /// files or metadata rows changed.
  Future<int> _migratePlaintextFilesToEncrypted({
    bool queueICloudSync = true,
  }) async {
    final run = _encryptionMigrationChain.then(
      (_) => _migratePlaintextFilesToEncryptedNow(
        queueICloudSync: queueICloudSync,
      ),
    );
    _encryptionMigrationChain = run.catchError((_) => 0);
    return run;
  }

  Future<int> _migratePlaintextFilesToEncryptedNow({
    required bool queueICloudSync,
  }) async {
    if (_currentMasterKey == null || _vaultDirectory == null) return 0;
    if (_items.isEmpty || _items.every(_isItemEncrypted)) {
      return 0;
    }

    bool anyChanged = false;
    int changedCount = 0;

    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      final path = _resolveVaultFilePathForItem(item);
      if (path == null) continue;
      final src = File(path);
      if (!await src.exists()) continue;

      final alreadyCiphertext = await VaultCipher.looksEncrypted(src);
      if (alreadyCiphertext && _isItemEncrypted(item)) {
        continue;
      }
      if (alreadyCiphertext) {
        // Metadata lagged behind the actual on-disk format.
        _markItemEncrypted(i);
        anyChanged = true;
        changedCount++;
        continue;
      }

      final encrypted = await _encryptLocalItemAtIndex(i);
      if (encrypted) {
        anyChanged = true;
        changedCount++;

        // Re-prime iCloud sync if enabled so the cloud copy is overwritten.
        if (queueICloudSync && _canAttemptAutomaticICloudBackup) {
          if (!_iCloudSyncQueue.contains(item.id)) {
            _iCloudSyncQueue.add(item.id);
          }
        }

        // Yield so UI / playback isn't blocked.
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    if (anyChanged) {
      await _saveIndex();
      notifyListeners();
      // Kick the iCloud sync queue if enabled.
      if (queueICloudSync) {
        queueICloudBackupForItems(
          _items.where(_isItemEncrypted).map((item) => item.id),
        );
      }
    }

    return changedCount;
  }

  /// Exposed for integration tests only. Idempotent; safe to call multiple times.
  @visibleForTesting
  Future<void> runEncryptionMigration() async {
    await _migratePlaintextFilesToEncrypted();
  }

  Future<bool> _encryptLocalItemAtIndex(int index) async {
    if (_currentMasterKey == null || _vaultDirectory == null) return false;
    if (index < 0 || index >= _items.length) return false;

    final item = _items[index];
    final path = _resolveVaultFilePathForItem(item);
    if (path == null) return false;
    final src = File(path);
    if (!await src.exists()) return false;

    final tmp = File('$path.enc.tmp');
    try {
      if (await tmp.exists()) await tmp.delete();
      await _encryptFileOffUiIsolate(
        masterKey: _currentMasterKey!,
        fileId: item.id,
        source: src,
        dest: tmp,
      );
      await tmp.rename(path);
      _markItemEncrypted(index);
      return true;
    } catch (e) {
      debugPrint(
          '[VaultService] Encryption migration failed for ${item.id}: $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return false;
    }
  }

  Future<bool> _ensureLocalItemEncryptedForBackfill(int index) async {
    if (_currentMasterKey == null || _vaultDirectory == null) return false;
    if (index < 0 || index >= _items.length) return false;

    final item = _items[index];
    final path = _resolveVaultFilePathForItem(item);
    if (path == null) return false;
    final src = File(path);
    if (!await src.exists()) return false;

    final alreadyCiphertext = await VaultCipher.looksEncrypted(src);
    if (alreadyCiphertext && _isItemEncrypted(item)) {
      return false;
    }
    if (alreadyCiphertext) {
      _markItemEncrypted(index);
      await _saveIndex();
      notifyListeners();
      return true;
    }

    final encrypted = await _encryptLocalItemAtIndex(index);
    if (encrypted) {
      await _saveIndex();
      notifyListeners();
    }
    return encrypted;
  }

  void _markItemEncrypted(int index) {
    final item = _items[index];
    final meta = Map<String, dynamic>.from(item.metadata ?? const {});
    meta[kEncryptionMetadataKey] = kEncryptionVersion;
    _items[index] = item.copyWith(metadata: meta, isEncrypted: true);
  }

  bool get _automaticICloudBackupRequested => _useICloudBackup != false;

  bool get _canAttemptAutomaticICloudBackup {
    // A test-injected directory represents an available iCloud container on
    // host platforms. Production automatic backup remains iOS-only.
    return _automaticICloudBackupRequested &&
        (Platform.isIOS || _iCloudBackupDirectory != null);
  }

  /// Schedule encrypted payload copies without blocking the caller.
  ///
  /// `null` is the repo's Auto-Detect preference and is eligible whenever the
  /// native iCloud container exists. IDs are retained while container lookup is
  /// in flight, so imports cannot fall through the initialization race.
  void queueICloudBackupForItems(Iterable<String> itemIds) {
    if (!_canAttemptAutomaticICloudBackup) return;

    final knownIds = _items.map((item) => item.id).toSet();
    var added = false;
    for (final itemId in itemIds) {
      if (!knownIds.contains(itemId) || _iCloudSyncQueue.contains(itemId)) {
        continue;
      }
      _iCloudSyncQueue.add(itemId);
      added = true;
    }

    if (!added && _iCloudSyncQueue.isEmpty) return;

    if (_iCloudBackupDirectory == null) {
      unawaited(_initializeICloudBackup().catchError((error) {
        debugPrint('[VaultService] iCloud backup init error: $error');
      }));
      return;
    }

    _iCloudSyncRetryTimer?.cancel();
    _iCloudSyncRetryTimer = null;
    if (!_isSyncingToICloud && !_isICloudBackfillRunning) {
      unawaited(_processICloudSyncQueue());
    }
  }

  /// Initialize the iCloud backup directory once per vault/preference state.
  /// Files are stored locally first, then synced to iCloud in the background.
  Future<void> _initializeICloudBackup() {
    if (!Platform.isIOS || !_automaticICloudBackupRequested) {
      return Future<void>.value();
    }

    if (_iCloudBackupDirectory != null) {
      queueICloudBackupForItems(_items.map((item) => item.id));
      return Future<void>.value();
    }

    final generation = _iCloudConfigurationGeneration;
    final active = _iCloudInitialization;
    if (active != null && _iCloudInitializationGeneration == generation) {
      return active;
    }

    final vaultId = _currentVaultId;
    late final Future<void> run;
    run = _initializeICloudBackupNow(
      generation: generation,
      vaultId: vaultId,
    ).whenComplete(() {
      if (identical(_iCloudInitialization, run)) {
        _iCloudInitialization = null;
        _iCloudInitializationGeneration = null;
      }
    });
    _iCloudInitialization = run;
    _iCloudInitializationGeneration = generation;
    return run;
  }

  Future<void> _initializeICloudBackupNow({
    required int generation,
    required String? vaultId,
  }) async {
    try {
      const platform = MethodChannel('com.angelonartey.nyx/icloud');
      final String? containerPath =
          await platform.invokeMethod('getICloudContainerPath');

      if (generation != _iCloudConfigurationGeneration ||
          vaultId != _currentVaultId ||
          !_automaticICloudBackupRequested) {
        return;
      }

      if (containerPath == null || containerPath.isEmpty) {
        debugPrint(
            '[VaultService] iCloud container not available - backup disabled');
        _iCloudBackupDirectory = null;
        return;
      }

      final vaultName =
          vaultId != null ? 'vault_${vaultId}_backup' : 'vault_backup';
      final backupDir = Directory('$containerPath/$vaultName');
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      if (generation != _iCloudConfigurationGeneration ||
          vaultId != _currentVaultId ||
          !_automaticICloudBackupRequested) {
        return;
      }

      _iCloudBackupDirectory = backupDir;
      debugPrint(
          '[VaultService] iCloud backup directory initialized: ${backupDir.path}');

      // Reconcile the complete index after every successful container lookup.
      // This recovers work lost if the app exited after local commit but before
      // the in-memory queue was populated.
      queueICloudBackupForItems(_items.map((item) => item.id));
    } catch (e) {
      debugPrint('[VaultService] Error initializing iCloud backup: $e');
      if (generation == _iCloudConfigurationGeneration &&
          vaultId == _currentVaultId) {
        _iCloudBackupDirectory = null;
      }
    }
  }

  void _scheduleICloudSyncRetry(int attempt) {
    if (!_automaticICloudBackupRequested || _iCloudSyncRetryTimer != null) {
      return;
    }
    final cappedAttempt = attempt > 5 ? 5 : attempt;
    final delay = Duration(seconds: 5 * (1 << (cappedAttempt - 1)));
    _iCloudSyncRetryTimer = Timer(delay, () {
      _iCloudSyncRetryTimer = null;
      if (_canAttemptAutomaticICloudBackup &&
          _iCloudBackupDirectory != null &&
          !_isSyncingToICloud &&
          !_isICloudBackfillRunning) {
        unawaited(_processICloudSyncQueue());
      }
    });
  }

  /// Process iCloud sync queue in the background, one payload at a time.
  Future<void> _processICloudSyncQueue() async {
    final backupDirectory = _iCloudBackupDirectory;
    if (_isSyncingToICloud ||
        _isICloudBackfillRunning ||
        !_automaticICloudBackupRequested ||
        backupDirectory == null) {
      return;
    }

    final generation = _iCloudConfigurationGeneration;
    _isSyncingToICloud = true;
    final completion = Completer<void>();
    final completionFuture = completion.future;
    _activeICloudSync = completionFuture;

    try {
      while (_iCloudSyncQueue.isNotEmpty) {
        if (generation != _iCloudConfigurationGeneration ||
            !_automaticICloudBackupRequested ||
            _isICloudBackfillRunning ||
            _iCloudBackupDirectory?.path != backupDirectory.path) {
          break;
        }

        final fileId = _iCloudSyncQueue.removeFirst();
        try {
          await _syncFileToICloud(
            fileId,
            backupDirectory: backupDirectory,
            configurationGeneration: generation,
          );
          _iCloudSyncRetryAttempts.remove(fileId);
        } catch (e) {
          debugPrint('[VaultService] Error syncing file $fileId to iCloud: $e');
          if (generation == _iCloudConfigurationGeneration &&
              _automaticICloudBackupRequested &&
              !_iCloudSyncQueue.contains(fileId)) {
            final attempt = (_iCloudSyncRetryAttempts[fileId] ?? 0) + 1;
            _iCloudSyncRetryAttempts[fileId] = attempt;
            _iCloudSyncQueue.addFirst(fileId);
            _scheduleICloudSyncRetry(attempt);
          }
          // Never spin on one failing cloud copy. The timer retries with
          // bounded exponential backoff.
          break;
        }

        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      _isSyncingToICloud = false;
      if (!completion.isCompleted) completion.complete();
      if (identical(_activeICloudSync, completionFuture)) {
        _activeICloudSync = null;
      }

      if (_iCloudSyncQueue.isNotEmpty &&
          _iCloudSyncRetryTimer == null &&
          _automaticICloudBackupRequested &&
          _iCloudBackupDirectory != null &&
          !_isICloudBackfillRunning) {
        unawaited(_processICloudSyncQueue());
      }
    }
  }

  Future<void> _copyFileCooperatively(File source, File dest) async {
    await compute(
      _copyVaultFileInWorker,
      _VaultFileCopyParams(
        sourcePath: source.path,
        destPath: dest.path,
      ),
    );
  }

  Future<void> _encryptFileOffUiIsolate({
    required Uint8List masterKey,
    required String fileId,
    required File source,
    required File dest,
  }) async {
    await compute(
      _encryptVaultFileInWorker,
      _VaultFileCryptoParams(
        masterKey: Uint8List.fromList(masterKey),
        fileId: fileId,
        sourcePath: source.path,
        destPath: dest.path,
      ),
    );
  }

  Future<void> _decryptFileOffUiIsolate({
    required Uint8List masterKey,
    required String fileId,
    required File source,
    required File dest,
  }) async {
    await compute(
      _decryptVaultFileInWorker,
      _VaultFileCryptoParams(
        masterKey: Uint8List.fromList(masterKey),
        fileId: fileId,
        sourcePath: source.path,
        destPath: dest.path,
      ),
    );
  }

  Future<_VaultPathImportResult> _encryptImportOffUiIsolate({
    required Uint8List masterKey,
    required String fileId,
    required File source,
    required File dest,
    required Duration idleTimeout,
    required bool computeSha256,
  }) async {
    return compute(
      _encryptVaultImportInWorker,
      _VaultPathImportParams(
        masterKey: Uint8List.fromList(masterKey),
        fileId: fileId,
        sourcePath: source.path,
        destPath: dest.path,
        idleTimeoutSeconds: idleTimeout.inSeconds,
        computeSha256: computeSha256,
      ),
    );
  }

  /// Sync a single encrypted vault file to iCloud backup.
  ///
  /// The sync target is based on the item's stored vault-relative path, not just
  /// `item.id`, so files imported as `<id>.<ext>` are backed up and backfilled.
  Future<bool> _syncFileToICloud(
    String fileId, {
    Directory? backupDirectory,
    int? configurationGeneration,
  }) async {
    final targetDirectory = backupDirectory ?? _iCloudBackupDirectory;
    if (targetDirectory == null || _vaultDirectory == null) return false;
    if (!_isICloudSyncContextCurrent(
      targetDirectory,
      configurationGeneration,
    )) {
      return false;
    }

    final itemIndex = _items.indexWhere((item) => item.id == fileId);
    if (itemIndex < 0) return false;
    final item = _items[itemIndex];

    final localPath = _resolveVaultFilePathForItem(item);
    if (localPath == null) return false;
    final localFile = File(localPath);
    if (!await localFile.exists()) return false;
    if (!_isICloudSyncContextCurrent(
      targetDirectory,
      configurationGeneration,
    )) {
      return false;
    }

    final localIsEncrypted = await VaultCipher.looksEncrypted(localFile);
    if (!_isICloudSyncContextCurrent(
      targetDirectory,
      configurationGeneration,
    )) {
      return false;
    }
    if (!localIsEncrypted) {
      final encrypted = await _encryptLocalItemAtIndex(itemIndex);
      if (!encrypted || !await VaultCipher.looksEncrypted(localFile)) {
        throw StateError(
            'Refusing to sync plaintext vault file to iCloud: $fileId');
      }
      await _saveIndex();
      if (!_isICloudSyncContextCurrent(
        targetDirectory,
        configurationGeneration,
      )) {
        return false;
      }
    }

    final backupFile = _iCloudBackupFileForItem(
      item,
      localFile,
      backupDirectory: targetDirectory,
    );
    final backupDir = backupFile.parent;
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }

    bool backupIsPlaintext = false;
    if (await backupFile.exists()) {
      backupIsPlaintext = !await VaultCipher.looksEncrypted(backupFile);
      final localModified = await localFile.lastModified();
      final backupModified = await backupFile.lastModified();
      final sameSize = await backupFile.length() == await localFile.length();
      if (!backupIsPlaintext &&
          sameSize &&
          (backupModified.isAfter(localModified) ||
              backupModified.isAtSameMomentAs(localModified))) {
        await _deleteLegacyICloudCopies(
          item,
          localFile,
          backupFile,
          backupDirectory: targetDirectory,
        );
        return false;
      }
    }

    final tmp = File('${backupFile.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
    await _copyFileCooperatively(localFile, tmp);
    if (!_isICloudSyncContextCurrent(
      targetDirectory,
      configurationGeneration,
    )) {
      if (await tmp.exists()) await tmp.delete();
      return false;
    }
    if (await backupFile.exists()) {
      await backupFile.delete();
    }
    await tmp.rename(backupFile.path);
    await _deleteLegacyICloudCopies(
      item,
      localFile,
      backupFile,
      backupDirectory: targetDirectory,
    );
    debugPrint(
      '[VaultService] Synced encrypted file $fileId to iCloud backup'
      '${backupIsPlaintext ? ' (replaced plaintext copy)' : ''}',
    );
    return true;
  }

  bool _isICloudSyncContextCurrent(
    Directory backupDirectory,
    int? configurationGeneration,
  ) {
    if (configurationGeneration == null) return true;
    return configurationGeneration == _iCloudConfigurationGeneration &&
        _automaticICloudBackupRequested &&
        _iCloudBackupDirectory?.path == backupDirectory.path;
  }

  File _iCloudBackupFileForItem(
    VaultItem item,
    File localFile, {
    Directory? backupDirectory,
  }) {
    final rel = item.vaultRelativePath;
    final name = rel != null && rel.isNotEmpty
        ? rel
        : localFile.path.split(Platform.pathSeparator).last;
    final directory = backupDirectory ?? _iCloudBackupDirectory!;
    return File('${directory.path}/$name');
  }

  List<File> _legacyICloudBackupFilesForItem(
    VaultItem item,
    File localFile,
    File canonicalBackupFile, {
    Directory? backupDirectory,
  }) {
    final directory = backupDirectory ?? _iCloudBackupDirectory;
    if (directory == null) return const <File>[];
    final names = <String>{
      item.id,
      item.effectiveVaultPath,
      localFile.path.split(Platform.pathSeparator).last,
    };
    final extension = item.extension;
    if (extension != null && extension.isNotEmpty) {
      names.add('${item.id}.$extension');
    }

    return names
        .map((name) => File('${directory.path}/$name'))
        .where((file) => file.path != canonicalBackupFile.path)
        .toList(growable: false);
  }

  Future<int> _deleteLegacyICloudCopies(
    VaultItem item,
    File localFile,
    File canonicalBackupFile, {
    Directory? backupDirectory,
  }) async {
    if (!await canonicalBackupFile.exists()) return 0;

    int deleted = 0;
    for (final legacyFile in _legacyICloudBackupFilesForItem(
      item,
      localFile,
      canonicalBackupFile,
      backupDirectory: backupDirectory,
    )) {
      try {
        if (await legacyFile.exists()) {
          await legacyFile.delete();
          deleted++;
          debugPrint(
              '[VaultService] Deleted legacy iCloud backup copy: ${legacyFile.path}');
        }
      } catch (e) {
        debugPrint(
            '[VaultService] Could not delete legacy iCloud copy ${legacyFile.path}: $e');
      }
    }
    return deleted;
  }

  Future<File?> _findCloudSourceForMissingLocalItem(
    VaultItem item,
    File localFile,
    File canonicalBackupFile,
  ) async {
    final backupDir = _iCloudBackupDirectory;
    if (backupDir == null || !await backupDir.exists()) return null;

    final highConfidenceNames = <String>{
      item.id,
      item.effectiveVaultPath,
      localFile.path.split(Platform.pathSeparator).last,
      canonicalBackupFile.path.split(Platform.pathSeparator).last,
    };
    final rel = item.vaultRelativePath;
    if (rel != null && rel.isNotEmpty) {
      highConfidenceNames.add(rel);
    }
    final extension = item.extension;
    if (extension != null && extension.isNotEmpty) {
      highConfidenceNames.add('${item.id}.$extension');
    }

    final checked = <String>{};
    for (final name in highConfidenceNames) {
      final candidate = File('${backupDir.path}/$name');
      if (!checked.add(candidate.path)) continue;
      if (await candidate.exists()) return candidate;
    }

    // Very old builds may have copied the original filename into iCloud. Only
    // use that weaker match when the plaintext size matches the vault index.
    final originalName = item.originalFilename;
    if (originalName.isNotEmpty &&
        !originalName.contains('/') &&
        !originalName.contains('\\')) {
      final candidate = File('${backupDir.path}/$originalName');
      if (checked.add(candidate.path) && await candidate.exists()) {
        if (await VaultCipher.looksEncrypted(candidate)) return candidate;
        if (item.sizeBytes <= 0 || await candidate.length() == item.sizeBytes) {
          return candidate;
        }
      }
    }

    return null;
  }

  Future<bool> _restoreMissingLocalItemFromICloudBackfill(int index) async {
    if (_currentMasterKey == null ||
        _vaultDirectory == null ||
        _iCloudBackupDirectory == null) {
      return false;
    }
    if (index < 0 || index >= _items.length) return false;

    final item = _items[index];
    final localPath = _resolveVaultFilePathForItem(item);
    if (localPath == null) return false;
    final localFile = File(localPath);
    if (await localFile.exists()) return false;

    final canonicalBackupFile = _iCloudBackupFileForItem(item, localFile);
    final cloudSource = await _findCloudSourceForMissingLocalItem(
      item,
      localFile,
      canonicalBackupFile,
    );
    if (cloudSource == null || !await cloudSource.exists()) return false;

    final tmp = File('$localPath.icloud-restore.tmp');
    try {
      if (!await localFile.parent.exists()) {
        await localFile.parent.create(recursive: true);
      }
      if (await tmp.exists()) await tmp.delete();

      if (await VaultCipher.looksEncrypted(cloudSource)) {
        await _copyFileCooperatively(cloudSource, tmp);
      } else {
        await _encryptFileOffUiIsolate(
          masterKey: _currentMasterKey!,
          fileId: item.id,
          source: cloudSource,
          dest: tmp,
        );
      }

      if (await localFile.exists()) await localFile.delete();
      await tmp.rename(localPath);
      _markItemEncrypted(index);
      if (item.vaultRelativePath == null || item.vaultRelativePath!.isEmpty) {
        _items[index] = _items[index].copyWith(
          vaultRelativePath: localFile.path.split(Platform.pathSeparator).last,
        );
      }
      await _saveIndex();
      notifyListeners();
      debugPrint(
          '[VaultService] Restored missing local vault file from iCloud backup: ${item.id}');
      return true;
    } catch (e) {
      debugPrint(
          '[VaultService] Could not restore ${item.id} from iCloud backup: $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return false;
    }
  }

  Future<int> _purgeUnknownPlaintextICloudFiles(
      Set<String> canonicalPaths) async {
    final backupDir = _iCloudBackupDirectory;
    if (backupDir == null || !await backupDir.exists()) return 0;

    int deleted = 0;
    int scanned = 0;
    await for (final entity
        in backupDir.list(recursive: true, followLinks: false)) {
      scanned++;
      if (scanned % 10 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      if (entity is! File) continue;
      if (canonicalPaths.contains(entity.path)) continue;

      final shouldDelete = entity.path.endsWith('.tmp') ||
          !await VaultCipher.looksEncrypted(entity);
      if (!shouldDelete) continue;

      try {
        await entity.delete();
        deleted++;
        debugPrint(
            '[VaultService] Deleted plaintext/temporary iCloud vault file: ${entity.path}');
      } catch (e) {
        debugPrint(
            '[VaultService] Could not delete iCloud plaintext file ${entity.path}: $e');
      }
    }
    return deleted;
  }

  void _emitICloudBackfillProgress(
    ICloudBackfillProgressCallback? onProgress,
    BackgroundExecutionService? backgroundExecutionService,
    ICloudBackfillProgress progress,
  ) {
    onProgress?.call(progress);
    if (backgroundExecutionService != null) {
      unawaited(backgroundExecutionService.updateProgress(
        current: progress.current,
        total: progress.total,
        status: progress.statusText,
      ));
    }
  }

  Future<ICloudBackfillResult> _runICloudEncryptionBackfillNow({
    ICloudBackfillProgressCallback? onProgress,
    bool allowBackgroundExecution = false,
    Duration interFileDelay = const Duration(milliseconds: 120),
  }) async {
    if (!_isInitialized) {
      throw StateError('Vault not initialized');
    }
    if (_currentMasterKey == null) {
      throw StateError('Cannot backfill iCloud backups while vault is locked');
    }
    if (_iCloudBackupDirectory == null) {
      return const ICloudBackfillResult();
    }

    final backgroundExecutionService =
        allowBackgroundExecution ? BackgroundExecutionService() : null;
    var backgroundStarted = false;
    if (backgroundExecutionService != null) {
      backgroundStarted =
          await backgroundExecutionService.requestBackgroundExecution(
              reason: 'Backfilling encrypted iCloud backup');
    }

    int cloudFilesWritten = 0;
    int localEncrypted = 0;
    int skippedMissingLocalFiles = 0;
    final canonicalPaths = <String>{};
    final backfillItems = List<VaultItem>.from(_items);
    final total = backfillItems.length;

    try {
      _emitICloudBackfillProgress(
        onProgress,
        backgroundExecutionService,
        ICloudBackfillProgress(
          current: 0,
          total: total,
          phase: 'Preparing iCloud backfill',
        ),
      );

      for (var i = 0; i < backfillItems.length; i++) {
        if (_currentMasterKey == null) {
          throw StateError(
              'Cannot backfill iCloud backups while vault is locked');
        }

        final snapshotItem = backfillItems[i];
        final current = i + 1;
        final itemIndex =
            _items.indexWhere((item) => item.id == snapshotItem.id);
        if (itemIndex < 0) {
          skippedMissingLocalFiles++;
          continue;
        }

        _emitICloudBackfillProgress(
          onProgress,
          backgroundExecutionService,
          ICloudBackfillProgress(
            current: current,
            total: total,
            phase: 'Encrypting',
            filename: _items[itemIndex].displayName,
          ),
        );

        final encrypted = await _ensureLocalItemEncryptedForBackfill(itemIndex);
        if (encrypted) localEncrypted++;

        var item = _items[itemIndex];
        var localPath = _resolveVaultFilePathForItem(item);
        var localFile = localPath != null ? File(localPath) : null;
        if (localFile == null || !await localFile.exists()) {
          _emitICloudBackfillProgress(
            onProgress,
            backgroundExecutionService,
            ICloudBackfillProgress(
              current: current,
              total: total,
              phase: 'Recovering from iCloud',
              filename: item.displayName,
            ),
          );

          final restored =
              await _restoreMissingLocalItemFromICloudBackfill(itemIndex);
          if (restored) localEncrypted++;

          item = _items[itemIndex];
          localPath = _resolveVaultFilePathForItem(item);
          localFile = localPath != null ? File(localPath) : null;
        }

        if (localFile == null || !await localFile.exists()) {
          skippedMissingLocalFiles++;
          await Future<void>.delayed(interFileDelay);
          continue;
        }

        canonicalPaths.add(_iCloudBackupFileForItem(item, localFile).path);

        _emitICloudBackfillProgress(
          onProgress,
          backgroundExecutionService,
          ICloudBackfillProgress(
            current: current,
            total: total,
            phase: 'Syncing',
            filename: item.displayName,
          ),
        );

        final wrote = await _syncFileToICloud(item.id);
        if (wrote) cloudFilesWritten++;

        _emitICloudBackfillProgress(
          onProgress,
          backgroundExecutionService,
          ICloudBackfillProgress(
            current: current,
            total: total,
            phase: 'Backfilled',
            filename: item.displayName,
          ),
        );

        await Future<void>.delayed(interFileDelay);
      }

      _emitICloudBackfillProgress(
        onProgress,
        backgroundExecutionService,
        ICloudBackfillProgress(
          current: total,
          total: total,
          phase: 'Cleaning iCloud backup',
        ),
      );

      final deletedPlaintextCloudFiles =
          await _purgeUnknownPlaintextICloudFiles(canonicalPaths);

      return ICloudBackfillResult(
        localFilesEncrypted: localEncrypted,
        cloudFilesWritten: cloudFilesWritten,
        deletedPlaintextCloudFiles: deletedPlaintextCloudFiles,
        skippedMissingLocalFiles: skippedMissingLocalFiles,
      );
    } finally {
      if (backgroundStarted) {
        await backgroundExecutionService?.endBackgroundExecution();
      }
    }
  }

  /// Encrypt local legacy payloads, overwrite plaintext iCloud backups with
  /// ciphertext, and remove stale plaintext files from the app's iCloud vault
  /// backup directory. This must run while the vault is unlocked because the
  /// master key is intentionally never persisted outside secure storage.
  ///
  /// The backfill is deliberately cooperative: it handles one vault item at a
  /// time, saves progress after each local encryption, yields between files, and
  /// optionally asks the OS for background execution time.
  Future<ICloudBackfillResult> runICloudEncryptionBackfill({
    ICloudBackfillProgressCallback? onProgress,
    bool allowBackgroundExecution = false,
    Duration interFileDelay = const Duration(milliseconds: 120),
  }) {
    final active = _activeICloudBackfill;
    if (active != null) return active;

    _isICloudBackfillRunning = true;
    notifyListeners();

    final run = () async {
      // A manual reconciliation and the automatic queue must never write the
      // same canonical cloud file concurrently. Let any in-flight item finish;
      // the worker stops before taking another item once the backfill flag is
      // set.
      final activeSync = _activeICloudSync;
      if (activeSync != null) await activeSync;
      return _runICloudEncryptionBackfillNow(
        onProgress: onProgress,
        allowBackgroundExecution: allowBackgroundExecution,
        interFileDelay: interFileDelay,
      );
    }();
    _activeICloudBackfill = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_activeICloudBackfill, run)) {
          _activeICloudBackfill = null;
          _isICloudBackfillRunning = false;
          notifyListeners();
          if (_iCloudSyncQueue.isNotEmpty && !_isSyncingToICloud) {
            queueICloudBackupForItems(
              List<String>.from(_iCloudSyncQueue),
            );
          }
        }
      }).then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    return run;
  }

  /// User-triggered iCloud backfill entry point.
  ///
  /// This intentionally does not run from vault initialization because it may
  /// touch every vault item and copy large ciphertext files.
  Future<ICloudBackfillResult> runICloudEncryptionBackfillFromUserAction({
    ICloudBackfillProgressCallback? onProgress,
  }) async {
    if (!_isInitialized) {
      throw StateError('Vault not initialized');
    }
    if (_currentMasterKey == null) {
      throw StateError('Cannot backfill iCloud backups while vault is locked');
    }
    if (!Platform.isIOS) {
      throw StateError('Encrypted iCloud backup is only available on iOS');
    }
    if (_useICloudBackup == false) {
      throw StateError('Encrypted iCloud backup is disabled');
    }

    if (_iCloudBackupDirectory == null) {
      await _initializeICloudBackup();
    }
    if (_iCloudBackupDirectory == null) {
      throw StateError('iCloud container is not available');
    }

    return runICloudEncryptionBackfill(
      onProgress: onProgress,
      allowBackgroundExecution: true,
      interFileDelay: const Duration(milliseconds: 150),
    );
  }

  @visibleForTesting
  Future<void> setICloudBackupDirectoryForTesting(Directory? directory) async {
    _iCloudBackupDirectory = directory;
    if (directory != null && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    if (directory != null) {
      queueICloudBackupForItems(_items.map((item) => item.id));
    }
  }

  @visibleForTesting
  int get pendingICloudBackupCount =>
      _iCloudSyncQueue.length + (_isSyncingToICloud ? 1 : 0);

  @visibleForTesting
  Future<void> waitForICloudSyncIdle({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final initialization = _iCloudInitialization;
      if (initialization != null) await initialization;

      final sync = _activeICloudSync;
      if (sync != null) await sync;

      if (_iCloudInitialization == null &&
          _activeICloudSync == null &&
          !_isSyncingToICloud) {
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Timed out waiting for iCloud backup to idle');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Save index to disk (public method for batch operations)
  /// If [immediate] is true, saves immediately; otherwise uses debounced save
  Future<void> saveIndex({
    bool immediate = false,
    bool throwOnError = false,
  }) async {
    if (immediate) {
      _indexSaveTimer?.cancel();
      _indexSaveTimer = null;
      _indexNeedsSaving = false;
      await _saveIndex(throwOnError: throwOnError);
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
      final raw = await _indexFile!.readAsBytes();
      String content;
      if (raw.isNotEmpty && raw[0] == VaultCipher.versionByte) {
        if (_currentMasterKey == null) {
          debugPrint(
              '[VaultService] Warning: items.json is encrypted but master key is null — skipping load');
          return;
        }
        final decrypted = _cipher.decryptBytes(
          masterKey: _currentMasterKey!,
          fileId: 'index:items',
          onDisk: raw,
        );
        content = utf8.decode(decrypted);
      } else {
        content = utf8.decode(raw);
      }
      final json = jsonDecode(content) as Map<String, dynamic>;
      final itemsJson = json['items'] as List<dynamic>? ?? [];

      // Parse into a local list first, then swap. A malformed entry partway
      // through must not leave _items half-populated.
      final loaded = itemsJson
          .map((item) => VaultItem.fromJson(item as Map<String, dynamic>))
          .toList(growable: false);

      _items
        ..clear()
        ..addAll(loaded);
      _indexLoadFailed = false;

      // Ensure every item has a stable chronological timestamp for UI sorting.
      // (Older vaults may not have this metadata key.)
      final changed = _backfillTimestampMetadataIfMissing();
      if (changed) {
        _scheduleIndexSave();
      }
    } catch (e) {
      // Do NOT clear _items here. A transient decrypt/parse failure used to
      // empty the in-memory list, and the next debounced save then wrote that
      // empty list over items.json — turning a recoverable read error into
      // permanent loss of the whole vault index. Latch instead, and refuse to
      // save until a load succeeds.
      debugPrint('[VaultService] Error loading index (saves blocked): $e');
      _indexLoadFailed = true;
    }
  }

  /// Save vault index to disk (atomic write)
  /// Uses streaming JSON encoding for large indexes to reduce memory usage
  /// Serializes index writes. Concurrent saves previously raced on a single
  /// shared `items.json.tmp`: one writer's rename consumed the other's temp
  /// file, the loser's rename threw, and because the video import path passes
  /// `throwOnError: true` the resulting rollback deleted a freshly-encrypted
  /// payload — a successfully imported video silently un-importing.
  Future<void> _indexSaveChain = Future<void>.value();
  int _indexTempSeq = 0;

  Future<void> _saveIndex({bool throwOnError = false}) {
    final next = _indexSaveChain
        .then((_) => _saveIndexLocked(throwOnError: throwOnError));
    // Keep the chain usable even if this save fails.
    _indexSaveChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _saveIndexLocked({bool throwOnError = false}) async {
    if (_indexFile == null) return;
    if (_indexLoadFailed) {
      const message =
          'Refusing to save: the vault index failed to load, saving now would '
          'overwrite it with incomplete data';
      debugPrint('[VaultService] $message');
      if (throwOnError) throw StateError(message);
      return;
    }

    // Unique per write, so a stray concurrent writer (or a second VaultService
    // over the same directory) can never consume this call's temp file.
    final tempFile = File('${_indexFile!.path}.${_indexTempSeq++}.${pid}.tmp');

    try {
      // For large indexes, build JSON string via string builder then encrypt/write
      if (_items.length > 1000) {
        final sb = StringBuffer();
        sb.write(
            '{"version":1,"lastUpdated":"${DateTime.now().toIso8601String()}","items":[');
        for (int i = 0; i < _items.length; i++) {
          if (i > 0) sb.write(',');
          sb.write(jsonEncode(_items[i].toJson()));
        }
        sb.write(']}');
        final jsonStr = sb.toString();

        if (_currentMasterKey != null) {
          final ciphertext = _cipher.encryptBytes(
            masterKey: _currentMasterKey!,
            fileId: 'index:items',
            plaintext: Uint8List.fromList(utf8.encode(jsonStr)),
          );
          await tempFile.writeAsBytes(ciphertext);
        } else {
          await tempFile.writeAsString(jsonStr);
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

        final jsonStr = jsonEncode(json);

        // Atomic write: write to temp, then rename
        if (_currentMasterKey != null) {
          final ciphertext = _cipher.encryptBytes(
            masterKey: _currentMasterKey!,
            fileId: 'index:items',
            plaintext: Uint8List.fromList(utf8.encode(jsonStr)),
          );
          await tempFile.writeAsBytes(ciphertext);
        } else {
          await tempFile.writeAsString(jsonStr);
        }
        await tempFile.rename(_indexFile!.path);
      }
    } catch (e) {
      debugPrint('[VaultService] Error saving index: $e');
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      if (throwOnError) rethrow;
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
      debugPrint(
          '[VaultService] Created ${_albums.length} default albums (file didn\'t exist)');
      return;
    }

    try {
      final raw = await _albumsFile!.readAsBytes();
      String content;
      if (raw.isNotEmpty && raw[0] == VaultCipher.versionByte) {
        if (_currentMasterKey == null) {
          debugPrint(
              '[VaultService] Warning: albums.json is encrypted but master key is null — skipping load');
          return;
        }
        final decrypted = _cipher.decryptBytes(
          masterKey: _currentMasterKey!,
          fileId: 'index:albums',
          onDisk: raw,
        );
        content = utf8.decode(decrypted);
      } else {
        content = utf8.decode(raw);
      }
      final json = jsonDecode(content) as Map<String, dynamic>;
      final albumsJson = json['albums'] as List<dynamic>? ?? [];

      _albums.clear();
      _albums.addAll(albumsJson
          .map((album) => Album.fromJson(album as Map<String, dynamic>)));

      // Ensure default albums exist
      final hadMissingAlbums =
          _albums.length < 6; // We should have at least 6 smart albums
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
      debugPrint(
          '[VaultService] Created ${_albums.length} default albums after error');
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

      final jsonStr = jsonEncode(json);
      final tempFile = File('${_albumsFile!.path}.tmp');

      if (_currentMasterKey != null) {
        final ciphertext = _cipher.encryptBytes(
          masterKey: _currentMasterKey!,
          fileId: 'index:albums',
          plaintext: Uint8List.fromList(utf8.encode(jsonStr)),
        );
        await tempFile.writeAsBytes(ciphertext);
      } else {
        await tempFile.writeAsString(jsonStr);
      }
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
      final raw = await _foldersFile!.readAsBytes();
      String content;
      if (raw.isNotEmpty && raw[0] == VaultCipher.versionByte) {
        if (_currentMasterKey == null) {
          debugPrint(
              '[VaultService] Warning: folders.json is encrypted but master key is null — skipping load');
          return;
        }
        final decrypted = _cipher.decryptBytes(
          masterKey: _currentMasterKey!,
          fileId: 'index:folders',
          onDisk: raw,
        );
        content = utf8.decode(decrypted);
      } else {
        content = utf8.decode(raw);
      }
      final json = jsonDecode(content) as Map<String, dynamic>;
      final foldersJson = json['folders'] as List<dynamic>? ?? [];

      _folders.clear();
      _folders.addAll(foldersJson.map(
          (folder) => VaultFolder.fromJson(folder as Map<String, dynamic>)));

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

      final jsonStr = jsonEncode(json);
      final tempFile = File('${_foldersFile!.path}.tmp');

      if (_currentMasterKey != null) {
        final ciphertext = _cipher.encryptBytes(
          masterKey: _currentMasterKey!,
          fileId: 'index:folders',
          plaintext: Uint8List.fromList(utf8.encode(jsonStr)),
        );
        await tempFile.writeAsBytes(ciphertext);
      } else {
        await tempFile.writeAsString(jsonStr);
      }
      await tempFile.rename(_foldersFile!.path);
    } catch (e) {
      debugPrint('[VaultService] Error saving folders: $e');
    }
  }

  /// Create a new folder
  Future<VaultFolder> createFolder(String name,
      {String? parentFolderId}) async {
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
      (f) =>
          f.id != folderId && f.name.toLowerCase() == trimmedName.toLowerCase(),
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
      final childFolders =
          _folders.where((f) => f.parentFolderId == folderId).toList();

      // Re-parent child folders to the deleted folder's parent (or null for root)
      for (final childFolder in childFolders) {
        final childIndex = _folders.indexWhere((f) => f.id == childFolder.id);
        if (childIndex != -1) {
          _folders[childIndex] = childFolder.copyWith(
            parentFolderId: parentFolderId,
            dateModified: DateTime.now(),
          );
          debugPrint(
              '[VaultService] Re-parented folder "${childFolder.name}" to ${parentFolderId ?? "root"}');
        }
      }

      // Move items from deleted folder to parent folder (or root if no parent)
      if (folderToDelete.itemIds.isNotEmpty) {
        if (parentFolderId != null) {
          // Move items to parent folder
          final parentIndex =
              _folders.indexWhere((f) => f.id == parentFolderId);
          if (parentIndex != -1) {
            final parentFolder = _folders[parentIndex];
            final updatedItemIds = List<String>.from(parentFolder.itemIds)
              ..addAll(folderToDelete.itemIds);
            _folders[parentIndex] = parentFolder.copyWith(
              itemIds: updatedItemIds,
              dateModified: DateTime.now(),
            );
            debugPrint(
                '[VaultService] Moved ${folderToDelete.itemIds.length} items to parent folder');
          } else {
            // Parent folder not found - items become root items (no folder)
            debugPrint(
                '[VaultService] Warning: Parent folder not found, items removed from folder structure');
          }
        } else {
          // No parent - items become root items (no folder)
          debugPrint(
              '[VaultService] Items from deleted folder are now root items');
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
    final folder = _folders.firstWhere((f) => f.id == folderId,
        orElse: () => throw StateError('Folder not found'));

    // Filter out missing items and collect valid items
    final validItems = <VaultItem>[];
    final orphanedIds = <String>[];
    final itemsById = {for (final item in _items) item.id: item};

    for (final id in folder.itemIds) {
      final item = itemsById[id];
      if (item != null) {
        validItems.add(item);
      } else {
        // Item doesn't exist - mark as orphaned
        orphanedIds.add(id);
        debugPrint(
            '[VaultService] Found orphaned item reference in folder ${folder.name}: $id');
      }
    }

    // Clean up orphaned references if any were found
    if (orphanedIds.isNotEmpty) {
      final updatedItemIds =
          folder.itemIds.where((id) => !orphanedIds.contains(id)).toList();
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
      Album(
          id: 'smart_documents', name: 'Documents', createdAt: DateTime.now()),
      Album(
          id: 'smart_downloads', name: 'Downloads', createdAt: DateTime.now()),
      Album(id: 'smart_recent', name: 'Recent', createdAt: DateTime.now()),
    ]);
  }

  /// Ensure default albums exist
  void _ensureDefaultAlbums() {
    final defaultIds = [
      'smart_photos',
      'smart_videos',
      'smart_audio',
      'smart_documents',
      'smart_downloads',
      'smart_recent'
    ];
    for (final id in defaultIds) {
      if (!_albums.any((a) => a.id == id)) {
        _albums.add(Album(
            id: id, name: _getSmartAlbumName(id), createdAt: DateTime.now()));
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
        final order = {
          'smart_recent': 0,
          'smart_photos': 1,
          'smart_videos': 2,
          'smart_audio': 3,
          'smart_documents': 4,
          'smart_downloads': 5
        };
        return (order[a.id] ?? 99).compareTo(order[b.id] ?? 99);
      }
      // For user albums, sort alphabetically
      return a.name.compareTo(b.name);
    });
  }

  String _getSmartAlbumName(String id) {
    switch (id) {
      case 'smart_photos':
        return 'Photos';
      case 'smart_videos':
        return 'Videos';
      case 'smart_audio':
        return 'Audio';
      case 'smart_documents':
        return 'Documents';
      case 'smart_downloads':
        return 'Downloads';
      case 'smart_recent':
        return 'Recent';
      default:
        return 'Album';
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
      if (mimeType.contains('pdf') ||
          mimeType.contains('document') ||
          mimeType.contains('text')) {
        return VaultItemType.document;
      }
    }

    // Check extension
    final photoExts = [
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'heif',
      'bmp'
    ];
    final videoExts = [
      'mp4',
      'mov',
      'avi',
      'mkv',
      'webm',
      'm4v',
      'flv',
      'wmv',
      '3gp'
    ];
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
      debugPrint(
          '[VaultService] Duplicate detected (storeFile), skipping: $filename -> keep ${duplicate.id}');
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

    // Write file to vault directory, encrypted at rest with AES-256-GCM.
    // Per-file key is derived from the master key + fileId; format is documented
    // in VaultCipher. iCloud sync (when enabled) copies these ciphertext bytes
    // unchanged, so plaintext never leaves the device.
    if (_currentMasterKey == null) {
      throw StateError('Cannot store file: vault master key is not set');
    }
    final filePath = '${_vaultDirectory!.path}/$vaultRelativePath';
    final file = File(filePath);

    final sink = file.openWrite();
    try {
      final encrypter = _cipher.beginEncrypt(
        masterKey: _currentMasterKey!,
        fileId: fileId,
        dest: sink,
      );
      if (data.length > 5 * 1024 * 1024) {
        // Large file: feed in 512 KB pieces and yield periodically to keep
        // the UI responsive and avoid memory spikes during simultaneous video playback.
        const chunkSize = 512 * 1024;
        for (int i = 0; i < data.length; i += chunkSize) {
          final end =
              (i + chunkSize < data.length) ? i + chunkSize : data.length;
          encrypter.add(data.sublist(i, end));
          if (i % (chunkSize * 2) == 0) {
            await sink.flush();
            await Future.delayed(const Duration(milliseconds: 5));
          }
        }
      } else {
        encrypter.add(data);
      }
      encrypter.finalize();
      await sink.flush();
    } finally {
      await sink.close();
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
    mergedMetadata[kEncryptionMetadataKey] = kEncryptionVersion;
    final item = VaultItem(
      id: fileId,
      originalFilename: filename,
      type: fileType,
      mimeType: mimeType,
      sizeBytes: data.length, // plaintext size for UI / dedup
      dateAdded: DateTime.now(),
      source: source,
      sourceUrl: sourceUrl,
      sourceSite: sourceSite,
      thumbnailId: null,
      thumbnailPath: null,
      vaultRelativePath: vaultRelativePath,
      metadata: mergedMetadata,
      isEncrypted: true,
    );

    _items.add(item);

    // Generate thumbnail in background (don't await - let it complete asynchronously)
    // For photos, pass data directly; for videos, use file path
    final thumbnailData = (fileType == VaultItemType.photo) ? data : null;
    final videoThumbnailPath =
        (fileType == VaultItemType.video) ? filePath : null;

    // For videos, always generate thumbnail (even if async)
    // For other types, generate in background
    if (fileType == VaultItemType.video) {
      // Videos MUST have thumbnails - generate immediately but don't block.
      // This runs serialized behind the thumbnail queue to prevent crashes.
      _enqueueThumbnailGeneration(() => _generateThumbnailAsync(
              fileId, videoThumbnailPath ?? filePath, fileType, thumbnailData))
          .then((generatedThumbnailPath) {
        if (generatedThumbnailPath != null) {
          // Update item with thumbnail path
          final itemIndex = _items.indexWhere((i) => i.id == fileId);
          if (itemIndex >= 0) {
            _items[itemIndex] = _items[itemIndex]
                .copyWith(thumbnailPath: generatedThumbnailPath);
            _scheduleIndexSave(); // Use debounced save
            notifyListeners();
            debugPrint(
                '[VaultService] Video thumbnail generated and saved: $fileId -> $generatedThumbnailPath');
          }
        } else {
          debugPrint(
              '[VaultService] WARNING: Video thumbnail generation failed for: $fileId');
        }
      }).catchError((e, stackTrace) {
        debugPrint(
            '[VaultService] Error generating video thumbnail in background: $e');
        debugPrint('[VaultService] Stack trace: $stackTrace');
      });
    } else {
      // For non-videos, generate in background (photos, etc.)
      _enqueueThumbnailGeneration(() => _generateThumbnailAsync(
              fileId, videoThumbnailPath ?? filePath, fileType, thumbnailData))
          .then((generatedThumbnailPath) {
        if (generatedThumbnailPath != null) {
          // Update item with thumbnail path
          final itemIndex = _items.indexWhere((i) => i.id == fileId);
          if (itemIndex >= 0) {
            _items[itemIndex] = _items[itemIndex]
                .copyWith(thumbnailPath: generatedThumbnailPath);
            _scheduleIndexSave(); // Use debounced save
            notifyListeners();
          }
        }
      }).catchError((e) {
        debugPrint(
            '[VaultService] Error generating thumbnail in background: $e');
      });
    }

    // Use debounced index saving - more efficient than saving after each file
    _scheduleIndexSave();

    // Queue the encrypted payload for eligible automatic iCloud backup.
    queueICloudBackupForItems(<String>[fileId]);

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
    bool deduplicate = true,
    bool queueICloudBackup = true,
    bool persistImmediately = false,
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

    // Ciphertext is written to a staging file and only renamed into place once
    // the byte count has been validated. Writing straight to destPath meant a
    // jetsam kill or force-quit mid-import left a truncated payload at the real
    // path — valid-looking ciphertext that decrypts to a broken video.
    final stagingFile = File('$destPath.partial');

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
      debugPrint(
          '[VaultService] Copying file (expected ${(expectedSize / 1024 / 1024).toStringAsFixed(2)} MB): $sourceFilePath -> $destPath');
    } else {
      debugPrint(
          '[VaultService] Copying file (size unknown yet): $sourceFilePath -> $destPath');
    }

    if (_currentMasterKey == null) {
      throw StateError('Cannot store file: vault master key is not set');
    }
    bool copySucceeded = false;
    final idleTimeout = Platform.isIOS
        ? const Duration(seconds: 120)
        : const Duration(seconds: 30);
    var bytesCopied = 0;
    var incomingDigest = '';
    try {
      final result = await _encryptImportOffUiIsolate(
        masterKey: _currentMasterKey!,
        fileId: fileId,
        source: sourceFile,
        dest: stagingFile,
        idleTimeout: idleTimeout,
        computeSha256: deduplicate,
      );
      bytesCopied = result.bytesCopied;
      incomingDigest = result.sha256Digest;

      // The source can be a PhotoManager/iCloud cache file. Refuse to commit
      // ciphertext if that file changed size while it was being streamed;
      // doing so would preserve a validly encrypted but truncated video.
      int? finalSourceSize;
      try {
        finalSourceSize = await sourceFile.length();
      } catch (_) {
        finalSourceSize = null;
      }
      final expectedChanged = expectedSize != null &&
          expectedSize > 0 &&
          bytesCopied != expectedSize;
      final sourceChanged = expectedSize != null &&
          expectedSize > 0 &&
          finalSourceSize != null &&
          finalSourceSize != expectedSize;
      final finalSizeMismatch = finalSourceSize != null &&
          finalSourceSize > 0 &&
          bytesCopied != finalSourceSize;
      if (expectedChanged || sourceChanged || finalSizeMismatch) {
        throw StateError(
          'Source file changed during import: expected $expectedSize bytes, '
          'copied $bytesCopied, final size $finalSourceSize',
        );
      }

      // Size is validated; publish atomically.
      await stagingFile.rename(destPath);

      copySucceeded = true;
      debugPrint(
          '[VaultService] File copy completed: $destPath (${(bytesCopied / 1024 / 1024).toStringAsFixed(2)} MB)');
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
      // If the copy failed, drop the staging file. destFile is only ever
      // created by the rename above, so a failure leaves the vault untouched.
      if (!copySucceeded) {
        try {
          if (await stagingFile.exists()) await stagingFile.delete();
        } catch (_) {
          // Ignore cleanup failures.
        }
      }
    }
    if (incomingDigest.isNotEmpty) {
      final duplicate = await _findDuplicateBySizeAndHash(
        sizeBytes: bytesCopied,
        sha256Digest: incomingDigest,
      );
      if (duplicate != null) {
        debugPrint(
            '[VaultService] Duplicate detected (storeFileFromPath), skipping: $filename -> keep ${duplicate.id}');
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
    mergedMetadata[kEncryptionMetadataKey] = kEncryptionVersion;

    // The thumbnail is generated from the *plaintext source*, while it is still
    // on disk and before the item is registered as encrypted.
    //
    // Two reasons this happens here rather than after the item is added:
    //   1. Every media import path passes queueThumbnailGeneration: false, and
    //      the background backfill service is never enabled — so items used to
    //      end up with no thumbnail at all and rendered as a blank placeholder,
    //      which reads to the user as a failed import.
    //   2. Generating it afterwards would send _generateThumbnail down the
    //      encrypted branch, decrypting the whole file to a temp copy just to
    //      read one frame.
    // _generateThumbnail is fully guarded internally (timeout, size cap, null
    // on any failure), and a missing thumbnail must never fail the import.
    String? initialThumbnailPath;
    try {
      if (fileType == VaultItemType.video || fileType == VaultItemType.audio) {
        // The native extractor takes a path.
        initialThumbnailPath =
            await _generateThumbnail(fileId, sourceFilePath, fileType, null);
      } else if (fileType == VaultItemType.photo) {
        // The image decoder needs bytes. Photos are small enough to read whole;
        // video deliberately never takes this branch.
        final sourceBytes = await sourceFile.readAsBytes();
        initialThumbnailPath = await _generateThumbnail(
            fileId, sourceFilePath, fileType, sourceBytes);
      }
    } catch (e) {
      debugPrint(
          '[VaultService] Thumbnail generation failed for $fileId (import continues): $e');
    }

    final item = VaultItem(
      id: fileId,
      originalFilename: filename,
      type: fileType,
      mimeType: mimeType,
      sizeBytes: bytesCopied, // plaintext byte count for UI / dedup
      dateAdded: DateTime.now(),
      source: source,
      sourceUrl: sourceUrl,
      sourceSite: sourceSite,
      thumbnailPath: initialThumbnailPath,
      vaultRelativePath: vaultRelativePath,
      metadata: mergedMetadata,
      isEncrypted: true,
    );

    _items.add(item);

    // Generate thumbnail in background (use file path, not data).
    // For bulk imports, callers can disable this and explicitly generate thumbnails in a controlled manner.
    if (queueThumbnailGeneration && initialThumbnailPath == null) {
      _enqueueThumbnailGeneration(
              () => _generateThumbnailAsync(fileId, destPath, fileType, null))
          .then((generatedThumbnailPath) {
        if (generatedThumbnailPath != null) {
          final itemIndex = _items.indexWhere((i) => i.id == fileId);
          if (itemIndex >= 0) {
            _items[itemIndex] = _items[itemIndex]
                .copyWith(thumbnailPath: generatedThumbnailPath);
            _scheduleIndexSave();
            notifyListeners();
          }
        }
      }).catchError((e) {
        debugPrint(
            '[VaultService] Error generating thumbnail in background: $e');
      });
    }

    if (persistImmediately) {
      try {
        await saveIndex(immediate: true, throwOnError: true);
      } catch (_) {
        // The source must not be deleted unless both payload and index are
        // durable. Roll back the new payload when the atomic index commit fails.
        _items.removeWhere((candidate) => candidate.id == fileId);
        try {
          if (await destFile.exists()) await destFile.delete();
        } catch (_) {}
        notifyListeners();
        rethrow;
      }
    } else {
      _scheduleIndexSave();
    }

    // Queue for eligible automatic iCloud backup without blocking the import.
    if (queueICloudBackup) {
      queueICloudBackupForItems(<String>[fileId]);
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
  Future<String?> _generateThumbnailAsync(String fileId, String filePath,
      VaultItemType type, Uint8List? originalData) async {
    // Yield to allow UI to update first
    await Future.delayed(const Duration(milliseconds: 50));
    return _generateThumbnail(fileId, filePath, type, originalData);
  }

  /// Generate thumbnail for all file types.
  /// If the source file is encrypted, transparently decrypts to a temp file
  /// first so VideoThumbnail / image decoding sees plaintext.
  Future<String?> _generateThumbnail(String fileId, String filePath,
      VaultItemType type, Uint8List? originalData) async {
    try {
      Uint8List? thumbnailData;

      // If we have an encrypted source and no plaintext bytes, materialize plaintext
      // to a temp file (videos) or read decrypted bytes (photos) before decoding.
      String workingPath = filePath;
      final itemIdx = _items.indexWhere((i) => i.id == fileId);
      final isEncrypted = itemIdx >= 0 && _isItemEncrypted(_items[itemIdx]);
      if (isEncrypted) {
        if (type == VaultItemType.photo && originalData == null) {
          // Decrypt bytes for the image decoder.
          originalData = await getFileData(fileId);
        } else if (type == VaultItemType.video || type == VaultItemType.audio) {
          // VideoThumbnail / AVAsset need a plaintext file path.
          final decrypted = await getDecryptedFilePath(fileId);
          if (decrypted != null) {
            workingPath = decrypted;
          }
        }
      }

      if (type == VaultItemType.photo) {
        // Generate thumbnail from image using compute for heavy processing
        if (originalData != null) {
          try {
            // Use compute to process image in isolate (prevents UI blocking)
            thumbnailData = await compute(_processImageThumbnail, originalData);
          } catch (e) {
            debugPrint(
                '[VaultService] Error processing image thumbnail in isolate: $e');
            // Fallback to main thread if compute fails
            final image = img.decodeImage(originalData);
            if (image != null) {
              final thumbnail = img.copyResize(
                image,
                width: 200,
                height: 200,
                interpolation: img.Interpolation.linear,
              );
              thumbnailData =
                  Uint8List.fromList(img.encodeJpg(thumbnail, quality: 75));
            }
          }
        }
      } else if (type == VaultItemType.video) {
        // Generate video thumbnail screenshot from FIRST FRAME (0ms) - performance requirement
        debugPrint(
            '[VaultService] Generating video thumbnail from first frame (0ms): $workingPath');
        try {
          // Verify file exists before attempting thumbnail generation
          final videoFile = File(workingPath);
          if (!await videoFile.exists()) {
            debugPrint(
                '[VaultService] ERROR: Video file does not exist: $workingPath');
            thumbnailData = null;
          } else {
            final fileSize = await videoFile.length();
            debugPrint(
                '[VaultService] Video file exists, size: $fileSize bytes');

            if (fileSize == 0) {
              debugPrint(
                  '[VaultService] ERROR: Video file is empty: $workingPath');
              thumbnailData = null;
            } else {
              // Anti-crash guard: skip extremely large videos on iOS (native extractor can OOM/crash)
              if (Platform.isIOS && fileSize > 750 * 1024 * 1024) {
                debugPrint(
                    '[VaultService] iOS: skipping thumbnail for huge video (>750MB): $workingPath');
                thumbnailData = null;
              } else {
                // Generate thumbnail at FIRST FRAME (0ms) - requirement for instant poster display
                try {
                  thumbnailData = await VideoThumbnail.thumbnailData(
                    video: workingPath,
                    imageFormat: ImageFormat.JPEG,
                    // Reduce memory pressure on iOS
                    maxWidth: Platform.isIOS ? 240 : 320,
                    quality: Platform.isIOS ? 60 : 75,
                    timeMs: 0, // FIRST FRAME ONLY - no 1-second strategy
                  ).timeout(
                    Platform.isIOS
                        ? const Duration(seconds: 6)
                        : const Duration(seconds: 10),
                    onTimeout: () {
                      debugPrint(
                          '[VaultService] Video thumbnail generation timed out: $workingPath');
                      return null;
                    },
                  );

                  if (thumbnailData != null) {
                    debugPrint(
                        '[VaultService] Successfully generated video thumbnail from first frame: ${thumbnailData.length} bytes');
                  } else {
                    debugPrint(
                        '[VaultService] ERROR: Video thumbnail generation returned null for: $workingPath');
                  }
                } catch (e) {
                  debugPrint(
                      '[VaultService] Error generating video thumbnail from first frame: $e');
                  thumbnailData = null;
                }
              }
            }
          }
        } catch (e, stackTrace) {
          debugPrint(
              '[VaultService] CRITICAL ERROR generating video thumbnail: $e');
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
        final thumbnailFile =
            File('${_thumbnailsDirectory!.path}/$thumbnailFileName');
        await thumbnailFile.writeAsBytes(thumbnailData);
        final thumbnailRelativePath = 'thumbnails/$thumbnailFileName';
        debugPrint(
            '[VaultService] Generated thumbnail for ${type == VaultItemType.video ? "video" : "file"}: $thumbnailRelativePath (${thumbnailData.length} bytes)');
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
      final item = _items.firstWhere((i) => i.id == itemId,
          orElse: () => throw StateError('Item not found'));
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
      final withOriginalExt =
          '${_vaultDirectory!.path}/${item.id}.$originalExt';
      if (File(withOriginalExt).existsSync()) return withOriginalExt;
    }

    // Try a small set of common extensions by type (cheap, avoids directory scan).
    final commonExts = switch (item.type) {
      VaultItemType.video => <String>[
          'mp4',
          'mov',
          'm4v',
          'avi',
          'mkv',
          'webm'
        ],
      VaultItemType.photo => <String>[
          'jpg',
          'jpeg',
          'png',
          'heic',
          'webp',
          'gif'
        ],
      VaultItemType.audio => <String>[
          'm4a',
          'mp3',
          'wav',
          'aac',
          'ogg',
          'flac'
        ],
      VaultItemType.document => <String>[
          'pdf',
          'txt',
          'doc',
          'docx',
          'ppt',
          'pptx',
          'xls',
          'xlsx'
        ],
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

  /// Returns true if the item is stored encrypted on disk.
  bool _isItemEncrypted(VaultItem item) {
    final flag = item.metadata?[kEncryptionMetadataKey];
    return flag == kEncryptionVersion;
  }

  Future<Directory> _getDecryptedTempDir() async {
    if (_decryptedTempDir != null && await _decryptedTempDir!.exists()) {
      return _decryptedTempDir!;
    }
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/nyx_decrypted');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _decryptedTempDir = dir;
    return dir;
  }

  /// Decrypt the on-disk vault file for [itemId] to a temp file (iOS `tmp/`,
  /// not iCloud-backed) and return its absolute path.
  ///
  /// For plaintext (legacy) items this is identical to [getFilePath]. For
  /// encrypted items the decrypted copy is cached for the rest of the unlocked
  /// session and removed by [clearDecryptedCache] (called on lock).
  Future<String?> getDecryptedFilePath(String itemId) async {
    if (!_isInitialized) return null;

    final item = _items.firstWhere(
      (i) => i.id == itemId,
      orElse: () => throw StateError('Item not found: $itemId'),
    );
    final cipherPath = _resolveVaultFilePathForItem(item);
    if (cipherPath == null) return null;
    if (!_isItemEncrypted(item)) {
      // Legacy plaintext file — return as-is.
      if (!await File(cipherPath).exists()) {
        debugPrint(
            '[VaultService] Vault file missing for $itemId at $cipherPath');
        return null;
      }
      return cipherPath;
    }
    if (_currentMasterKey == null) {
      throw StateError('Cannot decrypt: vault is locked');
    }

    // Do not put an await between this lookup and assignment. Dart executes
    // this section synchronously, so every concurrent caller observes the same
    // future instead of starting another isolate against the same destination.
    final activeJob = _decryptedTempJobs[itemId];
    if (activeJob != null) return activeJob;

    final job = _materializeDecryptedFile(
      item: item,
      cipherPath: cipherPath,
      masterKey: Uint8List.fromList(_currentMasterKey!),
    );
    _decryptedTempJobs[itemId] = job;
    try {
      return await job;
    } finally {
      if (identical(_decryptedTempJobs[itemId], job)) {
        _decryptedTempJobs.remove(itemId);
      }
    }
  }

  Future<String?> _materializeDecryptedFile({
    required VaultItem item,
    required String cipherPath,
    required Uint8List masterKey,
  }) async {
    if (!await File(cipherPath).exists()) {
      debugPrint(
          '[VaultService] Vault file missing for ${item.id} at $cipherPath');
      return null;
    }

    final cached = _decryptedTempPaths[item.id];
    if (cached != null) {
      final cachedFile = File(cached);
      if (await _isCompleteDecryptedFile(cachedFile, item)) {
        return cached;
      }

      // A previous failed/racing materialization must never be handed to a
      // native decoder. Remove it and rebuild from authenticated ciphertext.
      _decryptedTempPaths.remove(item.id);
      try {
        if (await cachedFile.exists()) await cachedFile.delete();
      } catch (_) {}
    }

    final tmpDir = await _getDecryptedTempDir();
    final extension = item.extension;
    final tmpName = extension != null && extension.isNotEmpty
        ? '${item.id}.$extension'
        : item.id;
    final tmpPath = '${tmpDir.path}/$tmpName';
    final tmpFile = File(tmpPath);
    final partialFile = File('$tmpPath.partial');

    // Decrypt to a private staging path. AVFoundation can only discover the
    // final path after authentication and length validation have completed.
    for (final stale in <File>[partialFile, tmpFile]) {
      try {
        if (await stale.exists()) await stale.delete();
      } catch (_) {}
    }

    try {
      await _decryptFileOffUiIsolate(
        masterKey: masterKey,
        fileId: item.id,
        source: File(cipherPath),
        dest: partialFile,
      );

      if (!await _isCompleteDecryptedFile(partialFile, item)) {
        final actualSize = await partialFile.length().catchError((_) => -1);
        throw StateError(
          'Decrypted file is incomplete for ${item.id}: '
          'expected ${item.sizeBytes} bytes, got $actualSize',
        );
      }

      await partialFile.rename(tmpPath);
      _decryptedTempPaths[item.id] = tmpPath;
      return tmpPath;
    } catch (_) {
      try {
        if (await partialFile.exists()) await partialFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<bool> _isCompleteDecryptedFile(File file, VaultItem item) async {
    if (!await file.exists()) return false;
    final actualSize = await file.length().catchError((_) => -1);
    if (actualSize < 0) return false;

    // Every encrypted write path records the plaintext byte count. Keep a
    // permissive fallback for migrated legacy rows that lack reliable size
    // metadata, while still rejecting empty media files.
    if (item.sizeBytes > 0) return actualSize == item.sizeBytes;
    return actualSize > 0 || item.sizeBytes == 0;
  }

  /// Delete all decrypted temp files. Call on vault lock.
  Future<void> clearDecryptedCache() async {
    // Let authenticated writes finish (or fail) before removing their output.
    // Otherwise an isolate could recreate plaintext after the lock cleanup.
    final activeJobs = _decryptedTempJobs.values.toSet().toList();
    if (activeJobs.isNotEmpty) {
      await Future.wait<void>(
        activeJobs.map((job) async {
          try {
            await job;
          } catch (_) {}
        }),
      );
    }

    final paths = List<String>.from(_decryptedTempPaths.values);
    _decryptedTempPaths.clear();
    var deletedCount = 0;

    Future<void> deleteFileIfPresent(File file) async {
      try {
        if (await file.exists()) {
          await file.delete();
          deletedCount++;
          if (deletedCount % 10 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }
      } catch (_) {}
    }

    for (final p in paths) {
      await deleteFileIfPresent(File(p));
    }
    if (_decryptedTempDir != null && await _decryptedTempDir!.exists()) {
      try {
        await for (final entity in _decryptedTempDir!.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            await deleteFileIfPresent(entity);
          }
        }
        if (await _decryptedTempDir!.exists()) {
          await _decryptedTempDir!.delete(recursive: true);
        }
      } catch (_) {}
      _decryptedTempDir = null;
    }
  }

  /// Get thumbnail file path (path-first design)
  /// Returns absolute file path, or null if not found
  String? getThumbnailPath(String itemId) {
    if (!_isInitialized) return null;

    try {
      final item = _items.firstWhere((i) => i.id == itemId,
          orElse: () => throw StateError('Item not found'));
      return getThumbnailPathForItem(item);
    } catch (e) {
      debugPrint('[VaultService] Error getting thumbnail path for $itemId: $e');
      return null;
    }
  }

  /// Get thumbnail path when the caller already has the item.
  ///
  /// This avoids an O(n) lookup for every tile during grid/list builds.
  String? getThumbnailPathForItem(VaultItem item) {
    if (!_isInitialized || _vaultDirectory == null) return null;
    final thumbnailPath = item.effectiveThumbnailPath;
    if (thumbnailPath == null) return null;
    return '${_vaultDirectory!.path}/$thumbnailPath';
  }

  /// Read full file contents into memory, decrypting if the item is encrypted.
  /// For large videos use [getDecryptedFilePath] (returns a temp file path) so
  /// the player can stream from disk without holding the file in memory.
  Future<Uint8List?> getFileData(String itemId, {Uint8List? masterKey}) async {
    final startTime = DateTime.now();
    if (!_isInitialized) return null;

    final item = _items.firstWhere(
      (i) => i.id == itemId,
      orElse: () => throw StateError('Item not found: $itemId'),
    );
    final filePath = _resolveVaultFilePathForItem(item);
    if (filePath == null) return null;

    final file = File(filePath);
    if (!await file.exists()) return null;

    final readStart = DateTime.now();
    final raw = await file.readAsBytes();
    final readDuration = DateTime.now().difference(readStart);
    debugPrint(
        '[VaultService] Reading file from disk took: ${readDuration.inMilliseconds}ms (${(raw.length / 1024 / 1024).toStringAsFixed(2)} MB)');

    Uint8List data;
    if (_isItemEncrypted(item)) {
      final effectiveMasterKey = masterKey ?? _currentMasterKey;
      if (effectiveMasterKey == null) {
        debugPrint(
            '[VaultService] getFileData: cannot decrypt, master key unavailable');
        return null;
      }
      data = _cipher.decryptBytes(
        masterKey: effectiveMasterKey,
        fileId: item.id,
        onDisk: raw,
      );
    } else {
      data = raw;
    }

    final totalDuration = DateTime.now().difference(startTime);
    debugPrint(
        '[VaultService] getFileData total time: ${totalDuration.inMilliseconds}ms');
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
      final thumbnailFile =
          File('${_thumbnailsDirectory!.path}/$thumbnailId.jpg');
      if (await thumbnailFile.exists()) {
        final data = await thumbnailFile.readAsBytes();
        _addToMemoryCache(thumbnailId, data);
        // Store in disk cache asynchronously (don't await - non-blocking)
        // Cache is already initialized, so we can directly store
        _ensureThumbnailCacheInitialized().then((_) {
          _thumbnailCacheService
              .storeThumbnail(itemId, thumbnailId, data)
              .catchError((e) {
            debugPrint('[VaultService] Error storing thumbnail in cache: $e');
          });
        }).catchError((e) {
          debugPrint(
              '[VaultService] Error ensuring thumbnail cache initialized: $e');
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

      final cached =
          await _thumbnailCacheService.getThumbnail(itemId, thumbnailId);
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
    while (_thumbnailCacheSize + data.length > _maxThumbnailCacheSize &&
        _thumbnailMemoryCache.isNotEmpty) {
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
  /// May return an encrypted vault path; prefer [getDecryptedFilePath] for playback.
  @Deprecated('Use getFilePath() instead')
  Future<String?> getVideoThumbnailPath(String itemId) async {
    // Use the new path-based method
    return getFilePath(itemId);
  }

  /// Generate thumbnail for an existing item (on-demand generation)
  /// Useful for items that were added before thumbnail generation was implemented
  /// For encrypted videos, temporarily decrypts to generate thumbnail
  /// [forceRegenerate] - If true, regenerates thumbnail even if one already exists
  Future<String?> generateThumbnailForItem(String itemId,
      {bool forceRegenerate = false}) async {
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
        final oldThumbnailFile =
            File('${_vaultDirectory!.path}/$existingThumbnailPath');
        if (await oldThumbnailFile.exists()) {
          await oldThumbnailFile.delete();
          debugPrint(
              '[VaultService] Deleted old thumbnail file: $existingThumbnailPath');
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
      debugPrint(
          '[VaultService] File not found for thumbnail generation: $filePath');
      return null;
    }

    // _generateThumbnail handles encrypted items by materializing a temp copy
    // when a native decoder needs a plaintext path.
    final thumbnailPath = await _enqueueThumbnailGeneration(
      () => _generateThumbnail(itemId, filePath, item.type, null),
    );

    if (thumbnailPath != null) {
      // Update item with thumbnail path
      _items[itemIndex] = item.copyWith(thumbnailPath: thumbnailPath);
      _scheduleIndexSave();
      notifyListeners();
      debugPrint(
          '[VaultService] Generated thumbnail on-demand for item: $itemId -> $thumbnailPath');
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
          debugPrint(
              '[VaultService] Deleted thumbnail file: ${thumbnailFile.path}');
        }
      }

      // Remove from folders (using copyWith to avoid mutating immutable lists)
      bool foldersChanged = false;
      for (int i = 0; i < _folders.length; i++) {
        if (_folders[i].itemIds.contains(itemId)) {
          final updatedItemIds = List<String>.from(_folders[i].itemIds)
            ..remove(itemId);
          _folders[i] = _folders[i].copyWith(
            itemIds: updatedItemIds,
            dateModified: DateTime.now(),
          );
          foldersChanged = true;
          debugPrint(
              '[VaultService] Removed item from folder: ${_folders[i].name}');
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
          final updatedItemIds = List<String>.from(album.itemIds)
            ..remove(itemId);
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
    items.sort((a, b) => keepOldest
        ? a.dateAdded.compareTo(b.dateAdded)
        : b.dateAdded.compareTo(a.dateAdded));

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
      onProgress?.call(i + 1, toDelete.length,
          'Deleting duplicate ${i + 1} / ${toDelete.length}...');
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
        return _items
            .where((i) =>
                i.type == VaultItemType.document ||
                i.type == VaultItemType.archive)
            .toList()
          ..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      case 'smart_downloads':
        return _items.where((i) => i.source == VaultItemSource.browser).toList()
          ..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      case 'smart_recent':
        return List.from(_items)
          ..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      default:
        return [];
    }
  }

  /// Count smart album items without sorting or allocating display lists.
  int getAlbumItemCount(String albumId) {
    if (albumId.startsWith('smart_')) {
      switch (albumId) {
        case 'smart_photos':
          return _items.where((i) => i.type == VaultItemType.photo).length;
        case 'smart_videos':
          return _items.where((i) => i.type == VaultItemType.video).length;
        case 'smart_audio':
          return _items.where((i) => i.type == VaultItemType.audio).length;
        case 'smart_documents':
          return _items
              .where((i) =>
                  i.type == VaultItemType.document ||
                  i.type == VaultItemType.archive)
              .length;
        case 'smart_downloads':
          return _items
              .where((i) => i.source == VaultItemSource.browser)
              .length;
        case 'smart_recent':
          return _items.length;
        default:
          return 0;
      }
    }

    final album = _albums.firstWhere(
      (a) => a.id == albumId,
      orElse: () => Album(id: '', name: '', createdAt: DateTime.now()),
    );
    return album.id.isEmpty ? 0 : album.itemIds.length;
  }

  /// Get items in album
  List<VaultItem> getAlbumItems(String albumId) {
    if (albumId.startsWith('smart_')) {
      return getSmartAlbumItems(albumId);
    }

    final album = _albums.firstWhere((a) => a.id == albumId,
        orElse: () => throw StateError('Album not found'));

    // Filter out missing items (orphaned references)
    final validItems = <VaultItem>[];
    final itemsById = {for (final item in _items) item.id: item};
    for (final id in album.itemIds) {
      final item = itemsById[id];
      if (item != null) {
        validItems.add(item);
      } else {
        // Item doesn't exist - skip it
        debugPrint(
            '[VaultService] Found orphaned item reference in album ${album.name}: $id');
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

  /// Reload encrypted index with the current vault master key.
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
      'documents': _items
          .where((i) =>
              i.type == VaultItemType.document ||
              i.type == VaultItemType.archive)
          .length,
      'unknown': _items.where((i) => i.type == VaultItemType.unknown).length,
    };
  }
}

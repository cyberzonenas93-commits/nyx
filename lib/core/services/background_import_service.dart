import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vault_item.dart';
import 'vault_service.dart';
import 'background_execution_service.dart';
import 'media_playback_manager.dart';

/// Background import service for processing file imports without blocking UI
/// Continues processing even when app is in background
class BackgroundImportService {
  final VaultService _vaultService;
  final Queue<ImportTask> _importQueue = Queue<ImportTask>();
  bool _isProcessing = false;
  StreamController<ImportProgress>? _progressController;
  Completer<void>? _processingCompleter;
  static const String _queueKey = 'background_import_queue';
  static const String _processingKey = 'background_import_processing';

  // Perf + stability: SharedPreferences writes are expensive.
  // Persisting the entire queue after every file turns into O(n²) work for large batches (e.g. 200+ items)
  // and can look like the app is "stuck".
  SharedPreferences? _prefs;
  DateTime _lastPersistAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _sinceLastPersist = 0;
  static const Duration _persistMinInterval = Duration(seconds: 2);
  static const int _persistEveryNItems = 5;
  
  BackgroundImportService(this._vaultService) {
    _progressController = StreamController<ImportProgress>.broadcast();
    _loadPersistedQueue();
  }
  
  /// Stream of import progress updates
  Stream<ImportProgress> get progressStream => _progressController!.stream;
  
  /// Add files to import queue
  Future<void> queueImports(List<ImportTask> tasks) async {
    _importQueue.addAll(tasks);
    await _persistQueue();
    if (!_isProcessing) {
      _startBackgroundProcessing();
    }
  }
  
  /// Start background processing (can continue when app is backgrounded)
  void _startBackgroundProcessing() {
    if (_isProcessing) return;
    
    // Request background execution to keep app active
    final bgService = BackgroundExecutionService();
    bgService.requestBackgroundExecution(reason: 'Importing files to vault');
    
    _processQueue(); // Start processing - this will continue even when backgrounded
  }
  
  Future<SharedPreferences> _getPrefs() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Load persisted queue from storage
  Future<void> _loadPersistedQueue() async {
    try {
      final prefs = await _getPrefs();
      final queueJson = prefs.getString(_queueKey);
      if (queueJson != null) {
        final List<dynamic> tasksJson = jsonDecode(queueJson);
        _importQueue.clear();
        _importQueue.addAll(tasksJson.map((json) => _taskFromJson(json)));
        
        // Check if processing was in progress
        final wasProcessing = prefs.getBool(_processingKey) ?? false;
        if (wasProcessing && _importQueue.isNotEmpty) {
          // Resume processing
          _startBackgroundProcessing();
        }
      }
    } catch (e) {
      debugPrint('[BackgroundImportService] Error loading persisted queue: $e');
    }
  }
  
  /// Persist queue to storage
  Future<void> _persistQueue() async {
    try {
      final prefs = await _getPrefs();
      final tasksJson = _importQueue.map((t) => _taskToJson(t)).toList();
      await prefs.setString(_queueKey, jsonEncode(tasksJson));
      await prefs.setBool(_processingKey, _isProcessing);
      _lastPersistAt = DateTime.now();
      _sinceLastPersist = 0;
    } catch (e) {
      debugPrint('[BackgroundImportService] Error persisting queue: $e');
    }
  }

  Future<void> _persistQueueThrottled({bool force = false}) async {
    if (force) {
      await _persistQueue();
      return;
    }
    _sinceLastPersist++;
    final now = DateTime.now();
    final dueByTime = now.difference(_lastPersistAt) >= _persistMinInterval;
    final dueByCount = _sinceLastPersist >= _persistEveryNItems;
    if (dueByTime || dueByCount || _importQueue.isEmpty) {
      await _persistQueue();
    }
  }
  
  /// Clear persisted queue
  Future<void> _clearPersistedQueue() async {
    try {
      final prefs = await _getPrefs();
      await prefs.remove(_queueKey);
      await prefs.remove(_processingKey);
    } catch (e) {
      debugPrint('[BackgroundImportService] Error clearing persisted queue: $e');
    }
  }
  
  /// Convert ImportTask to JSON
  Map<String, dynamic> _taskToJson(ImportTask task) {
    return {
      'filePath': task.filePath,
      'filename': task.filename,
      'mimeType': task.mimeType,
      'source': task.source.index,
      'metadata': task.metadata,
      'deleteOriginal': task.deleteOriginal,
      'folderId': task.folderId,
    };
  }
  
  /// Convert JSON to ImportTask
  ImportTask _taskFromJson(Map<String, dynamic> json) {
    return ImportTask(
      filePath: json['filePath'] as String,
      filename: json['filename'] as String,
      mimeType: json['mimeType'] as String?,
      source: VaultItemSource.values[json['source'] as int],
      metadata: json['metadata'] as Map<String, dynamic>?,
      deleteOriginal: json['deleteOriginal'] as bool? ?? false,
      folderId: json['folderId'] as String?,
    );
  }
  
  /// Process the import queue in background
  /// Can continue even when app is backgrounded (uses persistent Future)
  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;
    await _persistQueue(); // Force at start
    
    // Start processing without awaiting - allows it to continue when app is backgrounded
    // The Future will continue running even if the app goes to background
    _processQueueInternal().catchError((e) {
      debugPrint('[BackgroundImportService] Error in background processing: $e');
      _isProcessing = false;
    });
  }
  
  /// Internal processing loop that continues even when backgrounded
  Future<void> _processQueueInternal() async {
    int total = _importQueue.length;
    int completed = 0;
    int failed = 0;
    
    while (_importQueue.isNotEmpty) {
      // Check if video is playing - pause imports to prevent memory pressure
      final playbackManager = MediaPlaybackManager();
      final isVideoPlaying = playbackManager.isVideoPlaying;
      
      if (isVideoPlaying) {
        // Video is playing - wait a bit before processing to avoid memory pressure
        debugPrint('[BackgroundImportService] Video playing, pausing imports to prevent memory pressure');
        await Future.delayed(const Duration(milliseconds: 500));
        
        // Check again - if still playing, wait longer
        final stillPlaying = playbackManager.isVideoPlaying;
        if (stillPlaying) {
          // Wait longer and yield to video playback
          await Future.delayed(const Duration(seconds: 1));
          continue; // Skip this iteration, check again next time
        }
      }
      
      final task = _importQueue.removeFirst();
      final lowerName = task.filename.toLowerCase();
      final isVideoTask =
          (task.mimeType?.toLowerCase().startsWith('video/') ?? false) ||
          lowerName.endsWith('.mp4') ||
          lowerName.endsWith('.mov') ||
          lowerName.endsWith('.m4v') ||
          lowerName.endsWith('.avi') ||
          lowerName.endsWith('.mkv') ||
          lowerName.endsWith('.webm');
      
      try {
        // Update progress
        final progress = ImportProgress(
          current: completed + 1,
          total: total,
          status: 'Importing ${task.filename}...',
          isComplete: false,
        );
        _progressController?.add(progress);
        
        // Update background service notification
        BackgroundExecutionService().updateProgress(
          current: completed + 1,
          total: total,
          status: 'Importing ${task.filename}...',
        );
        
        // Process import (waits for iCloud download on iOS if needed)
        await _processImportTask(task, completed + 1, total);
        
        completed++;
        await _persistQueueThrottled(); // Throttled persisted state
        
        // Small delay to prevent overwhelming the system
        // Longer delay for videos and when playback recently occurred to avoid iOS memory spikes.
        final delay = isVideoTask
            ? (Platform.isIOS ? 600 : 250)
            : (isVideoPlaying ? 120 : 25);
        await Future.delayed(Duration(milliseconds: delay));
      } catch (e) {
        debugPrint('[BackgroundImportService] Error importing ${task.filename}: $e');
        failed++;
        await _persistQueueThrottled(); // Update even on failure (throttled)
      }
    }
    
    // Final progress update
    final finalProgress = ImportProgress(
      current: completed,
      total: total,
      status: 'Import complete',
      isComplete: true,
      successCount: completed,
      failCount: failed,
    );
    _progressController?.add(finalProgress);
    
    // End background execution
    BackgroundExecutionService().endBackgroundExecution();
    
    _isProcessing = false;
    // Ensure final state is persisted (then cleared) so we don't resume stale work.
    await _persistQueueThrottled(force: true);
    await _clearPersistedQueue();
  }
  
  /// On iOS, files picked from Photos/Files may be in iCloud and not yet downloaded.
  /// Wait for the file to become available before importing.
  ///
  /// IMPORTANT:
  /// - Checking `length()` is not sufficient for iCloud-only files; it can remain 0 until the file is actually read.
  /// - Probing with a tiny read forces iOS to begin the download.
  /// Emits [onStatus] (e.g. "Downloading from iCloud...") while waiting.
  Future<void> _ensureFileAvailableForImport(
    ImportTask task,
    int current,
    int total, {
    void Function(String status)? onStatus,
  }) async {
    final sourceFile = File(task.filePath);
    if (!Platform.isIOS) {
      if (!await sourceFile.exists()) {
        throw Exception('Source file does not exist: ${task.filePath}');
      }
      return;
    }

    Future<bool> probeReadable() async {
      // Try to read 1 byte with a short timeout. This triggers iCloud download.
      try {
        final stream = sourceFile.openRead(0, 1);
        final firstChunk = await stream.first.timeout(const Duration(seconds: 2));
        return firstChunk.isNotEmpty;
      } on TimeoutException {
        return false;
      } catch (_) {
        return false;
      }
    }

    // iOS: file may be an iCloud placeholder or not yet fully materialized on disk.
    // Use a long wait because multiple large videos may be queued.
    const maxAttempts = 600; // 10 minutes max wait per file
    const waitDuration = Duration(seconds: 1);
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (!await sourceFile.exists()) {
        throw Exception('Source file does not exist: ${task.filePath}');
      }

      // First: try to force-download + verify readability via probe.
      final readable = await probeReadable();
      if (readable) return;

      // Fallback: if length becomes non-zero, treat as ready (some providers update length first).
      try {
        final length = await sourceFile.length();
        if (length > 0) return;
      } catch (e) {
        debugPrint('[BackgroundImportService] File length check failed (attempt ${attempt + 1}): $e');
        // Keep waiting; length() can fail while provider is downloading.
      }

      onStatus?.call('Downloading from iCloud: ${task.filename}...');
      await Future.delayed(waitDuration);
    }
    throw Exception(
      'This file is stored in iCloud and could not be downloaded in time. '
      'Open it in Photos or Files first to download it, then try importing again.',
    );
  }
  
  /// Process a single import task
  /// Uses path-based streaming copy (no memory loading) - performance optimized
  Future<void> _processImportTask(ImportTask task, int current, int total) async {
    void reportStatus(String status) {
      _progressController?.add(ImportProgress(
        current: current,
        total: total,
        status: status,
        isComplete: false,
      ));
      BackgroundExecutionService().updateProgress(
        current: current,
        total: total,
        status: status,
      );
    }
    await _ensureFileAvailableForImport(
      task,
      current,
      total,
      onStatus: reportStatus,
    );
    final sourceFile = File(task.filePath);
    if (!await sourceFile.exists()) {
      throw Exception('Source file does not exist: ${task.filePath}');
    }
    
    // Use path-based storage (streaming copy) - no memory loading
    // This is the default and preferred method for all imports
    final lowerName = task.filename.toLowerCase();
    final isVideoTask =
        (task.mimeType?.toLowerCase().startsWith('video/') ?? false) ||
        lowerName.endsWith('.mp4') ||
        lowerName.endsWith('.mov') ||
        lowerName.endsWith('.m4v') ||
        lowerName.endsWith('.avi') ||
        lowerName.endsWith('.mkv') ||
        lowerName.endsWith('.webm');

    final storedItem = await _vaultService.storeFileFromPath(
      sourceFilePath: task.filePath,
      folderId: task.folderId,
      filename: task.filename,
      mimeType: task.mimeType,
      source: task.source,
      metadata: task.metadata,
      // IMPORTANT: Bulk imports can crash iOS if many video thumbnails generate concurrently.
      // We disable auto thumbnail generation here and generate video posters in a controlled, awaited way below.
      queueThumbnailGeneration: false,
      // Also serialize video metadata extraction (VideoPlayer init) so it doesn't overlap
      // with the next file copy when importing multiple large videos.
      awaitVideoMetadataExtraction: isVideoTask,
    );

    // For videos, generate the first-frame poster before moving to the next file.
    // This avoids overlapping heavy video decoding with the next file copy.
    // Runs serialized (VaultService thumbnail queue) to reduce crash risk.
    if (storedItem.type == VaultItemType.video) {
      reportStatus('Generating video thumbnail: ${task.filename}...');
      try {
        await _vaultService.generateThumbnailForItem(storedItem.id);
      } catch (e) {
        debugPrint('[BackgroundImportService] Error generating video thumbnail for ${task.filename}: $e');
        // Don't fail the import; UI can show a placeholder until user regenerates later.
      }
    }
    
    // Delete original if needed
    if (task.deleteOriginal) {
      try {
        if (await sourceFile.exists()) {
          await sourceFile.delete();
        }
      } catch (e) {
        debugPrint('[BackgroundImportService] Error deleting original file: $e');
      }
    }
  }
  
  /// Cancel all pending imports
  void cancelAll() {
    _importQueue.clear();
    _isProcessing = false;
  }
  
  /// Dispose resources
  void dispose() {
    _progressController?.close();
    _progressController = null;
    _importQueue.clear();
    _processingCompleter?.complete();
    _processingCompleter = null;
  }
  
  /// Resume processing when app comes to foreground
  Future<void> resume() async {
    if (_importQueue.isNotEmpty && !_isProcessing) {
      await _loadPersistedQueue();
      if (_importQueue.isNotEmpty) {
        _startBackgroundProcessing();
      }
    }
  }
}

/// Import task model
class ImportTask {
  final String filePath;
  final String filename;
  final String? mimeType;
  final VaultItemSource source;
  final Map<String, dynamic>? metadata;
  final bool deleteOriginal;
  final String? folderId; // Optional folder ID to store the file in
  
  ImportTask({
    required this.filePath,
    required this.filename,
    this.mimeType,
    required this.source,
    this.metadata,
    this.deleteOriginal = false,
    this.folderId,
  });
}

/// Import progress model
class ImportProgress {
  final int current;
  final int total;
  final String status;
  final bool isComplete;
  final int? successCount;
  final int? failCount;
  
  ImportProgress({
    required this.current,
    required this.total,
    required this.status,
    required this.isComplete,
    this.successCount,
    this.failCount,
  });
}

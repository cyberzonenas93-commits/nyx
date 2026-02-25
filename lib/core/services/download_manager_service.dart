import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'vault_service.dart';
import 'failure_intelligence_service.dart';
import 'media_extraction_engine.dart';
import '../models/vault_item.dart';

/// Download status
enum DownloadStatus {
  pending,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

/// Download task model
class DownloadTask {
  final String id;
  final String url;
  final String filename;
  final String? mimeType;
  final VaultItemSource source;
  final String? sourceSite;
  final Map<String, dynamic>? metadata;
  
  DownloadStatus status;
  int bytesDownloaded;
  int? totalBytes;
  double progress; // 0.0 to 1.0
  String? errorMessage;
  DateTime? startedAt;
  DateTime? completedAt;
  
  // For resumable downloads
  File? tempFile;
  String? tempFilePath;
  
  // Vault item ID when download completes
  String? vaultItemId;
  
  DownloadTask({
    required this.id,
    required this.url,
    required this.filename,
    this.mimeType,
    required this.source,
    this.sourceSite,
    this.metadata,
    this.status = DownloadStatus.pending,
    this.bytesDownloaded = 0,
    this.totalBytes,
    this.progress = 0.0,
    this.errorMessage,
    this.startedAt,
    this.completedAt,
    this.tempFile,
    this.tempFilePath,
    this.vaultItemId,
  });
  
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'url': url,
      'filename': filename,
      'mimeType': mimeType,
      'source': source.toString().split('.').last,
      'sourceSite': sourceSite,
      'metadata': metadata,
      'status': status.toString().split('.').last,
      'bytesDownloaded': bytesDownloaded,
      'totalBytes': totalBytes,
      'progress': progress,
      'errorMessage': errorMessage,
      'startedAt': startedAt?.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'tempFilePath': tempFilePath,
      'vaultItemId': vaultItemId,
    };
  }
  
  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'] as String,
      url: json['url'] as String,
      filename: json['filename'] as String,
      mimeType: json['mimeType'] as String?,
      source: VaultItemSource.values.firstWhere(
        (e) => e.toString().split('.').last == json['source'],
        orElse: () => VaultItemSource.unknown,
      ),
      sourceSite: json['sourceSite'] as String?,
      metadata: json['metadata'] != null 
          ? Map<String, dynamic>.from(json['metadata'] as Map)
          : null,
      status: DownloadStatus.values.firstWhere(
        (e) => e.toString().split('.').last == json['status'],
        orElse: () => DownloadStatus.pending,
      ),
      bytesDownloaded: json['bytesDownloaded'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int?,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      errorMessage: json['errorMessage'] as String?,
      startedAt: json['startedAt'] != null 
          ? DateTime.parse(json['startedAt'] as String)
          : null,
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
      tempFilePath: json['tempFilePath'] as String?,
      vaultItemId: json['vaultItemId'] as String?,
    );
  }
}

/// Desktop-class download manager with pause/resume, retry, and crash recovery
class DownloadManagerService extends ChangeNotifier {
  final VaultService _vaultService;
  final FailureIntelligenceService _failureIntelligence;
  final MediaExtractionEngine? _extractionEngine;
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, StreamSubscription<http.StreamedResponse>> _activeDownloads = {};
  final Map<String, CancelToken> _cancelTokens = {};
  
  Directory? _tempDirectory;
  File? _tasksFile;
  
  bool _isInitialized = false;
  final int _maxConcurrentDownloads = 3;
  
  DownloadManagerService(
    this._vaultService, {
    FailureIntelligenceService? failureIntelligence,
    MediaExtractionEngine? extractionEngine,
  }) : _failureIntelligence = failureIntelligence ?? FailureIntelligenceService(),
       _extractionEngine = extractionEngine {
    // Log extraction engine status
    if (_extractionEngine != null) {
      debugPrint('[DownloadManager] MediaExtractionEngine provided: ${_extractionEngine != null}');
      debugPrint('[DownloadManager] Extraction engine ready: ${_extractionEngine!.isReady}');
    } else {
      debugPrint('[DownloadManager] ⚠️ No MediaExtractionEngine provided');
    }
  }
  
  List<DownloadTask> get tasks => List.unmodifiable(_tasks.values);
  List<DownloadTask> get activeTasks => _tasks.values
      .where((t) => t.status == DownloadStatus.downloading)
      .toList();
  List<DownloadTask> get pendingTasks => _tasks.values
      .where((t) => t.status == DownloadStatus.pending)
      .toList();
  List<DownloadTask> get completedTasks => _tasks.values
      .where((t) => t.status == DownloadStatus.completed)
      .toList();
  List<DownloadTask> get failedTasks => _tasks.values
      .where((t) => t.status == DownloadStatus.failed)
      .toList();
  
  /// Initialize download manager
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    final appDir = await getTemporaryDirectory();
    _tempDirectory = Directory('${appDir.path}/downloads');
    await _tempDirectory!.create(recursive: true);
    
    _tasksFile = File('${_tempDirectory!.path}/tasks.json');
    await _loadTasks();
    
    // Resume incomplete downloads
    await _resumeIncompleteDownloads();
    
    _isInitialized = true;
    notifyListeners();
  }
  
  /// Load tasks from disk
  Future<void> _loadTasks() async {
    if (_tasksFile == null || !await _tasksFile!.exists()) {
      return;
    }
    
    try {
      final content = await _tasksFile!.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final tasksJson = json['tasks'] as List<dynamic>? ?? [];
      
      _tasks.clear();
      for (final taskJson in tasksJson) {
        final task = DownloadTask.fromJson(taskJson as Map<String, dynamic>);
        // Reset status to pending if incomplete
        if (task.status == DownloadStatus.downloading || 
            task.status == DownloadStatus.paused) {
          task.status = DownloadStatus.pending;
        }
        _tasks[task.id] = task;
      }
    } catch (e) {
      debugPrint('[DownloadManager] Error loading tasks: $e');
    }
  }
  
  /// Save tasks to disk
  Future<void> _saveTasks() async {
    if (_tasksFile == null) return;
    
    try {
      final json = {
        'version': 1,
        'lastUpdated': DateTime.now().toIso8601String(),
        'tasks': _tasks.values.map((t) => t.toJson()).toList(),
      };
      await _tasksFile!.writeAsString(jsonEncode(json));
    } catch (e) {
      debugPrint('[DownloadManager] Error saving tasks: $e');
    }
  }
  
  /// Resume incomplete downloads
  Future<void> _resumeIncompleteDownloads() async {
    final incompleteTasks = _tasks.values
        .where((t) => t.status == DownloadStatus.pending && 
                     t.bytesDownloaded > 0)
        .toList();
    
    for (final task in incompleteTasks) {
      _startDownload(task);
    }
  }
  
  /// Add download task
  Future<DownloadTask> addDownload({
    required String url,
    required String filename,
    String? mimeType,
    VaultItemSource source = VaultItemSource.browser,
    String? sourceSite,
    Map<String, dynamic>? metadata,
  }) async {
    final taskId = DateTime.now().millisecondsSinceEpoch.toString();
    final task = DownloadTask(
      id: taskId,
      url: url,
      filename: filename,
      mimeType: mimeType,
      source: source,
      sourceSite: sourceSite,
      metadata: metadata,
    );
    
    _tasks[taskId] = task;
    await _saveTasks();
    notifyListeners();
    
    // Start download if under limit
    if (activeTasks.length < _maxConcurrentDownloads) {
      _startDownload(task);
    }
    
    return task;
  }
  
  /// Start download
  Future<void> _startDownload(DownloadTask task) async {
    if (task.status == DownloadStatus.downloading) return;
    
    task.status = DownloadStatus.downloading;
    task.startedAt = DateTime.now();
    task.errorMessage = null;
    notifyListeners();
    await _saveTasks();
    
    // Verify extraction engine is ready
    if (_extractionEngine != null && !_extractionEngine!.isReady) {
      debugPrint('[DownloadManager] ⚠️ Extraction engine exists but is not ready. Attempting to set download manager...');
      // Try to set it if it's not set (shouldn't happen, but just in case)
      _extractionEngine!.setDownloadManager(this);
    }
    
    try {
      String downloadUrl = task.url;
      StreamType? detectedStreamType;
      
      // Skip extraction for YouTube videos - they already have direct URLs from VideoDetectionService
      final isYouTubeUrl = task.url.contains('googlevideo.com') || 
                          task.url.contains('youtube.com') || 
                          task.url.contains('ytimg.com') ||
                          (task.metadata?['source']?.toString().contains('youtube') ?? false);
      
      // PROACTIVELY use media extractor for ALL media downloads (except YouTube which already has direct URLs)
      if (!isYouTubeUrl && _extractionEngine != null && _extractionEngine!.isReady) {
        try {
          debugPrint('[DownloadManager] ✅ Extraction engine is ready, attempting media extraction for: ${task.url}');
          
          // Detect stream type first
          detectedStreamType = await _extractionEngine!.detectStreamType(task.url);
          debugPrint('[DownloadManager] Detected stream type: $detectedStreamType');
          
          // For adaptive streams (HLS/DASH), use the extraction engine's download method
          if (detectedStreamType == StreamType.hls || detectedStreamType == StreamType.dash) {
            debugPrint('[DownloadManager] Adaptive stream detected, using extraction engine download method');
            
            // Use extraction engine to download adaptive stream
            final success = await _extractionEngine!.downloadAdaptiveStream(
              manifestUrl: task.url,
              filename: task.filename,
              streamType: detectedStreamType,
              source: task.source,
              sourceSite: task.sourceSite,
              metadata: task.metadata,
            );
            
            if (success) {
              debugPrint('[DownloadManager] ✅ Adaptive stream download initiated via extraction engine');
              // Task will be handled by extraction engine, mark as completed
              _tasks.remove(task.id);
              notifyListeners();
              await _saveTasks();
              _startNextPendingDownload();
              return;
            } else {
              debugPrint('[DownloadManager] Adaptive stream download failed, will try direct download');
            }
          }
          
          // For progressive or unknown streams, try extraction to get direct URL
          final extractionResult = await _extractionEngine!.extractMedia(
            task.url,
            title: task.filename,
          );
          
          if (extractionResult.success && extractionResult.streams.isNotEmpty) {
            // Use the best quality stream
            final bestStream = extractionResult.streams.first;
            downloadUrl = bestStream.url;
            debugPrint('[DownloadManager] ✅ Media extraction successful. Using stream: $downloadUrl');
            
            // Note: metadata is final, so we can't update it here
            // The extraction info will be available in the extraction result
          } else {
            debugPrint('[DownloadManager] Media extraction failed or no streams found, using direct download');
            debugPrint('[DownloadManager] Extraction result: success=${extractionResult.success}, error=${extractionResult.error}, streams=${extractionResult.streams.length}');
          }
        } catch (e, stackTrace) {
          debugPrint('[DownloadManager] ❌ Error during media extraction: $e');
          debugPrint('[DownloadManager] Stack trace: $stackTrace');
          debugPrint('[DownloadManager] Falling back to direct download.');
        }
      } else if (isYouTubeUrl) {
        debugPrint('[DownloadManager] ℹ️ YouTube video detected - using direct URL (extraction not needed)');
      } else {
        if (_extractionEngine == null) {
          debugPrint('[DownloadManager] ⚠️ Extraction engine is null, skipping media extraction');
        } else if (!_extractionEngine!.isReady) {
          debugPrint('[DownloadManager] ⚠️ Extraction engine is not ready (download manager not set), skipping media extraction');
          debugPrint('[DownloadManager] Attempting to fix: setting download manager...');
          _extractionEngine!.setDownloadManager(this);
          if (_extractionEngine!.isReady) {
            debugPrint('[DownloadManager] ✅ Fixed! Extraction engine is now ready');
            // Retry extraction
            try {
              final extractionResult = await _extractionEngine!.extractMedia(
                task.url,
                title: task.filename,
              );
              if (extractionResult.success && extractionResult.streams.isNotEmpty) {
                final bestStream = extractionResult.streams.first;
                downloadUrl = bestStream.url;
                debugPrint('[DownloadManager] ✅ Media extraction successful after fix. Using stream: $downloadUrl');
              }
            } catch (e) {
              debugPrint('[DownloadManager] Extraction retry failed: $e');
            }
          }
        }
      }
      
      // Create temp file for download
      if (task.tempFilePath == null) {
        task.tempFilePath = '${_tempDirectory!.path}/${task.id}.tmp';
      }
      task.tempFile = File(task.tempFilePath!);
      
      // Check if resuming
      final resumeFrom = task.bytesDownloaded > 0 && await task.tempFile!.exists()
          ? task.bytesDownloaded
          : 0;
      
      // Create HTTP request with range header for resume
      final request = http.Request('GET', Uri.parse(downloadUrl));
      
      // Add headers for YouTube videos (they require specific headers)
      if (downloadUrl.contains('googlevideo.com') || downloadUrl.contains('youtube.com') || downloadUrl.contains('ytimg.com')) {
        request.headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
        request.headers['Accept'] = '*/*';
        request.headers['Accept-Language'] = 'en-US,en;q=0.9';
        request.headers['Referer'] = 'https://www.youtube.com/';
        request.headers['Origin'] = 'https://www.youtube.com';
        debugPrint('[DownloadManager] Added YouTube-specific headers for download');
      }
      
      if (resumeFrom > 0) {
        request.headers['Range'] = 'bytes=$resumeFrom-';
      }
      
      final client = http.Client();
      
      // YouTube videos may take longer, so use extended timeout
      final timeoutDuration = downloadUrl.contains('googlevideo.com') || downloadUrl.contains('youtube.com')
          ? const Duration(minutes: 60) // Longer timeout for YouTube
          : const Duration(minutes: 30);
      
      debugPrint('[DownloadManager] Starting download with timeout: ${timeoutDuration.inMinutes} minutes');
      final streamedResponse = await client.send(request).timeout(
        timeoutDuration,
        onTimeout: () {
          debugPrint('[DownloadManager] ⚠️ Download timeout after ${timeoutDuration.inMinutes} minutes');
          throw TimeoutException('Download timeout after ${timeoutDuration.inMinutes} minutes');
        },
      );
      
      // Track detected format (since filename and mimeType are final)
      String? detectedMimeType;
      String? detectedFilename;
      
      if (streamedResponse.statusCode == 206 || streamedResponse.statusCode == 200) {
        // Detect actual content type from response headers
        final contentType = streamedResponse.headers['content-type'];
        if (contentType != null && contentType.isNotEmpty) {
          // Update mimeType if we got a different one from the server
          detectedMimeType = contentType.split(';').first.trim();
          if (detectedMimeType.startsWith('video/') && task.mimeType != detectedMimeType) {
            debugPrint('[DownloadManager] Detected actual MIME type: $detectedMimeType (was: ${task.mimeType})');
            
            // Update filename extension to match detected format
            final currentExt = task.filename.split('.').last.toLowerCase();
            String newExt = currentExt;
            
            if (detectedMimeType.contains('webm')) {
              newExt = 'webm';
            } else if (detectedMimeType.contains('quicktime') || detectedMimeType.contains('mov')) {
              newExt = 'mov';
            } else if (detectedMimeType.contains('x-msvideo') || detectedMimeType.contains('avi')) {
              newExt = 'avi';
            } else if (detectedMimeType.contains('matroska') || detectedMimeType.contains('mkv')) {
              newExt = 'mkv';
            } else if (detectedMimeType.contains('mp4')) {
              newExt = 'mp4';
            } else if (detectedMimeType.contains('3gpp') || detectedMimeType.contains('3gp')) {
              newExt = '3gp';
            }
            
            if (newExt != currentExt) {
              final nameWithoutExt = task.filename.substring(0, task.filename.length - currentExt.length - 1);
              detectedFilename = '$nameWithoutExt.$newExt';
              debugPrint('[DownloadManager] Updated filename extension: $detectedFilename');
            }
          }
        }
        
        // Get total size
        final contentLength = streamedResponse.headers['content-length'];
        final contentRange = streamedResponse.headers['content-range'];
        
        if (contentRange != null) {
          // Parse total size from Content-Range header
          final match = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(contentRange);
          if (match != null) {
            task.totalBytes = int.parse(match.group(1)!);
          }
        } else if (contentLength != null) {
          task.totalBytes = int.parse(contentLength) + resumeFrom;
        }
        
        // Open file for writing (append if resuming)
        final file = task.tempFile!;
        final sink = file.openWrite(mode: resumeFrom > 0 ? FileMode.append : FileMode.write);
        
        // Download with progress tracking
        await for (final chunk in streamedResponse.stream) {
          if (task.status == DownloadStatus.cancelled) {
            await sink.close();
            client.close();
            return;
          }
          
          sink.add(chunk);
          task.bytesDownloaded += chunk.length;
          
          if (task.totalBytes != null) {
            task.progress = task.bytesDownloaded / task.totalBytes!;
          }
          
          notifyListeners();
        }
        
        await sink.close();
        client.close();
        
        // Move to vault (pass detected format values)
        await _completeDownload(task, detectedMimeType: detectedMimeType, detectedFilename: detectedFilename);
      } else {
        throw Exception('HTTP ${streamedResponse.statusCode}');
      }
    } catch (e) {
      debugPrint('[DownloadManager] Error downloading ${task.filename}: $e');
      
      // Use failure intelligence to determine recovery strategy
      final failureContext = _failureIntelligence.classifyFailure(e, task.url);
      final strategy = _failureIntelligence.analyzeFailure(failureContext);
      
      // Attempt recovery if strategy is not abort
      if (strategy != RecoveryStrategy.abort && _extractionEngine != null) {
        final recovered = await _failureIntelligence.executeRecovery(
          strategy: strategy,
          url: task.url,
          downloadManager: this,
          extractionEngine: _extractionEngine!,
          filename: task.filename,
          metadata: task.metadata,
        );
        
        if (recovered) {
          // Recovery successful - remove failed task
          _tasks.remove(task.id);
          notifyListeners();
          await _saveTasks();
          return;
        }
      }
      
      // Recovery failed or not attempted
      task.status = DownloadStatus.failed;
      task.errorMessage = e.toString();
      notifyListeners();
      await _saveTasks();
      
      // Start next pending download
      _startNextPendingDownload();
    }
  }
  
  /// Complete download and move to vault
  Future<void> _completeDownload(DownloadTask task, {String? detectedMimeType, String? detectedFilename}) async {
    try {
      debugPrint('[DownloadManager] Completing download: ${task.filename}');
      
      if (task.tempFile == null || !await task.tempFile!.exists()) {
        throw Exception('Temp file not found at ${task.tempFilePath}');
      }
      
      final fileSize = await task.tempFile!.length();
      debugPrint('[DownloadManager] Temp file size: $fileSize bytes');
      
      if (fileSize == 0) {
        throw Exception('Downloaded file is empty');
      }
      
      final fileData = await task.tempFile!.readAsBytes();
      debugPrint('[DownloadManager] Read ${fileData.length} bytes from temp file');
      
      // Detect format from file header as backup (more reliable than HTTP headers)
      if (fileData.length > 12) {
        final fileHeader = fileData.take(12).toList();
        String? headerDetectedFormat;
        String? headerDetectedExt;
        
        // Check for MP4/M4V (ftyp box at offset 4)
        if (fileHeader.length >= 8) {
          final ftyp = String.fromCharCodes(fileHeader.sublist(4, 8));
          if (ftyp == 'ftyp') {
            headerDetectedFormat = 'video/mp4';
            headerDetectedExt = 'mp4';
          }
        }
        
        // Check for WebM/MKV (starts with 1A 45 DF A3)
        if (headerDetectedFormat == null && fileHeader.length >= 4) {
          if (fileHeader[0] == 0x1A && fileHeader[1] == 0x45 && fileHeader[2] == 0xDF && fileHeader[3] == 0xA3) {
            headerDetectedFormat = 'video/webm';
            headerDetectedExt = 'webm';
          }
        }
        
        // Check for FLV
        if (headerDetectedFormat == null && fileHeader.length >= 3) {
          final flv = String.fromCharCodes(fileHeader.sublist(0, 3));
          if (flv == 'FLV') {
            headerDetectedFormat = 'video/x-flv';
            headerDetectedExt = 'flv';
          }
        }
        
        // Check for AVI (RIFF)
        if (headerDetectedFormat == null && fileHeader.length >= 4) {
          final riff = String.fromCharCodes(fileHeader.sublist(0, 4));
          if (riff == 'RIFF') {
            headerDetectedFormat = 'video/x-msvideo';
            headerDetectedExt = 'avi';
          }
        }
        
        // Use file header detection if it found something different
        if (headerDetectedFormat != null) {
          final currentMimeType = detectedMimeType ?? task.mimeType;
          if (headerDetectedFormat != currentMimeType) {
            debugPrint('[DownloadManager] File header detection: $headerDetectedFormat (HTTP header was: $currentMimeType)');
            detectedMimeType = headerDetectedFormat;
            
            if (headerDetectedExt != null) {
              final currentFilename = detectedFilename ?? task.filename;
              final currentExt = currentFilename.split('.').last.toLowerCase();
              if (currentExt != headerDetectedExt) {
                final nameWithoutExt = currentFilename.substring(0, currentFilename.length - currentExt.length - 1);
                detectedFilename = '$nameWithoutExt.$headerDetectedExt';
                debugPrint('[DownloadManager] Updated filename based on file header: $detectedFilename');
              }
            }
          }
        }
      }
      
      // Use detected values or fall back to task values
      final finalFilename = detectedFilename ?? task.filename;
      final finalMimeType = detectedMimeType ?? task.mimeType;
      
      // Store in vault
      debugPrint('[DownloadManager] Storing file in vault: $finalFilename (MIME: $finalMimeType)');
      final vaultItem = await _vaultService.storeFile(
        data: fileData,
        filename: finalFilename,
        mimeType: finalMimeType,
        source: task.source,
        sourceUrl: task.url,
        sourceSite: task.sourceSite,
        metadata: task.metadata,
      );
      
      debugPrint('[DownloadManager] ✅ File stored in vault with ID: ${vaultItem.id}');
      
      // Store vault item ID for navigation
      task.vaultItemId = vaultItem.id;
      
      // Clean up temp file
      try {
        await task.tempFile!.delete();
        debugPrint('[DownloadManager] Temp file deleted');
      } catch (e) {
        debugPrint('[DownloadManager] Warning: Failed to delete temp file: $e');
      }
      task.tempFile = null;
      task.tempFilePath = null;
      
      task.status = DownloadStatus.completed;
      task.completedAt = DateTime.now();
      task.progress = 1.0;
      
      notifyListeners();
      await _saveTasks();
      
      debugPrint('[DownloadManager] ✅ Download completed successfully: ${task.filename}');
      
      // Start next pending download
      _startNextPendingDownload();
    } catch (e, stackTrace) {
      debugPrint('[DownloadManager] ❌ Error completing download: $e');
      debugPrint('[DownloadManager] Stack trace: $stackTrace');
      task.status = DownloadStatus.failed;
      task.errorMessage = e.toString();
      notifyListeners();
      await _saveTasks();
      
      // Start next pending download even on failure
      _startNextPendingDownload();
    }
  }
  
  /// Start next pending download
  void _startNextPendingDownload() {
    if (activeTasks.length >= _maxConcurrentDownloads) return;
    
    if (pendingTasks.isNotEmpty) {
      _startDownload(pendingTasks.first);
    }
  }
  
  /// Pause download
  Future<void> pauseDownload(String taskId) async {
    final task = _tasks[taskId];
    if (task == null || task.status != DownloadStatus.downloading) return;
    
    // Cancel the download stream
    _cancelTokens[taskId]?.cancel();
    _cancelTokens.remove(taskId);
    _activeDownloads[taskId]?.cancel();
    _activeDownloads.remove(taskId);
    
    task.status = DownloadStatus.paused;
    notifyListeners();
    await _saveTasks();
    
    // Start next pending download
    _startNextPendingDownload();
  }
  
  /// Resume download
  Future<void> resumeDownload(String taskId) async {
    final task = _tasks[taskId];
    if (task == null || task.status != DownloadStatus.paused) return;
    
    if (activeTasks.length < _maxConcurrentDownloads) {
      _startDownload(task);
    }
  }
  
  /// Cancel download
  Future<void> cancelDownload(String taskId) async {
    final task = _tasks[taskId];
    if (task == null) return;
    
    // Cancel active download
    _cancelTokens[taskId]?.cancel();
    _cancelTokens.remove(taskId);
    _activeDownloads[taskId]?.cancel();
    _activeDownloads.remove(taskId);
    
    // Delete temp file
    if (task.tempFile != null && await task.tempFile!.exists()) {
      await task.tempFile!.delete();
    }
    
    task.status = DownloadStatus.cancelled;
    _tasks.remove(taskId);
    notifyListeners();
    await _saveTasks();
    
    // Start next pending download
    _startNextPendingDownload();
  }
  
  /// Retry failed download
  Future<void> retryDownload(String taskId) async {
    final task = _tasks[taskId];
    if (task == null || task.status != DownloadStatus.failed) return;
    
    task.status = DownloadStatus.pending;
    task.errorMessage = null;
    task.bytesDownloaded = 0;
    task.progress = 0.0;
    task.tempFile = null;
    task.tempFilePath = null;
    
    notifyListeners();
    await _saveTasks();
    
    if (activeTasks.length < _maxConcurrentDownloads) {
      _startDownload(task);
    }
  }
  
  /// Remove download task from list (for completed/failed/cancelled downloads)
  Future<void> removeDownload(String taskId) async {
    final task = _tasks[taskId];
    if (task == null) return;
    
    // Cancel if still downloading
    if (task.status == DownloadStatus.downloading || task.status == DownloadStatus.pending) {
      await cancelDownload(taskId);
      return;
    }
    
    // Remove from tasks
    _tasks.remove(taskId);
    _cancelTokens.remove(taskId);
    _activeDownloads.remove(taskId);
    
    // Clean up temp file if exists
    if (task.tempFile != null && await task.tempFile!.exists()) {
      try {
        await task.tempFile!.delete();
      } catch (e) {
        debugPrint('[DownloadManager] Error deleting temp file: $e');
      }
    }
    
    notifyListeners();
    await _saveTasks();
  }
  
  /// Get download task by ID
  DownloadTask? getTask(String taskId) {
    return _tasks[taskId];
  }
  
  /// Clear completed downloads
  Future<void> clearCompleted() async {
    final completedIds = completedTasks.map((t) => t.id).toList();
    for (final id in completedIds) {
      _tasks.remove(id);
    }
    notifyListeners();
    await _saveTasks();
  }
}

/// Simple cancel token for download cancellation
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() {
    _cancelled = true;
  }
}

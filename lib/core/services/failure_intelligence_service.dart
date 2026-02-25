import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'download_manager_service.dart';
import 'media_extraction_engine.dart';

/// Failure type classification
enum FailureType {
  networkError,      // Connection issues, timeouts
  httpError,         // 4xx, 5xx responses
  missingAudio,      // Video has no audio track
  avDesync,          // Audio/video synchronization issues
  manifestChurn,     // Manifest changes during download
  bufferStarvation,  // Download stalls
  timestampDrift,    // Segment timestamp issues
  codecError,         // Codec/format problems
  unknown,
}

/// Failure context
class FailureContext {
  final FailureType type;
  final String? errorMessage;
  final int? httpStatusCode;
  final String? url;
  final Map<String, dynamic> metadata;
  
  FailureContext({
    required this.type,
    this.errorMessage,
    this.httpStatusCode,
    this.url,
    Map<String, dynamic>? metadata,
  }) : metadata = metadata ?? {};
  
  Map<String, dynamic> toJson() {
    return {
      'type': type.toString().split('.').last,
      'errorMessage': errorMessage,
      'httpStatusCode': httpStatusCode,
      'url': url,
      'metadata': metadata,
    };
  }
  
  factory FailureContext.fromJson(Map<String, dynamic> json) {
    return FailureContext(
      type: FailureType.values.firstWhere(
        (e) => e.toString().split('.').last == json['type'],
        orElse: () => FailureType.unknown,
      ),
      errorMessage: json['errorMessage'] as String?,
      httpStatusCode: json['httpStatusCode'] as int?,
      url: json['url'] as String?,
      metadata: json['metadata'] != null 
          ? Map<String, dynamic>.from(json['metadata'] as Map)
          : null,
    );
  }
}

/// Failure recovery strategy
enum RecoveryStrategy {
  retrySegment,        // Retry with pacing
  switchBitrate,       // Switch to different quality
  switchCodec,         // Try different codec
  switchCDN,           // Try different CDN endpoint
  reparseManifest,     // Re-parse and remap tracks
  pivotToProgressive,  // Try progressive if adaptive fails
  reattachMSE,         // Reattach MediaSource buffers
  remuxTracks,         // Isolate and remux audio/video
  restartCapture,      // Restart from beginning
  abort,               // Give up with diagnostics
}

/// Adaptive failure-mode intelligence service
/// Implements self-healing failure detection and escalation
class FailureIntelligenceService {
  final Map<String, List<FailureContext>> _failureHistory = {};
  final Map<String, int> _retryCounts = {};
  final Map<String, RecoveryStrategy> _currentStrategies = {};
  
  static const int maxRetriesPerStrategy = 3;
  static const int maxTotalRetries = 10;
  
  /// Analyze failure and determine recovery strategy
  RecoveryStrategy analyzeFailure(FailureContext context) {
    // Record failure
    final key = context.url ?? 'unknown';
    _failureHistory.putIfAbsent(key, () => []).add(context);
    
    // Determine strategy based on failure type
    switch (context.type) {
      case FailureType.networkError:
        return _handleNetworkError(key);
      case FailureType.httpError:
        return _handleHttpError(context, key);
      case FailureType.missingAudio:
        return RecoveryStrategy.remuxTracks;
      case FailureType.avDesync:
        return RecoveryStrategy.remuxTracks;
      case FailureType.manifestChurn:
        return RecoveryStrategy.reparseManifest;
      case FailureType.bufferStarvation:
        return RecoveryStrategy.retrySegment;
      case FailureType.timestampDrift:
        return RecoveryStrategy.remuxTracks;
      case FailureType.codecError:
        return RecoveryStrategy.switchCodec;
      default:
        return RecoveryStrategy.retrySegment;
    }
  }
  
  /// Handle network errors
  RecoveryStrategy _handleNetworkError(String key) {
    final retryCount = _retryCounts[key] ?? 0;
    
    if (retryCount < 2) {
      return RecoveryStrategy.retrySegment;
    } else if (retryCount < 4) {
      return RecoveryStrategy.switchCDN;
    } else {
      return RecoveryStrategy.abort;
    }
  }
  
  /// Handle HTTP errors
  RecoveryStrategy _handleHttpError(FailureContext context, String key) {
    final statusCode = context.httpStatusCode ?? 0;
    final retryCount = _retryCounts[key] ?? 0;
    
    if (statusCode == 404) {
      return RecoveryStrategy.switchBitrate;
    } else if (statusCode == 403 || statusCode == 401) {
      return RecoveryStrategy.switchCDN;
    } else if (statusCode >= 500) {
      if (retryCount < 3) {
        return RecoveryStrategy.retrySegment;
      } else {
        return RecoveryStrategy.switchCDN;
      }
    } else if (statusCode == 429) {
      // Rate limited - wait and retry
      return RecoveryStrategy.retrySegment;
    }
    
    return RecoveryStrategy.abort;
  }
  
  /// Execute recovery strategy
  Future<bool> executeRecovery({
    required RecoveryStrategy strategy,
    required String url,
    required DownloadManagerService downloadManager,
    required MediaExtractionEngine extractionEngine,
    String? filename,
    Map<String, dynamic>? metadata,
  }) async {
    final key = url;
    _retryCounts[key] = (_retryCounts[key] ?? 0) + 1;
    
    if (_retryCounts[key]! > maxTotalRetries) {
      debugPrint('[FailureIntelligence] Max retries exceeded for $url');
      return false;
    }
    
    try {
      switch (strategy) {
        case RecoveryStrategy.retrySegment:
          return await _retryWithPacing(url, downloadManager, filename, metadata);
          
        case RecoveryStrategy.switchBitrate:
          return await _switchBitrate(url, extractionEngine, downloadManager, filename, metadata);
          
        case RecoveryStrategy.switchCodec:
          return await _switchCodec(url, extractionEngine, downloadManager, filename, metadata);
          
        case RecoveryStrategy.switchCDN:
          return await _switchCDN(url, downloadManager, filename, metadata);
          
        case RecoveryStrategy.reparseManifest:
          return await _reparseManifest(url, extractionEngine, downloadManager, filename, metadata);
          
        case RecoveryStrategy.pivotToProgressive:
          return await _pivotToProgressive(url, extractionEngine, downloadManager, filename, metadata);
          
        case RecoveryStrategy.remuxTracks:
          // Remuxing would require additional libraries - for now, just retry
          return await _retryWithPacing(url, downloadManager, filename, metadata);
          
        case RecoveryStrategy.restartCapture:
          return await _restartCapture(url, downloadManager, filename, metadata);
          
        case RecoveryStrategy.abort:
          return false;
          
        default:
          return false;
      }
    } catch (e) {
      debugPrint('[FailureIntelligence] Error executing recovery: $e');
      return false;
    }
  }
  
  /// Retry with exponential backoff
  Future<bool> _retryWithPacing(
    String url,
    DownloadManagerService downloadManager,
    String? filename,
    Map<String, dynamic>? metadata,
  ) async {
    final retryCount = _retryCounts[url] ?? 0;
    final delay = Duration(seconds: 1 << retryCount.clamp(0, 5)); // Exponential backoff
    
    await Future.delayed(delay);
    
    try {
      if (filename != null) {
        await downloadManager.addDownload(
          url: url,
          filename: filename,
          metadata: metadata,
        );
        return true;
      }
    } catch (e) {
      debugPrint('[FailureIntelligence] Retry failed: $e');
    }
    
    return false;
  }
  
  /// Switch to different bitrate/quality
  Future<bool> _switchBitrate(
    String url,
    MediaExtractionEngine extractionEngine,
    DownloadManagerService downloadManager,
    String? filename,
    Map<String, dynamic>? metadata,
  ) async {
    try {
      final extraction = await extractionEngine.extractMedia(url);
      if (extraction.success && extraction.streams.length > 1) {
        // Try a different quality stream
        final alternativeStream = extraction.streams[1]; // Second best
        await downloadManager.addDownload(
          url: alternativeStream.url,
          filename: filename ?? 'video.mp4',
          metadata: {
            ...?metadata,
            'quality': alternativeStream.quality?.label,
            'fallback': true,
          },
        );
        return true;
      }
    } catch (e) {
      debugPrint('[FailureIntelligence] Switch bitrate failed: $e');
    }
    
    return false;
  }
  
  /// Switch codec
  Future<bool> _switchCodec(
    String url,
    MediaExtractionEngine extractionEngine,
    DownloadManagerService downloadManager,
    String? filename,
    Map<String, dynamic>? metadata,
  ) async {
    // Similar to switch bitrate, but filter by codec
    return await _switchBitrate(url, extractionEngine, downloadManager, filename, metadata);
  }
  
  /// Switch CDN
  Future<bool> _switchCDN(
    String url,
    DownloadManagerService downloadManager,
    String? filename,
    Map<String, dynamic>? metadata,
  ) async {
    try {
      // Try alternative CDN by modifying URL
      final uri = Uri.parse(url);
      final alternativeHosts = [
        'cdn1.${uri.host}',
        'cdn2.${uri.host}',
        'media.${uri.host}',
        'stream.${uri.host}',
      ];
      
      for (final host in alternativeHosts) {
        try {
          final alternativeUrl = uri.replace(host: host).toString();
          await downloadManager.addDownload(
            url: alternativeUrl,
            filename: filename ?? 'video.mp4',
            metadata: {
              ...?metadata,
              'cdnFallback': true,
            },
          );
          return true;
        } catch (e) {
          continue; // Try next CDN
        }
      }
    } catch (e) {
      debugPrint('[FailureIntelligence] Switch CDN failed: $e');
    }
    
    return false;
  }
  
  /// Re-parse manifest
  Future<bool> _reparseManifest(
    String url,
    MediaExtractionEngine extractionEngine,
    DownloadManagerService downloadManager,
    String? filename,
    Map<String, dynamic>? metadata,
  ) async {
    try {
      final extraction = await extractionEngine.extractMedia(url);
      if (extraction.success && extraction.streams.isNotEmpty) {
        await downloadManager.addDownload(
          url: extraction.streams.first.url,
          filename: filename ?? 'video.mp4',
          metadata: {
            ...?metadata,
            'manifestReparsed': true,
          },
        );
        return true;
      }
    } catch (e) {
      debugPrint('[FailureIntelligence] Re-parse manifest failed: $e');
    }
    
    return false;
  }
  
  /// Pivot from adaptive to progressive
  Future<bool> _pivotToProgressive(
    String url,
    MediaExtractionEngine extractionEngine,
    DownloadManagerService downloadManager,
    String? filename,
    Map<String, dynamic>? metadata,
  ) async {
    try {
      final extraction = await extractionEngine.extractMedia(url);
      if (extraction.success) {
        // Find progressive stream
        final progressiveStream = extraction.streams.firstWhere(
          (s) => s.type == StreamType.progressive,
          orElse: () => extraction.streams.first,
        );
        
        await downloadManager.addDownload(
          url: progressiveStream.url,
          filename: filename ?? 'video.mp4',
          metadata: {
            ...?metadata,
            'pivotedToProgressive': true,
          },
        );
        return true;
      }
    } catch (e) {
      debugPrint('[FailureIntelligence] Pivot to progressive failed: $e');
    }
    
    return false;
  }
  
  /// Restart capture from beginning
  Future<bool> _restartCapture(
    String url,
    DownloadManagerService downloadManager,
    String? filename,
    Map<String, dynamic>? metadata,
  ) async {
    // Cancel existing download and restart
    // This would require tracking active downloads
    return await _retryWithPacing(url, downloadManager, filename, metadata);
  }
  
  /// Classify failure from exception
  FailureContext classifyFailure(dynamic error, String? url) {
    if (error is SocketException || error is TimeoutException) {
      return FailureContext(
        type: FailureType.networkError,
        errorMessage: error.toString(),
        url: url,
      );
    }
    
    if (error is http.ClientException) {
      return FailureContext(
        type: FailureType.networkError,
        errorMessage: error.toString(),
        url: url,
      );
    }
    
    if (error.toString().toLowerCase().contains('audio')) {
      return FailureContext(
        type: FailureType.missingAudio,
        errorMessage: error.toString(),
        url: url,
      );
    }
    
    if (error.toString().toLowerCase().contains('sync') || 
        error.toString().toLowerCase().contains('desync')) {
      return FailureContext(
        type: FailureType.avDesync,
        errorMessage: error.toString(),
        url: url,
      );
    }
    
    return FailureContext(
      type: FailureType.unknown,
      errorMessage: error.toString(),
      url: url,
    );
  }
  
  /// Get failure history for URL
  List<FailureContext> getFailureHistory(String url) {
    return _failureHistory[url] ?? [];
  }
  
  /// Clear failure history
  void clearHistory(String? url) {
    if (url != null) {
      _failureHistory.remove(url);
      _retryCounts.remove(url);
      _currentStrategies.remove(url);
    } else {
      _failureHistory.clear();
      _retryCounts.clear();
      _currentStrategies.clear();
    }
  }
  
  /// Get learning insights (for future optimization)
  Map<String, dynamic> getInsights() {
    final insights = <String, dynamic>{
      'totalFailures': _failureHistory.values.fold<int>(0, (sum, list) => sum + list.length),
      'failureTypes': <String, int>{},
      'mostProblematicUrls': <String, int>{},
    };
    
    // Count failure types
    for (final failures in _failureHistory.values) {
      for (final failure in failures) {
        final typeKey = failure.type.toString().split('.').last;
        insights['failureTypes'][typeKey] = 
            (insights['failureTypes'][typeKey] as int? ?? 0) + 1;
      }
    }
    
    // Find most problematic URLs
    for (final entry in _failureHistory.entries) {
      insights['mostProblematicUrls'][entry.key] = entry.value.length;
    }
    
    return insights;
  }
}

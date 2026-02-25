import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'download_manager_service.dart';
import '../models/vault_item.dart';

/// Media stream type
enum StreamType {
  progressive, // Direct MP4, WebM, etc.
  hls,         // HTTP Live Streaming (M3U8)
  dash,        // Dynamic Adaptive Streaming over HTTP
  unknown,
}

/// Stream quality information
class StreamQuality {
  final String? label; // e.g., "1080p", "720p", "480p"
  final int? width;
  final int? height;
  final int? bitrate;
  final String? codec;
  
  StreamQuality({
    this.label,
    this.width,
    this.height,
    this.bitrate,
    this.codec,
  });
}

/// Detected media stream
class MediaStream {
  final String url;
  final StreamType type;
  final StreamQuality? quality;
  final String? mimeType;
  final bool isVideo;
  final bool isAudio;
  final Map<String, dynamic>? metadata;
  
  MediaStream({
    required this.url,
    required this.type,
    this.quality,
    this.mimeType,
    this.isVideo = true,
    this.isAudio = false,
    this.metadata,
  });
}

/// Extraction result
class ExtractionResult {
  final bool success;
  final String? error;
  final List<MediaStream> streams;
  final String? title;
  final String? thumbnail;
  final int? duration;
  
  ExtractionResult({
    required this.success,
    this.error,
    this.streams = const [],
    this.title,
    this.thumbnail,
    this.duration,
  });
}

/// Comprehensive media extraction and reconstruction engine
/// Handles progressive, HLS, and DASH streams
class MediaExtractionEngine {
  DownloadManagerService? _downloadManager;
  final http.Client _httpClient = http.Client();
  
  MediaExtractionEngine(this._downloadManager);
  
  /// Set download manager (for dependency injection)
  void setDownloadManager(DownloadManagerService downloadManager) {
    _downloadManager = downloadManager;
    debugPrint('[MediaExtraction] Download manager set: ${downloadManager != null}');
  }
  
  /// Check if download manager is available
  bool get isReady => _downloadManager != null;
  
  /// Detect stream type from URL or manifest
  Future<StreamType> detectStreamType(String url) async {
    final urlLower = url.toLowerCase();
    
    if (urlLower.contains('.m3u8') || urlLower.contains('hls')) {
      return StreamType.hls;
    }
    if (urlLower.contains('.mpd') || urlLower.contains('dash')) {
      return StreamType.dash;
    }
    if (urlLower.contains('.mp4') || urlLower.contains('.webm') || urlLower.contains('.mov')) {
      return StreamType.progressive;
    }
    
    // Try fetching to check content type
    try {
      final response = await _httpClient.head(Uri.parse(url)).timeout(
        const Duration(seconds: 5),
      );
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      
      if (contentType.contains('application/vnd.apple.mpegurl') || 
          contentType.contains('application/x-mpegurl')) {
        return StreamType.hls;
      }
      if (contentType.contains('application/dash+xml')) {
        return StreamType.dash;
      }
      if (contentType.contains('video/') || contentType.contains('audio/')) {
        return StreamType.progressive;
      }
    } catch (e) {
      debugPrint('[MediaExtraction] Error detecting stream type: $e');
    }
    
    return StreamType.unknown;
  }
  
  /// Extract media from URL
  Future<ExtractionResult> extractMedia(String url, {String? title}) async {
    try {
      debugPrint('[MediaExtraction] Starting media extraction for: $url');
      final streamType = await detectStreamType(url);
      debugPrint('[MediaExtraction] Detected stream type: $streamType');
      
      ExtractionResult result;
      switch (streamType) {
        case StreamType.progressive:
          result = _extractProgressive(url, title: title);
          break;
        case StreamType.hls:
          result = await _extractHLS(url, title: title);
          break;
        case StreamType.dash:
          result = await _extractDASH(url, title: title);
          break;
        default:
          result = ExtractionResult(
            success: false,
            error: 'Unknown stream type',
          );
      }
      
      debugPrint('[MediaExtraction] Extraction result: success=${result.success}, streams=${result.streams.length}');
      return result;
    } catch (e, stackTrace) {
      debugPrint('[MediaExtraction] ❌ Error extracting media: $e');
      debugPrint('[MediaExtraction] Stack trace: $stackTrace');
      return ExtractionResult(
        success: false,
        error: e.toString(),
      );
    }
  }
  
  /// Extract progressive media (direct download)
  ExtractionResult _extractProgressive(String url, {String? title}) {
    return ExtractionResult(
      success: true,
      streams: [
        MediaStream(
          url: url,
          type: StreamType.progressive,
          isVideo: true,
        ),
      ],
      title: title,
    );
  }
  
  /// Extract HLS stream (M3U8)
  Future<ExtractionResult> _extractHLS(String manifestUrl, {String? title}) async {
    try {
      // Fetch manifest
      final response = await _httpClient.get(Uri.parse(manifestUrl)).timeout(
        const Duration(seconds: 30),
      );
      
      if (response.statusCode != 200) {
        return ExtractionResult(
          success: false,
          error: 'Failed to fetch HLS manifest: HTTP ${response.statusCode}',
        );
      }
      
      final manifest = utf8.decode(response.bodyBytes);
      final streams = <MediaStream>[];
      
      // Parse M3U8 manifest
      final lines = manifest.split('\n');
      StreamQuality? currentQuality;
      
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        
        if (line.startsWith('#EXT-X-STREAM-INF:')) {
          // Parse quality info
          currentQuality = _parseHLSQuality(line);
        } else if (line.isNotEmpty && !line.startsWith('#')) {
          // This is a URL - should follow a #EXT-X-STREAM-INF line
          // Resolve relative URL
          final baseUri = Uri.parse(manifestUrl);
          final resolvedUrl = baseUri.resolve(line).toString();
          
          streams.add(MediaStream(
            url: resolvedUrl,
            type: StreamType.hls,
            quality: currentQuality,
            isVideo: true,
          ));
          
          // Reset quality for next stream
          currentQuality = null;
        }
      }
      
      // If no streams found, try to extract segment URLs
      if (streams.isEmpty) {
        // Look for segment URLs in manifest
        for (final line in lines) {
          if (line.isNotEmpty && !line.startsWith('#')) {
            final baseUri = Uri.parse(manifestUrl);
            final segmentUrl = baseUri.resolve(line).toString();
            streams.add(MediaStream(
              url: segmentUrl,
              type: StreamType.hls,
              isVideo: true,
            ));
          }
        }
      }
      
      return ExtractionResult(
        success: streams.isNotEmpty,
        streams: streams,
        title: title,
        error: streams.isEmpty ? 'No streams found in HLS manifest' : null,
      );
    } catch (e) {
      debugPrint('[MediaExtraction] Error extracting HLS: $e');
      return ExtractionResult(
        success: false,
        error: 'HLS extraction failed: $e',
      );
    }
  }
  
  /// Parse HLS quality from EXT-X-STREAM-INF line
  StreamQuality _parseHLSQuality(String line) {
    int? width;
    int? height;
    int? bitrate;
    String? codec;
    String? label;
    
    // Parse RESOLUTION=WIDTHxHEIGHT
    final resolutionMatch = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
    if (resolutionMatch != null) {
      width = int.tryParse(resolutionMatch.group(1)!);
      height = int.tryParse(resolutionMatch.group(2)!);
      label = '${height}p';
    }
    
    // Parse BANDWIDTH=bitrate
    final bandwidthMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
    if (bandwidthMatch != null) {
      bitrate = int.tryParse(bandwidthMatch.group(1)!);
    }
    
    // Parse CODECS=codec
    final codecMatch = RegExp(r'CODECS="([^"]+)"').firstMatch(line);
    if (codecMatch != null) {
      codec = codecMatch.group(1);
    }
    
    return StreamQuality(
      label: label,
      width: width,
      height: height,
      bitrate: bitrate,
      codec: codec,
    );
  }
  
  /// Extract DASH stream (MPD)
  Future<ExtractionResult> _extractDASH(String manifestUrl, {String? title}) async {
    try {
      // Fetch manifest
      final response = await _httpClient.get(Uri.parse(manifestUrl)).timeout(
        const Duration(seconds: 30),
      );
      
      if (response.statusCode != 200) {
        return ExtractionResult(
          success: false,
          error: 'Failed to fetch DASH manifest: HTTP ${response.statusCode}',
        );
      }
      
      final manifestXml = utf8.decode(response.bodyBytes);
      final streams = <MediaStream>[];
      
      // Parse DASH MPD (simplified - full parser would use XML library)
      // Extract AdaptationSet URLs
      final adaptationSetPattern = RegExp(
        r'<AdaptationSet[^>]*>.*?<Representation[^>]*>.*?<BaseURL>([^<]+)</BaseURL>',
        multiLine: true,
        dotAll: true,
      );
      
      for (final match in adaptationSetPattern.allMatches(manifestXml)) {
        final url = match.group(1);
        if (url != null) {
          final baseUri = Uri.parse(manifestUrl);
          final fullUrl = baseUri.resolve(url).toString();
          
          streams.add(MediaStream(
            url: fullUrl,
            type: StreamType.dash,
            isVideo: true,
          ));
        }
      }
      
      return ExtractionResult(
        success: streams.isNotEmpty,
        streams: streams,
        title: title,
        error: streams.isEmpty ? 'No streams found in DASH manifest' : null,
      );
    } catch (e) {
      debugPrint('[MediaExtraction] Error extracting DASH: $e');
      return ExtractionResult(
        success: false,
        error: 'DASH extraction failed: $e',
      );
    }
  }
  
  /// Download and reconstruct adaptive stream
  /// For HLS/DASH, downloads all segments and concatenates them
  Future<bool> downloadAdaptiveStream({
    required String manifestUrl,
    required String filename,
    StreamType? streamType,
    StreamQuality? quality,
    VaultItemSource source = VaultItemSource.browser,
    String? sourceSite,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final type = streamType ?? await detectStreamType(manifestUrl);
      
      if (type == StreamType.progressive) {
        // Use download manager for progressive
        if (_downloadManager == null) {
          throw StateError('Download manager not set');
        }
        await _downloadManager!.addDownload(
          url: manifestUrl,
          filename: filename,
          source: source,
          sourceSite: sourceSite,
          metadata: metadata,
        );
        return true;
      }
      
      // For adaptive streams, extract and download segments
      final extraction = await extractMedia(manifestUrl);
      if (!extraction.success || extraction.streams.isEmpty) {
        return false;
      }
      
      // For now, download the first/best stream
      // Full implementation would download all segments and reconstruct
      final stream = extraction.streams.first;
      
      // Use download manager (it will handle the stream URL)
      if (_downloadManager == null) {
        throw StateError('Download manager not set');
      }
      await _downloadManager!.addDownload(
        url: stream.url,
        filename: filename,
        mimeType: stream.mimeType,
        source: source,
        sourceSite: sourceSite,
        metadata: {
          ...?metadata,
          'streamType': type.toString(),
          'quality': quality?.label,
        },
      );
      
      return true;
    } catch (e) {
      debugPrint('[MediaExtraction] Error downloading adaptive stream: $e');
      return false;
    }
  }
  
  /// Download progressive media
  Future<bool> downloadProgressiveMedia({
    required String url,
    required String filename,
    String? mimeType,
    VaultItemSource source = VaultItemSource.browser,
    String? sourceSite,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      if (_downloadManager == null) {
        throw StateError('Download manager not set');
      }
      await _downloadManager!.addDownload(
        url: url,
        filename: filename,
        mimeType: mimeType,
        source: source,
        sourceSite: sourceSite,
        metadata: metadata,
      );
      return true;
    } catch (e) {
      debugPrint('[MediaExtraction] Error downloading progressive media: $e');
      return false;
    }
  }
  
  void dispose() {
    _httpClient.close();
  }
}

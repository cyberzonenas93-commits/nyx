import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Stream type classification
enum StreamType {
  hls,        // HTTP Live Streaming (.m3u8)
  dash,       // Dynamic Adaptive Streaming over HTTP (.mpd)
  progressive, // Progressive download (.mp4, .webm, etc.)
  unknown,    // Unknown or unclassified
}

/// Protection level classification (technical detection only)
enum ProtectionLevel {
  none,       // No encryption or DRM detected
  encrypted,  // AES-128 encrypted (requires key from manifest)
  drm,        // DRM detected (Widevine, FairPlay, PlayReady)
  unknown,    // Protection status unknown
}

/// Extraction feasibility (technical assessment only)
enum ExtractionRecommendation {
  feasible,   // Technically feasible (progressive or unencrypted ABR)
  requiresKey, // Requires encryption key (encrypted but key available)
  complex,    // Complex extraction (DRM or session-bound tokens)
  notFeasible, // Not technically feasible (DRM or missing keys)
}

/// Streaming mechanism diagnostics
class StreamingDiagnostics {
  final StreamType type;
  final String? manifestUrl;
  final List<String> segmentUrls;
  final String? primaryDomain;
  final List<String> additionalDomains;
  final Map<String, dynamic> metadata;
  final DateTime detectedAt;
  final bool isMultiDomain;
  final ProtectionLevel protectionLevel;
  final ExtractionRecommendation extractionRecommendation;
  final bool hasTokenizedUrls;
  final bool hasExpiringTokens;
  final String? encryptionKeyUrl;
  final List<String> drmSystems;

  StreamingDiagnostics({
    required this.type,
    this.manifestUrl,
    this.segmentUrls = const [],
    this.primaryDomain,
    this.additionalDomains = const [],
    this.metadata = const {},
    DateTime? detectedAt,
    this.isMultiDomain = false,
    this.protectionLevel = ProtectionLevel.unknown,
    this.extractionRecommendation = ExtractionRecommendation.complex,
    this.hasTokenizedUrls = false,
    this.hasExpiringTokens = false,
    this.encryptionKeyUrl,
    this.drmSystems = const [],
  }) : detectedAt = detectedAt ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'manifestUrl': manifestUrl,
      'segmentCount': segmentUrls.length,
      'primaryDomain': primaryDomain,
      'additionalDomains': additionalDomains,
      'isMultiDomain': isMultiDomain,
      'protectionLevel': protectionLevel.name,
      'extractionRecommendation': extractionRecommendation.name,
      'hasTokenizedUrls': hasTokenizedUrls,
      'hasExpiringTokens': hasExpiringTokens,
      'encryptionKeyUrl': encryptionKeyUrl,
      'drmSystems': drmSystems,
      'metadata': metadata,
      'detectedAt': detectedAt.toIso8601String(),
    };
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.writeln('Stream Type: ${type.name.toUpperCase()}');
    if (manifestUrl != null) {
      buffer.writeln('Manifest: $manifestUrl');
    }
    if (segmentUrls.isNotEmpty) {
      buffer.writeln('Segments Detected: ${segmentUrls.length}');
    }
    if (primaryDomain != null) {
      buffer.writeln('Primary Domain: $primaryDomain');
    }
    if (isMultiDomain && additionalDomains.isNotEmpty) {
      buffer.writeln('Additional Domains: ${additionalDomains.join(', ')}');
    }
    buffer.writeln('Protection: ${protectionLevel.name.toUpperCase()}');
    if (protectionLevel == ProtectionLevel.encrypted && encryptionKeyUrl != null) {
      buffer.writeln('Encryption Key: $encryptionKeyUrl');
    }
    if (protectionLevel == ProtectionLevel.drm && drmSystems.isNotEmpty) {
      buffer.writeln('DRM Systems: ${drmSystems.join(', ')}');
    }
    buffer.writeln('Extraction: ${_getExtractionMessage()}');
    if (hasTokenizedUrls) {
      buffer.writeln('⚠️ Tokenized URLs detected (session-bound)');
    }
    if (hasExpiringTokens) {
      buffer.writeln('⚠️ Expiring tokens detected');
    }
    if (metadata.isNotEmpty) {
      buffer.writeln('Metadata: $metadata');
    }
    return buffer.toString();
  }

  String _getExtractionMessage() {
    switch (extractionRecommendation) {
      case ExtractionRecommendation.feasible:
        return '✅ Technically feasible (progressive or unencrypted)';
      case ExtractionRecommendation.requiresKey:
        return '⚠️ Requires encryption key (encrypted, key may be available)';
      case ExtractionRecommendation.complex:
        return '⚠️ Complex extraction (DRM or session-bound tokens)';
      case ExtractionRecommendation.notFeasible:
        return '🚫 Not technically feasible (DRM or missing keys)';
    }
  }
}

/// Service for detecting and classifying video streaming mechanisms
class StreamingDetectorService extends ChangeNotifier {
  final Map<String, StreamingDiagnostics> _activeStreams = {};
  final Map<String, List<String>> _requestHistory = {}; // tabId -> list of URLs
  final Map<String, DateTime> _lastUserInteraction = {}; // tabId -> timestamp
  final Map<String, String> _primaryDomain = {}; // tabId -> domain
  final Map<String, Set<String>> _observedDomains = {}; // tabId -> set of domains
  final Map<String, String> _manifestContent = {}; // manifestUrl -> content

  /// Track user interaction to start monitoring
  void recordUserInteraction(String tabId) {
    _lastUserInteraction[tabId] = DateTime.now();
    debugPrint('[StreamingDetector] User interaction recorded for tab: $tabId');
  }

  /// Parse HLS manifest to detect encryption and protection
  Future<Map<String, dynamic>> _parseHLSManifest(String manifestUrl, String? content) async {
    final result = <String, dynamic>{
      'hasEncryption': false,
      'encryptionKeyUrl': null,
      'hasDRM': false,
      'drmSystems': <String>[],
      'hasTokenizedUrls': false,
      'hasExpiringTokens': false,
    };

    if (content == null) {
      // Try to fetch manifest if content not provided
      try {
        final response = await http.get(Uri.parse(manifestUrl));
        if (response.statusCode == 200) {
          content = response.body;
        }
      } catch (e) {
        debugPrint('[StreamingDetector] Failed to fetch HLS manifest: $e');
        return result;
      }
    }

    if (content == null) return result;

    final lines = content.split('\n');
    
    // Check for EXT-X-KEY (AES-128 encryption)
    for (final line in lines) {
      if (line.startsWith('#EXT-X-KEY:')) {
        result['hasEncryption'] = true;
        // Extract key URL
        final keyMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (keyMatch != null) {
          final keyUrl = keyMatch.group(1);
          // Resolve relative URLs
          if (keyUrl != null && !keyUrl.startsWith('http')) {
            final baseUri = Uri.parse(manifestUrl);
            final resolvedUri = baseUri.resolve(keyUrl);
            result['encryptionKeyUrl'] = resolvedUri.toString();
          } else {
            result['encryptionKeyUrl'] = keyUrl;
          }
        }
        // Check for KEYFORMAT (indicates DRM)
        if (line.contains('KEYFORMAT')) {
          result['hasDRM'] = true;
          if (line.contains('com.apple.streamingkeydelivery')) {
            result['drmSystems'] = ['FairPlay'];
          } else if (line.contains('com.widevine')) {
            result['drmSystems'] = ['Widevine'];
          } else if (line.contains('com.microsoft.playready')) {
            result['drmSystems'] = ['PlayReady'];
          }
        }
      }
    }

    // Check for tokenized URLs (common patterns)
    if (content.contains('token=') || 
        content.contains('signature=') ||
        content.contains('expires=') ||
        content.contains('hdnea=')) {
      result['hasTokenizedUrls'] = true;
    }

    // Check for expiring tokens
    if (content.contains('expires=') || content.contains('exp=')) {
      result['hasExpiringTokens'] = true;
    }

    return result;
  }

  /// Parse DASH manifest to detect DRM and protection
  Future<Map<String, dynamic>> _parseDASHManifest(String manifestUrl, String? content) async {
    final result = <String, dynamic>{
      'hasEncryption': false,
      'encryptionKeyUrl': null,
      'hasDRM': false,
      'drmSystems': <String>[],
      'hasTokenizedUrls': false,
      'hasExpiringTokens': false,
    };

    if (content == null) {
      try {
        final response = await http.get(Uri.parse(manifestUrl));
        if (response.statusCode == 200) {
          content = response.body;
        }
      } catch (e) {
        debugPrint('[StreamingDetector] Failed to fetch DASH manifest: $e');
        return result;
      }
    }

    if (content == null) return result;

    // Check for ContentProtection elements (DRM)
    if (content.contains('<ContentProtection') || 
        content.contains('contentProtection')) {
      result['hasDRM'] = true;
      
      // Detect specific DRM systems
      if (content.contains('urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed') ||
          content.contains('com.widevine')) {
        result['drmSystems'] = ['Widevine'];
      }
      if (content.contains('urn:uuid:94ce86fb-07ff-4f43-adb8-93d2fa968ca2') ||
          content.contains('com.microsoft.playready')) {
        if (result['drmSystems'] is List) {
          (result['drmSystems'] as List).add('PlayReady');
        }
      }
      if (content.contains('urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95') ||
          content.contains('com.apple.fps')) {
        if (result['drmSystems'] is List) {
          (result['drmSystems'] as List).add('FairPlay');
        }
      }
    }

    // Check for encryption (cenc:default_KID)
    if (content.contains('cenc:default_KID') || 
        content.contains('encryption')) {
      result['hasEncryption'] = true;
    }

    // Check for tokenized URLs
    if (content.contains('token=') || 
        content.contains('signature=') ||
        content.contains('expires=')) {
      result['hasTokenizedUrls'] = true;
    }

    if (content.contains('expires=') || content.contains('exp=')) {
      result['hasExpiringTokens'] = true;
    }

    return result;
  }

  /// Analyze a network request and classify if it's video-related
  StreamingDiagnostics? analyzeRequest({
    required String tabId,
    required String url,
    String? contentType,
    Map<String, String>? headers,
  }) {
    // Only analyze after user interaction
    final lastInteraction = _lastUserInteraction[tabId];
    if (lastInteraction == null) {
      return null; // No user interaction yet, ignore
    }

    // Only analyze requests within 30 seconds of user interaction
    final timeSinceInteraction = DateTime.now().difference(lastInteraction);
    if (timeSinceInteraction > const Duration(seconds: 30)) {
      return null; // Too long after interaction
    }

    // Initialize tracking for this tab if needed
    if (!_requestHistory.containsKey(tabId)) {
      _requestHistory[tabId] = [];
      _observedDomains[tabId] = {};
    }

    _requestHistory[tabId]!.add(url);
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) {
      _observedDomains[tabId]!.add(uri.host);
    }

    // Extract primary domain from first request
    if (_primaryDomain[tabId] == null && uri != null) {
      _primaryDomain[tabId] = uri.host;
    }

    // Classify based on URL pattern and content type
    StreamType? detectedType;
    String? manifestUrl;
    List<String> segmentUrls = [];

    final urlLower = url.toLowerCase();

    // Check for HLS manifest (.m3u8)
    if (urlLower.contains('.m3u8') || 
        contentType?.toLowerCase().contains('application/vnd.apple.mpegurl') == true ||
        contentType?.toLowerCase().contains('application/x-mpegurl') == true) {
      detectedType = StreamType.hls;
      manifestUrl = url;
      debugPrint('[StreamingDetector] HLS manifest detected: $url');
    }
    // Check for DASH manifest (.mpd)
    else if (urlLower.contains('.mpd') ||
             contentType?.toLowerCase().contains('application/dash+xml') == true) {
      detectedType = StreamType.dash;
      manifestUrl = url;
      debugPrint('[StreamingDetector] DASH manifest detected: $url');
      
      // Parse manifest asynchronously to detect DRM
      _parseDASHManifest(url, null).then((protectionInfo) {
        _updateStreamProtection(tabId, protectionInfo);
      });
    }
    // Check for progressive media
    else if (urlLower.contains('.mp4') ||
             urlLower.contains('.webm') ||
             urlLower.contains('.mov') ||
             urlLower.contains('.avi') ||
             urlLower.contains('.mkv') ||
             contentType?.toLowerCase().startsWith('video/') == true) {
      // Check if it's a segment or full file
      // Segments often have patterns like: segment_001.mp4, chunk_123.mp4, etc.
      final isSegment = urlLower.contains('segment') ||
                       urlLower.contains('chunk') ||
                       urlLower.contains('ts') ||
                       urlLower.contains('frag') ||
                       RegExp(r'[0-9]{3,}\.(mp4|webm|ts)$').hasMatch(urlLower);

      if (isSegment) {
        // Likely a segment from a streaming protocol
        segmentUrls.add(url);
        // Check if we already detected a manifest
        final existing = _activeStreams[tabId];
        if (existing != null && existing.manifestUrl != null) {
          // Update existing stream with segment
          final updated = StreamingDiagnostics(
            type: existing.type,
            manifestUrl: existing.manifestUrl,
            segmentUrls: [...existing.segmentUrls, url],
            primaryDomain: existing.primaryDomain,
            additionalDomains: existing.additionalDomains,
            metadata: existing.metadata,
            detectedAt: existing.detectedAt,
            isMultiDomain: existing.isMultiDomain || 
                          (uri != null && uri.host != existing.primaryDomain),
            protectionLevel: existing.protectionLevel,
            extractionRecommendation: existing.extractionRecommendation,
            hasTokenizedUrls: existing.hasTokenizedUrls,
            hasExpiringTokens: existing.hasExpiringTokens,
            encryptionKeyUrl: existing.encryptionKeyUrl,
            drmSystems: existing.drmSystems,
          );
          _activeStreams[tabId] = updated;
          notifyListeners();
          return updated;
        }
        // Segment without manifest - might be HLS segments (.ts files)
        if (urlLower.contains('.ts')) {
          detectedType = StreamType.hls;
          segmentUrls = [url];
        }
      } else {
        // Full progressive file
        detectedType = StreamType.progressive;
        debugPrint('[StreamingDetector] Progressive media detected: $url');
      }
    }

    // If we detected a stream type, create diagnostics
    if (detectedType != null) {
      final primaryDomain = _primaryDomain[tabId];
      final allDomains = _observedDomains[tabId] ?? {};
      final additionalDomains = allDomains
          .where((domain) => domain != primaryDomain)
          .toList();

      // Check for tokenized URLs in the URL itself
      final hasTokenizedUrls = url.contains('token=') || 
                               url.contains('signature=') ||
                               url.contains('hdnea=') ||
                               url.contains('expires=');
      final hasExpiringTokens = url.contains('expires=') || url.contains('exp=');

      // Determine protection level and extraction feasibility
      ProtectionLevel protectionLevel = ProtectionLevel.none;
      ExtractionRecommendation extractionRecommendation = ExtractionRecommendation.feasible;

      if (detectedType == StreamType.progressive) {
        // Progressive streams are generally feasible
        protectionLevel = ProtectionLevel.none;
        extractionRecommendation = hasTokenizedUrls 
            ? ExtractionRecommendation.requiresKey 
            : ExtractionRecommendation.feasible;
      } else {
        // ABR streams - protection will be determined after manifest parsing
        protectionLevel = ProtectionLevel.unknown;
        extractionRecommendation = ExtractionRecommendation.complex;
      }

      final diagnostics = StreamingDiagnostics(
        type: detectedType,
        manifestUrl: manifestUrl,
        segmentUrls: segmentUrls,
        primaryDomain: primaryDomain,
        additionalDomains: additionalDomains,
        metadata: {
          'contentType': contentType,
          'url': url,
          'requestCount': _requestHistory[tabId]?.length ?? 0,
        },
        isMultiDomain: additionalDomains.isNotEmpty,
        protectionLevel: protectionLevel,
        extractionRecommendation: extractionRecommendation,
        hasTokenizedUrls: hasTokenizedUrls,
        hasExpiringTokens: hasExpiringTokens,
      );

      // Store or update active stream
      if (_activeStreams.containsKey(tabId) && manifestUrl == null) {
        // Update existing stream with new segment
        final existing = _activeStreams[tabId]!;
        _activeStreams[tabId] = StreamingDiagnostics(
          type: existing.type,
          manifestUrl: existing.manifestUrl,
          segmentUrls: [...existing.segmentUrls, ...segmentUrls],
          primaryDomain: existing.primaryDomain ?? primaryDomain,
          additionalDomains: [
            ...existing.additionalDomains,
            ...additionalDomains,
          ].toSet().toList(),
          metadata: {
            ...existing.metadata,
            ...diagnostics.metadata,
          },
          detectedAt: existing.detectedAt,
          isMultiDomain: existing.isMultiDomain || diagnostics.isMultiDomain,
          protectionLevel: existing.protectionLevel,
          extractionRecommendation: existing.extractionRecommendation,
          hasTokenizedUrls: existing.hasTokenizedUrls || diagnostics.hasTokenizedUrls,
          hasExpiringTokens: existing.hasExpiringTokens || diagnostics.hasExpiringTokens,
          encryptionKeyUrl: existing.encryptionKeyUrl ?? diagnostics.encryptionKeyUrl,
          drmSystems: existing.drmSystems.isNotEmpty ? existing.drmSystems : diagnostics.drmSystems,
        );
      } else {
        _activeStreams[tabId] = diagnostics;
      }

      notifyListeners();
      return _activeStreams[tabId];
    }

    return null;
  }

  /// Get diagnostics for a specific tab
  StreamingDiagnostics? getDiagnostics(String tabId) {
    return _activeStreams[tabId];
  }

  /// Get all active streams
  Map<String, StreamingDiagnostics> get activeStreams => Map.unmodifiable(_activeStreams);

  /// Clear diagnostics for a tab
  void clearTab(String tabId) {
    _activeStreams.remove(tabId);
    _requestHistory.remove(tabId);
    _lastUserInteraction.remove(tabId);
    _primaryDomain.remove(tabId);
    _observedDomains.remove(tabId);
    notifyListeners();
  }

  /// Clear all diagnostics
  void clearAll() {
    _activeStreams.clear();
    _requestHistory.clear();
    _lastUserInteraction.clear();
    _primaryDomain.clear();
    _observedDomains.clear();
    notifyListeners();
  }

  /// Update stream protection information after manifest parsing
  void _updateStreamProtection(String tabId, Map<String, dynamic> protectionInfo) {
    final existing = _activeStreams[tabId];
    if (existing == null) return;

    ProtectionLevel protectionLevel = existing.protectionLevel;
    ExtractionRecommendation extractionRecommendation = existing.extractionRecommendation;
    String? encryptionKeyUrl = existing.encryptionKeyUrl;
    List<String> drmSystems = List.from(existing.drmSystems);
    bool hasTokenizedUrls = existing.hasTokenizedUrls;
    bool hasExpiringTokens = existing.hasExpiringTokens;

    // Update based on manifest parsing results
    if (protectionInfo['hasDRM'] == true) {
      protectionLevel = ProtectionLevel.drm;
      extractionRecommendation = ExtractionRecommendation.notFeasible;
      if (protectionInfo['drmSystems'] is List) {
        drmSystems = List<String>.from(protectionInfo['drmSystems']);
      }
    } else if (protectionInfo['hasEncryption'] == true) {
      protectionLevel = ProtectionLevel.encrypted;
      extractionRecommendation = protectionInfo['encryptionKeyUrl'] != null
          ? ExtractionRecommendation.requiresKey
          : ExtractionRecommendation.complex;
      encryptionKeyUrl = protectionInfo['encryptionKeyUrl'];
    } else {
      protectionLevel = ProtectionLevel.none;
      extractionRecommendation = hasTokenizedUrls
          ? ExtractionRecommendation.requiresKey
          : ExtractionRecommendation.feasible;
    }

    if (protectionInfo['hasTokenizedUrls'] == true) {
      hasTokenizedUrls = true;
    }
    if (protectionInfo['hasExpiringTokens'] == true) {
      hasExpiringTokens = true;
    }

    // Update diagnostics
    _activeStreams[tabId] = StreamingDiagnostics(
      type: existing.type,
      manifestUrl: existing.manifestUrl,
      segmentUrls: existing.segmentUrls,
      primaryDomain: existing.primaryDomain,
      additionalDomains: existing.additionalDomains,
      metadata: existing.metadata,
      detectedAt: existing.detectedAt,
      isMultiDomain: existing.isMultiDomain,
      protectionLevel: protectionLevel,
      extractionRecommendation: extractionRecommendation,
      hasTokenizedUrls: hasTokenizedUrls,
      hasExpiringTokens: hasExpiringTokens,
      encryptionKeyUrl: encryptionKeyUrl,
      drmSystems: drmSystems,
    );

    notifyListeners();
  }

  /// Get classification summary for a tab
  String getClassificationSummary(String tabId) {
    final diagnostics = _activeStreams[tabId];
    if (diagnostics == null) {
      return 'No streaming detected';
    }

    return diagnostics.toString();
  }
}

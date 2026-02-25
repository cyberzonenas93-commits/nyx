import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Detected video information
class DetectedVideo {
  final String url;
  final String? title;
  final String? thumbnail;
  final int? duration;
  final String? quality;
  final VideoSource source;

  DetectedVideo({
    required this.url,
    this.title,
    this.thumbnail,
    this.duration,
    this.quality,
    required this.source,
  });
}

enum VideoSource {
  youtube,
  direct,
  hls,
  dash,
  embedded,
}

/// Service for detecting and extracting videos from web pages
class VideoDetectionService {
  YoutubeExplode? _ytExplode;
  bool _isDisposed = false;
  
  YoutubeExplode get _youtubeExplode {
    if (_isDisposed || _ytExplode == null) {
      _ytExplode?.close();
      _ytExplode = YoutubeExplode();
      _isDisposed = false;
    }
    return _ytExplode!;
  }
  
  /// Recreate YoutubeExplode instance (useful for Android network recovery)
  void _recreateYoutubeExplode() {
    if (!_isDisposed) {
      _ytExplode?.close();
    }
    _ytExplode = YoutubeExplode();
    _isDisposed = false;
  }

  /// Detect videos from a web page URL
  Future<List<DetectedVideo>> detectVideos(String pageUrl) async {
    try {
      if (kDebugMode) {
        debugPrint('[VideoDetection] ========================================');
        debugPrint('[VideoDetection] detectVideos called with URL: $pageUrl');
      }
      
      final uri = Uri.parse(pageUrl);
      final hostname = uri.host.toLowerCase();

      if (kDebugMode) {
        debugPrint('[VideoDetection] Hostname: $hostname');
      }

      // YouTube detection
      if (hostname.contains('youtube.com') || hostname.contains('youtu.be')) {
        if (kDebugMode) {
          debugPrint('[VideoDetection] ✅ Detected YouTube domain, calling _detectYouTubeVideos');
        }
        final videos = await _detectYouTubeVideos(pageUrl);
        if (kDebugMode) {
          debugPrint('[VideoDetection] ✅ YouTube detection returned ${videos.length} video(s)');
        }
        return videos;
      }

      // Generic video detection for other sites
      if (kDebugMode) {
        debugPrint('[VideoDetection] Not YouTube, calling _detectGenericVideos');
      }
      return await _detectGenericVideos(pageUrl);
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[VideoDetection] ❌ ERROR in detectVideos: $e');
        debugPrint('[VideoDetection] Error type: ${e.runtimeType}');
        debugPrint('[VideoDetection] Stack trace: $stackTrace');
      }
      return [];
    }
  }

  /// Detect YouTube videos
  Future<List<DetectedVideo>> _detectYouTubeVideos(String url) async {
    if (kDebugMode) {
      debugPrint('[VideoDetection] ========================================');
      debugPrint('[VideoDetection] _detectYouTubeVideos called with URL: $url');
    }
    
    // Extract video ID first (outside try block so it's available in catch blocks)
    final videoId = extractYouTubeVideoId(url);
    if (videoId == null) {
      if (kDebugMode) {
        debugPrint('[VideoDetection] ❌ Could not extract video ID from URL: $url');
        debugPrint('[VideoDetection] Returning empty list');
      }
      return [];
    }
    
    if (kDebugMode) {
      debugPrint('[VideoDetection] ✅ Successfully extracted video ID: $videoId');
    }
    
    try {
      if (kDebugMode) {
        debugPrint('[VideoDetection] ========================================');
        debugPrint('[VideoDetection] Detecting YouTube video from URL: $url');
        debugPrint('[VideoDetection] Extracted video ID: $videoId');
        debugPrint('[VideoDetection] Platform: ${Platform.operatingSystem}');
        debugPrint('[VideoDetection] ========================================');
      }
      
      // Always create a fresh instance for each detection to avoid closed client errors
      // This is safer than reusing instances that might get closed
      if (kDebugMode) {
        debugPrint('[VideoDetection] Creating fresh YoutubeExplode instance for this detection');
      }
      
      // Close existing instance if any (safely)
      if (_ytExplode != null) {
        try {
          if (!_isDisposed) {
            _ytExplode?.close();
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[VideoDetection] Error closing old instance (ignoring): $e');
          }
        }
      }
      
      // Create new instance
      try {
        _ytExplode = YoutubeExplode();
        _isDisposed = false;
        if (kDebugMode) {
          debugPrint('[VideoDetection] ✅ New YoutubeExplode instance created');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[VideoDetection] ❌ Error creating YoutubeExplode instance: $e');
        }
        rethrow;
      }
      
      // Add timeout to prevent hanging (30 seconds for both platforms to handle slow networks)
      final timeoutDuration = const Duration(seconds: 30);
      
      if (kDebugMode) {
        debugPrint('[VideoDetection] Fetching video info for ID: $videoId (timeout: ${timeoutDuration.inSeconds}s)');
        debugPrint('[VideoDetection] Calling _youtubeExplode.videos.get($videoId)...');
      }
      
      final video = await _youtubeExplode.videos.get(videoId).timeout(
        timeoutDuration,
        onTimeout: () {
          if (kDebugMode) {
            debugPrint('[VideoDetection] ⏱️ Timeout after ${timeoutDuration.inSeconds}s while fetching video info');
          }
          throw TimeoutException('YouTube API timeout while fetching video info (${timeoutDuration.inSeconds}s)');
        },
      );
      
      if (kDebugMode) {
        debugPrint('[VideoDetection] ✅ Successfully fetched video info: ${video.title}');
        debugPrint('[VideoDetection] Fetching manifest for ID: $videoId (timeout: ${timeoutDuration.inSeconds}s)');
      }
      
      // Try to fetch manifest with retries (up to 2 retries)
      StreamManifest? manifest;
      int retryCount = 0;
      const maxRetries = 2;
      
      while (retryCount <= maxRetries) {
        try {
          if (retryCount > 0) {
            if (kDebugMode) {
              debugPrint('[VideoDetection] Retrying manifest fetch (attempt ${retryCount + 1}/${maxRetries + 1})...');
            }
            // Recreate instance on retry to get fresh connection
            if (_ytExplode != null && !_isDisposed) {
              try {
                _ytExplode?.close();
              } catch (e) {
                // Ignore
              }
            }
            _ytExplode = YoutubeExplode();
            _isDisposed = false;
            // Wait a bit before retry
            await Future.delayed(Duration(milliseconds: 500 * retryCount));
          }
          
          // Use same timeout duration for manifest fetch
          manifest = await _youtubeExplode.videos.streamsClient.getManifest(videoId).timeout(
            timeoutDuration,
            onTimeout: () {
              if (kDebugMode) {
                debugPrint('[VideoDetection] Timeout after ${timeoutDuration.inSeconds}s while fetching manifest (attempt ${retryCount + 1})');
              }
              throw TimeoutException('YouTube API timeout while fetching manifest (${timeoutDuration.inSeconds}s)');
            },
          );
          
          // Success - break out of retry loop
          if (kDebugMode) {
            debugPrint('[VideoDetection] ✅ Manifest retrieved successfully on attempt ${retryCount + 1}');
          }
          break;
        } on TimeoutException {
          retryCount++;
          if (retryCount > maxRetries) {
            // All retries exhausted
            if (kDebugMode) {
              debugPrint('[VideoDetection] All ${maxRetries + 1} attempts to fetch manifest failed');
            }
            rethrow;
          }
          // Continue to next retry
          if (kDebugMode) {
            debugPrint('[VideoDetection] Manifest fetch failed, will retry...');
          }
        } catch (e) {
          // Non-timeout error - don't retry
          if (kDebugMode) {
            debugPrint('[VideoDetection] Non-timeout error fetching manifest: $e');
          }
          rethrow;
        }
      }
      
      if (manifest == null) {
        if (kDebugMode) {
          debugPrint('[VideoDetection] ❌ Failed to retrieve manifest after all retries');
        }
        return [];
      }
      
      if (kDebugMode) {
        debugPrint('[VideoDetection] ✅ Manifest retrieved. Muxed streams: ${manifest.muxed.length}, Video-only: ${manifest.videoOnly.length}, Audio-only: ${manifest.audioOnly.length}');
      }

      // Get best quality video (muxed stream preferred, then video-only)
      VideoStreamInfo? videoStream;
      
      if (manifest.muxed.isNotEmpty) {
        final sortedMuxed = manifest.muxed.sortByVideoQuality();
        videoStream = sortedMuxed.lastOrNull;
        if (kDebugMode && videoStream != null) {
          debugPrint('[VideoDetection] ✅ Selected muxed stream: ${videoStream.qualityLabel}');
        }
      }
      
      if (videoStream == null && manifest.videoOnly.isNotEmpty) {
        final sortedVideoOnly = manifest.videoOnly.sortByVideoQuality();
        videoStream = sortedVideoOnly.lastOrNull;
        if (kDebugMode && videoStream != null) {
          debugPrint('[VideoDetection] ✅ Selected video-only stream: ${videoStream.qualityLabel}');
        }
      }

      if (videoStream == null) {
        if (kDebugMode) {
          debugPrint('[VideoDetection] ❌ No video stream found for video ID: $videoId');
          debugPrint('[VideoDetection] Available muxed streams: ${manifest.muxed.length}');
          debugPrint('[VideoDetection] Available video-only streams: ${manifest.videoOnly.length}');
          debugPrint('[VideoDetection] Available audio-only streams: ${manifest.audioOnly.length}');
          
          // Log all available streams for debugging
          if (manifest.muxed.isNotEmpty) {
            debugPrint('[VideoDetection] Muxed stream qualities:');
            for (var stream in manifest.muxed) {
              debugPrint('[VideoDetection]   - ${stream.qualityLabel} (${stream.container})');
            }
          }
          if (manifest.videoOnly.isNotEmpty) {
            debugPrint('[VideoDetection] Video-only stream qualities:');
            for (var stream in manifest.videoOnly) {
              debugPrint('[VideoDetection]   - ${stream.qualityLabel} (${stream.container})');
            }
          }
        }
        return [];
      }

      if (kDebugMode) {
        debugPrint('[VideoDetection] ✅ Found YouTube video: ${video.title} (${videoStream.qualityLabel})');
        debugPrint('[VideoDetection] Video URL length: ${videoStream.url.toString().length}');
        debugPrint('[VideoDetection] Video URL preview: ${videoStream.url.toString().substring(0, videoStream.url.toString().length > 100 ? 100 : videoStream.url.toString().length)}...');
        debugPrint('[VideoDetection] Video stream details:');
        debugPrint('[VideoDetection]   - Quality: ${videoStream.qualityLabel}');
        debugPrint('[VideoDetection]   - Video Quality: ${videoStream.videoQuality}');
        debugPrint('[VideoDetection]   - Container: ${videoStream.container}');
        debugPrint('[VideoDetection]   - Codec: ${videoStream.videoCodec}');
        debugPrint('[VideoDetection]   - Size: ${videoStream.size.totalBytes} bytes');
      }

      final videoUrl = videoStream.url.toString();
      if (videoUrl.isEmpty) {
        if (kDebugMode) {
          debugPrint('[VideoDetection] ❌ ERROR: Video URL is empty!');
        }
        return [];
      }

      return [
        DetectedVideo(
          url: videoUrl,
          title: video.title,
          thumbnail: video.thumbnails.highResUrl,
          duration: video.duration?.inSeconds,
          quality: videoStream.qualityLabel,
          source: VideoSource.youtube,
        ),
      ];
    } on TimeoutException catch (e) {
      if (kDebugMode) {
        debugPrint('[VideoDetection] ⚠️ TIMEOUT detecting YouTube video');
        debugPrint('[VideoDetection] Error: $e');
        debugPrint('[VideoDetection] Platform: ${Platform.operatingSystem}');
        debugPrint('[VideoDetection] Video ID: $videoId');
        debugPrint('[VideoDetection] URL: $url');
        debugPrint('[VideoDetection] This might indicate slow network or YouTube API issues');
      }
      // Recreate instance after timeout
      _recreateYoutubeExplode();
      return [];
    } on SocketException catch (e) {
      if (kDebugMode) {
        debugPrint('[VideoDetection] ⚠️ NETWORK ERROR detecting YouTube video');
        debugPrint('[VideoDetection] Error: $e');
        debugPrint('[VideoDetection] Platform: ${Platform.operatingSystem}');
        debugPrint('[VideoDetection] Video ID: $videoId');
        debugPrint('[VideoDetection] URL: $url');
        debugPrint('[VideoDetection] This might be a network connectivity issue');
        debugPrint('[VideoDetection] Check: Internet connection, firewall, VPN');
      }
      // Recreate the instance for next attempt
      _recreateYoutubeExplode();
      return [];
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[VideoDetection] ⚠️ UNKNOWN ERROR detecting YouTube video');
        debugPrint('[VideoDetection] Error: $e');
        debugPrint('[VideoDetection] Error type: ${e.runtimeType}');
        debugPrint('[VideoDetection] Platform: ${Platform.operatingSystem}');
        debugPrint('[VideoDetection] Video ID: $videoId');
        debugPrint('[VideoDetection] URL: $url');
        debugPrint('[VideoDetection] Stack trace: $stackTrace');
        
        // Check if it's a closed client error
        if (e.toString().contains('http-client was closed') || 
            e.toString().contains('HttpClientClosedException')) {
          debugPrint('[VideoDetection] 🔧 Detected closed client error - will recreate instance');
        }
      }
      // Recreate instance for any error, especially closed client errors
      _recreateYoutubeExplode();
      return [];
    }
  }

  /// Extract YouTube video ID from URL
  String? extractYouTubeVideoId(String url) {
    if (kDebugMode) {
      debugPrint('[VideoDetection] Extracting video ID from URL: $url');
    }
    try {
      final uri = Uri.parse(url);
      
      if (kDebugMode) {
        debugPrint('[VideoDetection] Parsing URL: $url');
        debugPrint('[VideoDetection] Host: ${uri.host}, Path: ${uri.path}');
      }
      
      // youtube.com/watch?v=VIDEO_ID or m.youtube.com/watch?v=VIDEO_ID
      // Also handle /watch?v=VIDEO_ID&other=params
      if (uri.host.contains('youtube.com') && uri.path.contains('/watch')) {
        final videoId = uri.queryParameters['v'];
        if (videoId != null && videoId.isNotEmpty) {
          if (kDebugMode) {
            debugPrint('[VideoDetection] Found video ID from /watch: $videoId');
          }
          return videoId;
        }
      }
      
      // youtu.be/VIDEO_ID
      if (uri.host.contains('youtu.be')) {
        final videoId = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
        // Remove leading slash if present
        final cleanId = videoId?.replaceFirst('/', '');
        if (kDebugMode) {
          debugPrint('[VideoDetection] Found video ID from youtu.be: $cleanId');
        }
        return cleanId?.isNotEmpty == true ? cleanId : null;
      }
      
      // youtube.com/embed/VIDEO_ID or m.youtube.com/embed/VIDEO_ID
      if (uri.path.contains('/embed/')) {
        final videoId = uri.pathSegments.last;
        if (kDebugMode) {
          debugPrint('[VideoDetection] Found video ID from /embed: $videoId');
        }
        return videoId;
      }
      
      // youtube.com/v/VIDEO_ID
      if (uri.path.startsWith('/v/')) {
        final videoId = uri.pathSegments.length > 1 ? uri.pathSegments[1] : null;
        if (kDebugMode) {
          debugPrint('[VideoDetection] Found video ID from /v/: $videoId');
        }
        return videoId;
      }
      
      // Try regex fallback for any YouTube URL format
      final regex = RegExp(r'(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/embed\/|youtube\.com\/v\/)([a-zA-Z0-9_-]{11})');
      final match = regex.firstMatch(url);
      if (match != null && match.groupCount >= 1) {
        final videoId = match.group(1);
        if (kDebugMode) {
          debugPrint('[VideoDetection] Found video ID via regex: $videoId');
        }
        return videoId;
      }
      
      if (kDebugMode) {
        debugPrint('[VideoDetection] Could not extract video ID from URL: $url');
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[VideoDetection] Error extracting video ID: $e');
      }
      return null;
    }
  }

  /// Detect videos from generic websites
  Future<List<DetectedVideo>> _detectGenericVideos(String pageUrl) async {
    try {
      // Fetch page HTML
      final response = await http.get(Uri.parse(pageUrl), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': pageUrl,
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint('[VideoDetection] HTTP ${response.statusCode} for $pageUrl');
        }
        return [];
      }

      final html = response.body;
      if (html.isEmpty) {
        if (kDebugMode) {
          debugPrint('[VideoDetection] Empty HTML response');
        }
        return [];
      }

      final videos = <DetectedVideo>[];
      if (kDebugMode) {
        debugPrint('[VideoDetection] Analyzing HTML (${html.length} chars)');
      }

      // Detect <video> tags with source elements
      final videoTagPattern = '<video[^>]*>.*?<source[^>]*src=["\']([^"\']+)["\']';
      final videoTagRegex = RegExp(videoTagPattern, multiLine: true, dotAll: true);
      
      // Detect <video> tags with direct src
      final videoSrcPattern = '<video[^>]*src=["\']([^"\']+)["\']';
      final videoSrcRegex = RegExp(videoSrcPattern, multiLine: true);

      // Extract video sources from <video> tags
      for (final match in videoTagRegex.allMatches(html)) {
        final videoUrl = match.group(1);
        if (videoUrl != null && _isVideoUrl(videoUrl)) {
          videos.add(DetectedVideo(
            url: _resolveUrl(videoUrl, pageUrl),
            source: VideoSource.direct,
          ));
        }
      }

      for (final match in videoSrcRegex.allMatches(html)) {
        final videoUrl = match.group(1);
        if (videoUrl != null && _isVideoUrl(videoUrl)) {
          videos.add(DetectedVideo(
            url: _resolveUrl(videoUrl, pageUrl),
            source: VideoSource.direct,
          ));
        }
      }

      // Detect JavaScript video variables (common in adult sites)
      final jsVideoPattern = '(?:videoUrl|video_url|videoSrc|video_src|mediaUrl|media_url|srcUrl|src_url|fileUrl|file_url|mp4Url|mp4_url|videoFile|video_file)\\s*[:=]\\s*["\']([^"\']+\\.(?:mp4|webm|m3u8|flv|avi|mov))["\']';
      final jsVideoRegex = RegExp(jsVideoPattern, caseSensitive: false);

      for (final match in jsVideoRegex.allMatches(html)) {
        final videoUrl = match.group(1);
        if (videoUrl != null && _isVideoUrl(videoUrl)) {
          videos.add(DetectedVideo(
            url: _resolveUrl(videoUrl, pageUrl),
            source: VideoSource.embedded,
          ));
        }
      }

      // HLS streams are now completely blocked - skip detection
      // (Removed HLS stream detection to block them completely)

      // Remove duplicates and filter out thumbnails
      final uniqueVideos = <String, DetectedVideo>{};
      for (final video in videos) {
        // Filter out thumbnails (common false positives)
        if (!video.url.toLowerCase().contains('thumb') &&
            !video.url.toLowerCase().contains('preview') &&
            !video.url.toLowerCase().contains('poster')) {
          uniqueVideos[video.url] = video;
        }
      }

      return uniqueVideos.values.toList();
    } catch (e) {
      return [];
    }
  }

  /// Check if URL is a video URL
  bool _isVideoUrl(String url) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.contains('.mp4') ||
        lowerUrl.contains('.webm') ||
        lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('.flv') ||
        lowerUrl.contains('.avi') ||
        lowerUrl.contains('.mov');
  }

  /// Resolve relative URLs to absolute URLs
  String _resolveUrl(String url, String baseUrl) {
    try {
      if (url.startsWith('http://') || url.startsWith('https://')) {
        return url;
      }
      final base = Uri.parse(baseUrl);
      return base.resolve(url).toString();
    } catch (e) {
      return url;
    }
  }

  void dispose() {
    if (!_isDisposed) {
      _ytExplode?.close();
      _ytExplode = null;
      _isDisposed = true;
    }
  }
}

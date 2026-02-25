import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Detected video information
class DetectedVideo {
  final String url;
  final String? title;
  final String? thumbnail;
  final int? width;
  final int? height;
  final int? duration;
  final String? mimeType;
  final Map<String, dynamic>? metadata;
  
  DetectedVideo({
    required this.url,
    this.title,
    this.thumbnail,
    this.width,
    this.height,
    this.duration,
    this.mimeType,
    this.metadata,
  });
  
  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'title': title,
      'thumbnail': thumbnail,
      'width': width,
      'height': height,
      'duration': duration,
      'mimeType': mimeType,
      'metadata': metadata,
    };
  }
  
  factory DetectedVideo.fromJson(Map<String, dynamic> json) {
    return DetectedVideo(
      url: json['url'] as String,
      title: json['title'] as String?,
      thumbnail: json['thumbnail'] as String?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      duration: json['duration'] as int?,
      mimeType: json['mimeType'] as String?,
      metadata: json['metadata'] != null 
          ? Map<String, dynamic>.from(json['metadata'] as Map)
          : null,
    );
  }
}

/// Service for detecting videos on web pages using JavaScript
class GenericVideoDetectionService {
  /// JavaScript code to detect videos on a page
  static const String _detectionScript = '''
(function() {
  const videos = [];
  const videoElements = document.querySelectorAll('video');
  
  videoElements.forEach((video, index) => {
    let videoUrl = null;
    let videoTitle = null;
    let thumbnail = null;
    let width = null;
    let height = null;
    let duration = null;
    let mimeType = null;
    
    // Try to get video source
    if (video.src) {
      videoUrl = video.src;
    } else if (video.currentSrc) {
      videoUrl = video.currentSrc;
    } else {
      // Check source elements
      const source = video.querySelector('source');
      if (source && source.src) {
        videoUrl = source.src;
        mimeType = source.type;
      }
    }
    
    // If still no URL, try to get from poster or data attributes
    if (!videoUrl) {
      videoUrl = video.getAttribute('data-src') || 
                 video.getAttribute('data-video-src') ||
                 video.getAttribute('data-url');
    }
    
    // Get video metadata
    if (video.videoWidth) width = video.videoWidth;
    if (video.videoHeight) height = video.videoHeight;
    if (video.duration && !isNaN(video.duration)) duration = Math.round(video.duration);
    if (video.poster) thumbnail = video.poster;
    
    // Try to get title from various sources
    videoTitle = video.getAttribute('title') || 
                 video.getAttribute('aria-label') ||
                 video.getAttribute('alt') ||
                 document.title;
    
    // If video URL is relative, make it absolute
    if (videoUrl && !videoUrl.startsWith('http')) {
      try {
        videoUrl = new URL(videoUrl, window.location.href).href;
      } catch (e) {
        // Skip invalid URLs
        return;
      }
    }
    
    if (videoUrl) {
      videos.push({
        url: videoUrl,
        title: videoTitle,
        thumbnail: thumbnail,
        width: width,
        height: height,
        duration: duration,
        mimeType: mimeType,
        index: index
      });
    }
  });
  
  // Also check for video URLs in page source (for embedded videos)
  // Look for common video URL patterns
  const pageText = document.documentElement.innerHTML;
  const urlPatterns = [
    /https?:\\/\\/[^"\\s]+\\.(mp4|webm|mov|m3u8|mpd)([^"\\s]*)?/gi,
    /https?:\\/\\/[^"\\s]+\\/video[^"\\s]*/gi,
    /https?:\\/\\/[^"\\s]+\\/stream[^"\\s]*/gi,
  ];
  
  const foundUrls = new Set();
  urlPatterns.forEach(pattern => {
    const matches = pageText.match(pattern);
    if (matches) {
      matches.forEach(url => {
        // Clean up URL (remove query params that might be part of HTML)
        const cleanUrl = url.split(/[<"'>\\s]/)[0];
        if (cleanUrl && cleanUrl.startsWith('http')) {
          foundUrls.add(cleanUrl);
        }
      });
    }
  });
  
  // Add found URLs that aren't already in videos array
  foundUrls.forEach(url => {
    const alreadyFound = videos.some(v => v.url === url);
    if (!alreadyFound) {
      videos.push({
        url: url,
        title: document.title || null,
        thumbnail: null,
        width: null,
        height: null,
        duration: null,
        mimeType: null,
        index: videos.length
      });
    }
  });
  
  return JSON.stringify(videos);
})();
''';

  /// Detect videos on the current page
  /// Returns list of detected videos
  Future<List<DetectedVideo>> detectVideos(WebViewController controller) async {
    try {
      if (kDebugMode) {
        debugPrint('[GenericVideoDetection] Starting video detection...');
      }
      
      // Execute JavaScript to detect videos
      final result = await controller.runJavaScriptReturningResult(_detectionScript);
      
      if (kDebugMode) {
        debugPrint('[GenericVideoDetection] JavaScript result: $result');
      }
      
      // Parse result
      String jsonString;
      if (result is String) {
        // Remove quotes if JavaScript returned a string
        jsonString = result.replaceAll('"', '');
      } else {
        jsonString = result.toString();
      }
      
      // Handle escaped JSON
      jsonString = jsonString.replaceAll('\\"', '"');
      jsonString = jsonString.replaceAll('\\n', '');
      
      // Try to extract JSON from the result
      final jsonMatch = RegExp(r'\[.*\]').firstMatch(jsonString);
      if (jsonMatch != null) {
        jsonString = jsonMatch.group(0)!;
      }
      
      if (kDebugMode) {
        debugPrint('[GenericVideoDetection] Parsed JSON string: $jsonString');
      }
      
      // Parse JSON
      final List<dynamic> videosJson = jsonDecode(jsonString) as List<dynamic>;
      
      final videos = videosJson
          .map((json) => DetectedVideo.fromJson(json as Map<String, dynamic>))
          .where((video) => video.url.isNotEmpty)
          .toList();
      
      if (kDebugMode) {
        debugPrint('[GenericVideoDetection] ✅ Detected ${videos.length} video(s)');
        for (final video in videos) {
          debugPrint('[GenericVideoDetection]   - ${video.url} (${video.title ?? "No title"})');
        }
      }
      
      return videos;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[GenericVideoDetection] ❌ Error detecting videos: $e');
        debugPrint('[GenericVideoDetection] Stack trace: $stackTrace');
      }
      return [];
    }
  }
  
  /// Check if a URL is likely a video URL
  static bool isVideoUrl(String url) {
    final urlLower = url.toLowerCase();
    final videoExtensions = ['.mp4', '.webm', '.mov', '.avi', '.mkv', '.flv', '.m3u8', '.mpd'];
    final videoKeywords = ['/video/', '/stream/', '/media/', 'video', 'stream'];
    
    return videoExtensions.any((ext) => urlLower.contains(ext)) ||
           videoKeywords.any((keyword) => urlLower.contains(keyword));
  }
}

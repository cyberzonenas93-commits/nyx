import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

/// Video stream information
class VideoStream {
  final String url;
  final String? quality;
  final String? format; // mp4, hls, dash
  final int? width;
  final int? height;
  final int? bitrate;

  VideoStream({
    required this.url,
    this.quality,
    this.format,
    this.width,
    this.height,
    this.bitrate,
  });
}

/// Extracted video information
class ExtractedVideo {
  final String title;
  final List<VideoStream> streams;
  final String? thumbnail;
  final int? duration; // in seconds

  ExtractedVideo({
    required this.title,
    required this.streams,
    this.thumbnail,
    this.duration,
  });

  /// Get the best quality stream (prefer mp4, then highest resolution)
  VideoStream? get bestStream {
    if (streams.isEmpty) return null;
    
    // Prefer MP4 over HLS/DASH
    final mp4Streams = streams.where((s) => s.format == 'mp4').toList();
    if (mp4Streams.isNotEmpty) {
      // Sort by resolution (height), descending
      mp4Streams.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
      return mp4Streams.first;
    }
    
    // Fallback to any stream, sorted by quality
    final sorted = List<VideoStream>.from(streams);
    sorted.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
    return sorted.first;
  }
}

/// Extraction result
class ExtractionResult {
  final bool success;
  final ExtractedVideo? video;
  final String? error;
  final bool requiresCaptcha;
  final bool requiresLogin;

  ExtractionResult({
    required this.success,
    this.video,
    this.error,
    this.requiresCaptcha = false,
    this.requiresLogin = false,
  });
}

/// Video extraction service with domain-specific extractors
class VideoExtractionService {
  static const Duration _timeout = Duration(seconds: 30);
  static const int _maxIframeDepth = 2;

  /// Extract video from URL
  Future<ExtractionResult> extractVideo(String url) async {
    try {
      final uri = Uri.parse(url);
      final domain = uri.host.toLowerCase();
      
      debugPrint('[VideoExtraction] Extracting from domain: $domain');
      
      // Fetch page HTML without executing JavaScript
      final html = await _fetchPageHtml(url);
      if (html == null) {
        return ExtractionResult(
          success: false,
          error: 'Failed to fetch page content',
        );
      }

      // Check for CAPTCHA or login requirements
      if (_hasCaptcha(html)) {
        return ExtractionResult(
          success: false,
          error: 'This site requires CAPTCHA verification',
          requiresCaptcha: true,
        );
      }

      if (_requiresLogin(html)) {
        return ExtractionResult(
          success: false,
          error: 'This video requires login',
          requiresLogin: true,
        );
      }

      // Try domain-specific extractor first
      ExtractedVideo? video;
      
      if (domain.contains('pornhub.com')) {
        video = await _extractPornhub(html, url);
      } else if (domain.contains('xvideos.com')) {
        video = await _extractXvideos(html, url);
      } else if (domain.contains('xhamster.com')) {
        video = await _extractXhamster(html, url);
      } else if (domain.contains('redtube.com')) {
        video = await _extractRedtube(html, url);
      } else if (domain.contains('youporn.com')) {
        video = await _extractYouporn(html, url);
      }
      
      // Fallback to generic extractor
      video ??= await _extractGeneric(html, url);

      if (video != null && video.streams.isNotEmpty) {
        return ExtractionResult(
          success: true,
          video: video,
        );
      }

      return ExtractionResult(
        success: false,
        error: 'No video streams found',
      );
    } catch (e) {
      debugPrint('[VideoExtraction] Error: $e');
      return ExtractionResult(
        success: false,
        error: 'Extraction failed: $e',
      );
    }
  }

  /// Fetch page HTML without JavaScript
  Future<String?> _fetchPageHtml(String url) async {
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.5',
        },
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        return response.body;
      }
      
      debugPrint('[VideoExtraction] HTTP ${response.statusCode} for $url');
      return null;
    } catch (e) {
      debugPrint('[VideoExtraction] Error fetching HTML: $e');
      return null;
    }
  }

  /// Check if page has CAPTCHA
  bool _hasCaptcha(String html) {
    final lower = html.toLowerCase();
    return lower.contains('captcha') ||
           lower.contains('recaptcha') ||
           lower.contains('hcaptcha') ||
           lower.contains('cloudflare') && lower.contains('challenge');
  }

  /// Check if page requires login
  bool _requiresLogin(String html) {
    final lower = html.toLowerCase();
    return lower.contains('login required') ||
           lower.contains('sign in to watch') ||
           lower.contains('members only') ||
           lower.contains('premium required');
  }

  /// Extract from Pornhub
  Future<ExtractedVideo?> _extractPornhub(String html, String url) async {
    try {
      // Look for media_ variable in JavaScript
      final mediaMatch = RegExp(r'media_\s*=\s*({[^}]+})', multiLine: true).firstMatch(html);
      if (mediaMatch != null) {
        final jsonStr = mediaMatch.group(1);
        if (jsonStr != null) {
          final data = jsonDecode(jsonStr) as Map<String, dynamic>;
          final mediaUrl = data['mp4'] as String?;
          if (mediaUrl != null) {
            return ExtractedVideo(
              title: _extractTitle(html) ?? 'Video',
              streams: [
                VideoStream(
                  url: mediaUrl,
                  format: 'mp4',
                ),
              ],
            );
          }
        }
      }

      // Look for qualityItems_ variable
      final qualityRegex = RegExp(r'qualityItems_\s*=\s*(\[[^\]]+\])', multiLine: true);
      final qualityMatch = qualityRegex.firstMatch(html);
      if (qualityMatch != null) {
        final jsonStr = qualityMatch.group(1);
        if (jsonStr != null) {
          final qualities = jsonDecode(jsonStr) as List;
          final streams = <VideoStream>[];
          
          for (final item in qualities) {
            if (item is Map) {
              final url = item['url'] as String?;
              final quality = item['quality'] as String?;
              if (url != null) {
                streams.add(VideoStream(
                  url: url,
                  quality: quality,
                  format: 'mp4',
                ));
              }
            }
          }
          
          if (streams.isNotEmpty) {
            return ExtractedVideo(
              title: _extractTitle(html) ?? 'Video',
              streams: streams,
            );
          }
        }
      }

      return null;
    } catch (e) {
      debugPrint('[VideoExtraction] Pornhub extraction error: $e');
      return null;
    }
  }

  /// Extract from Xvideos
  Future<ExtractedVideo?> _extractXvideos(String html, String url) async {
    try {
      // Look for flashvars or media definitions
      final flashvarsRegex = RegExp(r'flashvars\s*=\s*({[^}]+})', multiLine: true);
      final flashvarsMatch = flashvarsRegex.firstMatch(html);
      if (flashvarsMatch != null) {
        final jsonStr = flashvarsMatch.group(1);
        if (jsonStr != null) {
          final data = jsonDecode(jsonStr) as Map<String, dynamic>;
          final videoUrl = data['flv_url'] as String? ?? data['url'] as String?;
          if (videoUrl != null) {
            return ExtractedVideo(
              title: _extractTitle(html) ?? 'Video',
              streams: [
                VideoStream(
                  url: videoUrl,
                  format: 'mp4',
                ),
              ],
            );
          }
        }
      }

      return null;
    } catch (e) {
      debugPrint('[VideoExtraction] Xvideos extraction error: $e');
      return null;
    }
  }

  /// Extract from Xhamster
  Future<ExtractedVideo?> _extractXhamster(String html, String url) async {
    try {
      // Look for mediastring variable - try both single and double quotes
      RegExp? mediaRegex;
      RegExpMatch? mediaMatch;
      
      // Try double quotes first
      mediaRegex = RegExp(r'mediastring\s*=\s*"([^"]+)"', multiLine: true);
      mediaMatch = mediaRegex.firstMatch(html);
      
      // If not found, try single quotes
      if (mediaMatch == null) {
        mediaRegex = RegExp(r"mediastring\s*=\s*'([^']+)'", multiLine: true);
        mediaMatch = mediaRegex.firstMatch(html);
      }
      if (mediaMatch != null) {
        final mediaUrl = mediaMatch.group(1);
        if (mediaUrl != null) {
          return ExtractedVideo(
            title: _extractTitle(html) ?? 'Video',
            streams: [
              VideoStream(
                url: mediaUrl,
                format: 'mp4',
              ),
            ],
          );
        }
      }

      return null;
    } catch (e) {
      debugPrint('[VideoExtraction] Xhamster extraction error: $e');
      return null;
    }
  }

  /// Extract from Redtube
  Future<ExtractedVideo?> _extractRedtube(String html, String url) async {
    // Similar pattern to other sites
    return await _extractGeneric(html, url);
  }

  /// Extract from Youporn
  Future<ExtractedVideo?> _extractYouporn(String html, String url) async {
    // Similar pattern to other sites
    return await _extractGeneric(html, url);
  }

  /// Generic extractor - searches for video tags, source tags, and iframes
  Future<ExtractedVideo?> _extractGeneric(String html, String url, {int depth = 0}) async {
    if (depth > _maxIframeDepth) {
      return null;
    }

    try {
      final document = html_parser.parse(html);
      final streams = <VideoStream>[];

      // Method 1: Look for <video> tags
      final videoTags = document.querySelectorAll('video');
      for (final video in videoTags) {
        // Check src attribute
        final src = video.attributes['src'];
        if (src != null && _isVideoUrl(src)) {
          streams.add(VideoStream(
            url: _resolveUrl(src, url),
            format: _getFormat(src),
          ));
        }

        // Check <source> tags inside video
        final sources = video.querySelectorAll('source');
        for (final source in sources) {
          final src = source.attributes['src'];
          if (src != null && _isVideoUrl(src)) {
            streams.add(VideoStream(
              url: _resolveUrl(src, url),
              format: _getFormat(src),
              quality: source.attributes['data-quality'],
            ));
          }
        }
      }

      // Method 2: Look for standalone <source> tags
      if (streams.isEmpty) {
        final sources = document.querySelectorAll('source[src]');
        for (final source in sources) {
          final src = source.attributes['src'];
          if (src != null && _isVideoUrl(src)) {
            streams.add(VideoStream(
              url: _resolveUrl(src, url),
              format: _getFormat(src),
            ));
          }
        }
      }

      // Method 3: Look for iframes and extract recursively
      if (streams.isEmpty && depth < _maxIframeDepth) {
        final iframes = document.querySelectorAll('iframe[src]');
        for (final iframe in iframes) {
          final iframeSrc = iframe.attributes['src'];
          if (iframeSrc != null) {
            final resolvedUrl = _resolveUrl(iframeSrc, url);
            final iframeHtml = await _fetchPageHtml(resolvedUrl);
            if (iframeHtml != null) {
              final iframeVideo = await _extractGeneric(iframeHtml, resolvedUrl, depth: depth + 1);
              if (iframeVideo != null && iframeVideo.streams.isNotEmpty) {
                return iframeVideo;
              }
            }
          }
        }
      }

      // Method 4: Search for video URLs in JavaScript variables
      if (streams.isEmpty) {
        // Use a simpler pattern that avoids quote issues
        final urlPattern = RegExp(r'https?://[^\s<>]+\.(mp4|webm|m3u8|m4s)', caseSensitive: false);
        final matches = urlPattern.allMatches(html);
        for (final match in matches) {
          final videoUrl = match.group(0);
          if (videoUrl != null && videoUrl.isNotEmpty && _isVideoUrl(videoUrl)) {
            streams.add(VideoStream(
              url: videoUrl,
              format: _getFormat(videoUrl),
            ));
          }
        }
      }

      if (streams.isNotEmpty) {
        return ExtractedVideo(
          title: _extractTitle(html) ?? 'Video',
          streams: streams,
        );
      }

      return null;
    } catch (e) {
      debugPrint('[VideoExtraction] Generic extraction error: $e');
      return null;
    }
  }

  /// Extract title from HTML
  String? _extractTitle(String html) {
    try {
      final document = html_parser.parse(html);
      
      // Try <title> tag
      final titleTag = document.querySelector('title');
      if (titleTag != null) {
        final title = titleTag.text.trim();
        if (title.isNotEmpty) return title;
      }

      // Try Open Graph title
      final ogTitle = document.querySelector('meta[property="og:title"]');
      if (ogTitle != null) {
        final title = ogTitle.attributes['content'];
        if (title != null && title.isNotEmpty) return title;
      }

      // Try h1 tag
      final h1 = document.querySelector('h1');
      if (h1 != null) {
        final title = h1.text.trim();
        if (title.isNotEmpty) return title;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Check if URL is a video URL
  bool _isVideoUrl(String url) {
    final lower = url.toLowerCase();
    return lower.endsWith('.mp4') ||
           lower.endsWith('.webm') ||
           lower.endsWith('.m3u8') ||
           lower.endsWith('.m4s') ||
           lower.contains('.mp4?') ||
           lower.contains('.webm?') ||
           lower.contains('/video/') ||
           lower.contains('/stream/');
  }

  /// Get format from URL
  String? _getFormat(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.mp4') || lower.contains('.m4s')) return 'mp4';
    if (lower.contains('.webm')) return 'webm';
    if (lower.contains('.m3u8')) return 'hls';
    if (lower.contains('.mpd')) return 'dash';
    return null;
  }

  /// Resolve relative URL to absolute
  String _resolveUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    final base = Uri.parse(baseUrl);
    return base.resolve(url).toString();
  }
}

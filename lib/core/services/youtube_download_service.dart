import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Simple YouTube video download service
class YouTubeDownloadService {
  YoutubeExplode? _ytExplode;
  
  /// Extract video ID from YouTube URL
  String? extractVideoId(String url) {
    try {
      if (url.isEmpty) return null;
      
      final uri = Uri.parse(url);
      
      // youtube.com/watch?v=VIDEO_ID or m.youtube.com/watch?v=VIDEO_ID
      if (uri.host.contains('youtube.com') && uri.path.contains('/watch')) {
        final videoId = uri.queryParameters['v'];
        if (videoId != null && videoId.isNotEmpty) {
          if (kDebugMode) {
            debugPrint('[YouTubeDownload] Extracted video ID from /watch: $videoId');
          }
          return videoId;
        }
      }
      
      // youtube.com/shorts/VIDEO_ID (YouTube Shorts)
      if (uri.host.contains('youtube.com') && uri.path.contains('/shorts/')) {
        final pathSegments = uri.pathSegments;
        final shortsIndex = pathSegments.indexWhere((s) => s == 'shorts');
        if (shortsIndex != -1 && shortsIndex < pathSegments.length - 1) {
          final videoId = pathSegments[shortsIndex + 1];
          if (videoId.isNotEmpty) {
            if (kDebugMode) {
              debugPrint('[YouTubeDownload] Extracted video ID from /shorts: $videoId');
            }
            return videoId;
          }
        }
      }
      
      // youtu.be/VIDEO_ID
      if (uri.host.contains('youtu.be')) {
        final pathSegments = uri.pathSegments;
        if (pathSegments.isNotEmpty) {
          final videoId = pathSegments.first.replaceAll('/', '');
          if (videoId.isNotEmpty) {
            if (kDebugMode) {
              debugPrint('[YouTubeDownload] Extracted video ID from youtu.be: $videoId');
            }
            return videoId;
          }
        }
      }
      
      // youtube.com/embed/VIDEO_ID
      if (uri.path.contains('/embed/')) {
        final pathSegments = uri.pathSegments;
        final embedIndex = pathSegments.indexWhere((s) => s == 'embed');
        if (embedIndex != -1 && embedIndex < pathSegments.length - 1) {
          final videoId = pathSegments[embedIndex + 1];
          if (videoId.isNotEmpty) {
            if (kDebugMode) {
              debugPrint('[YouTubeDownload] Extracted video ID from /embed: $videoId');
            }
            return videoId;
          }
        }
      }
      
      // youtube.com/v/VIDEO_ID
      if (uri.path.contains('/v/')) {
        final pathSegments = uri.pathSegments;
        final vIndex = pathSegments.indexWhere((s) => s == 'v');
        if (vIndex != -1 && vIndex < pathSegments.length - 1) {
          final videoId = pathSegments[vIndex + 1];
          if (videoId.isNotEmpty) {
            if (kDebugMode) {
              debugPrint('[YouTubeDownload] Extracted video ID from /v: $videoId');
            }
            return videoId;
          }
        }
      }
      
      // Try regex fallback for any YouTube URL pattern
      final regex = RegExp(r'(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/embed\/|youtube\.com\/v\/|youtube\.com\/shorts\/)([a-zA-Z0-9_-]{11})');
      final match = regex.firstMatch(url);
      if (match != null && match.groupCount >= 1) {
        final videoId = match.group(1);
        if (videoId != null && videoId.isNotEmpty) {
          if (kDebugMode) {
            debugPrint('[YouTubeDownload] Extracted video ID via regex: $videoId');
          }
          return videoId;
        }
      }
      
      // Only log if it's actually a YouTube URL (to avoid spam for non-YouTube sites)
      if (kDebugMode) {
        final uri = Uri.tryParse(url);
        if (uri != null && (uri.host.contains('youtube.com') || uri.host.contains('youtu.be'))) {
          debugPrint('[YouTubeDownload] Could not extract video ID from YouTube URL: $url');
        }
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] Error extracting video ID: $e');
      }
      return null;
    }
  }
  
  /// Get video info from YouTube
  /// [reuseClient] - If true, reuse existing client instead of creating new one
  Future<Video?> getVideoInfo(String videoId, {bool reuseClient = false}) async {
    try {
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] Getting video info for ID: $videoId');
      }
      
      // Create fresh instance unless reusing
      if (!reuseClient) {
        _ytExplode?.close();
        _ytExplode = YoutubeExplode();
      } else if (_ytExplode == null) {
        _ytExplode = YoutubeExplode();
      }
      
      final video = await _ytExplode!.videos.get(videoId);
      
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] ✅ Got video: ${video.title}');
      }
      
      return video;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] ❌ Error getting video info: $e');
      }
      if (!reuseClient) {
        _ytExplode?.close();
        _ytExplode = null;
      }
      return null;
    }
  }
  
  /// Get best quality video stream URL
  /// [reuseClient] - If true, reuse existing client instead of creating new one
  Future<String?> getVideoStreamUrl(String videoId, {bool reuseClient = false}) async {
    try {
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] Getting stream URL for ID: $videoId');
      }
      
      // Create fresh instance unless reusing
      if (!reuseClient) {
        _ytExplode?.close();
        _ytExplode = YoutubeExplode();
      } else if (_ytExplode == null) {
        _ytExplode = YoutubeExplode();
      }
      
      final manifest = await _ytExplode!.videos.streamsClient.getManifest(videoId);
      
      // Prefer MP4 streams for better iOS compatibility
      // iOS doesn't support WebM natively, so prioritize MP4 containers
      VideoStreamInfo? videoStream;
      
      // First, try to find MP4 muxed streams (video + audio)
      final muxedStreams = manifest.muxed.where((s) => s.container.name.toLowerCase() == 'mp4').toList();
      if (muxedStreams.isNotEmpty) {
        videoStream = muxedStreams.sortByVideoQuality().lastOrNull;
        if (kDebugMode) {
          debugPrint('[YouTubeDownload] Found MP4 muxed stream (quality: ${videoStream?.qualityLabel ?? videoStream?.videoQuality})');
        }
      }
      
      // If no MP4 muxed, try any muxed stream
      if (videoStream == null) {
        videoStream = manifest.muxed.sortByVideoQuality().lastOrNull;
        if (kDebugMode && videoStream != null) {
          debugPrint('[YouTubeDownload] Using muxed stream (container: ${videoStream.container.name}, quality: ${videoStream.qualityLabel ?? videoStream.videoQuality})');
        }
      }
      
      // Fallback to video-only if no muxed available
      if (videoStream == null) {
        // Prefer MP4 video-only streams
        final videoOnlyStreams = manifest.videoOnly.where((s) => s.container.name.toLowerCase() == 'mp4').toList();
        if (videoOnlyStreams.isNotEmpty) {
          videoStream = videoOnlyStreams.sortByVideoQuality().lastOrNull;
          if (kDebugMode) {
            debugPrint('[YouTubeDownload] Using MP4 video-only stream (quality: ${videoStream?.qualityLabel ?? videoStream?.videoQuality})');
          }
        } else {
          videoStream = manifest.videoOnly.sortByVideoQuality().lastOrNull;
          if (kDebugMode && videoStream != null) {
            debugPrint('[YouTubeDownload] Using video-only stream (container: ${videoStream.container.name}, quality: ${videoStream.qualityLabel ?? videoStream.videoQuality})');
          }
        }
      }
      
      if (videoStream == null) {
        if (kDebugMode) {
          debugPrint('[YouTubeDownload] ❌ No video stream found');
        }
        return null;
      }
      
      final streamUrl = videoStream.url.toString();
      
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] ✅ Got stream URL (quality: ${videoStream.qualityLabel ?? videoStream.videoQuality})');
      }
      
      return streamUrl;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] ❌ Error getting stream URL: $e');
      }
      if (!reuseClient) {
        _ytExplode?.close();
        _ytExplode = null;
      }
      return null;
    }
  }
  
  /// Get YouTube video info and stream URL for download manager
  /// Returns a map with 'streamUrl', 'title', 'videoId', and 'metadata'
  Future<Map<String, dynamic>?> getVideoDownloadInfo(String videoUrl) async {
    // Create a single client instance for the entire operation
    YoutubeExplode? client;
    try {
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] Getting download info for: $videoUrl');
      }
      
      // Extract video ID
      final videoId = extractVideoId(videoUrl);
      if (videoId == null) {
        if (kDebugMode) {
          debugPrint('[YouTubeDownload] ❌ Could not extract video ID');
        }
        return null;
      }
      
      // Create fresh client for this operation
      _ytExplode?.close();
      client = YoutubeExplode();
      _ytExplode = client;
      
      // Get video info using the same client
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] Getting video info for ID: $videoId');
      }
      final video = await client.videos.get(videoId);
      
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] ✅ Got video: ${video.title}');
      }
      
      // Get stream URL using the same client
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] Getting stream URL for ID: $videoId');
      }
      final manifest = await client.videos.streamsClient.getManifest(videoId);
      
      // Prefer MP4 streams for better iOS compatibility
      VideoStreamInfo? videoStream;
      
      // First, try to find MP4 muxed streams (video + audio)
      final muxedStreams = manifest.muxed.where((s) => s.container.name.toLowerCase() == 'mp4').toList();
      if (muxedStreams.isNotEmpty) {
        videoStream = muxedStreams.sortByVideoQuality().lastOrNull;
        if (kDebugMode) {
          debugPrint('[YouTubeDownload] Found MP4 muxed stream (quality: ${videoStream?.qualityLabel ?? videoStream?.videoQuality})');
        }
      }
      
      // If no MP4 muxed, try any muxed stream
      if (videoStream == null) {
        videoStream = manifest.muxed.sortByVideoQuality().lastOrNull;
        if (kDebugMode && videoStream != null) {
          debugPrint('[YouTubeDownload] Using muxed stream (container: ${videoStream.container.name}, quality: ${videoStream.qualityLabel ?? videoStream.videoQuality})');
        }
      }
      
      // Fallback to video-only if no muxed available
      if (videoStream == null) {
        // Prefer MP4 video-only streams
        final videoOnlyStreams = manifest.videoOnly.where((s) => s.container.name.toLowerCase() == 'mp4').toList();
        if (videoOnlyStreams.isNotEmpty) {
          videoStream = videoOnlyStreams.sortByVideoQuality().lastOrNull;
          if (kDebugMode) {
            debugPrint('[YouTubeDownload] Using MP4 video-only stream (quality: ${videoStream?.qualityLabel ?? videoStream?.videoQuality})');
          }
        } else {
          videoStream = manifest.videoOnly.sortByVideoQuality().lastOrNull;
          if (kDebugMode && videoStream != null) {
            debugPrint('[YouTubeDownload] Using video-only stream (container: ${videoStream.container.name}, quality: ${videoStream.qualityLabel ?? videoStream.videoQuality})');
          }
        }
      }
      
      if (videoStream == null) {
        if (kDebugMode) {
          debugPrint('[YouTubeDownload] ❌ No video stream found');
        }
        return null;
      }
      
      final streamUrl = videoStream.url.toString();
      
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] ✅ Got stream URL (quality: ${videoStream.qualityLabel ?? videoStream.videoQuality})');
        debugPrint('[YouTubeDownload] ✅ Got download info: ${video.title}');
      }
      
      return {
        'streamUrl': streamUrl,
        'title': video.title,
        'videoId': videoId,
        'metadata': {
          'youtube_video_id': videoId,
          'youtube_url': videoUrl,
          'title': video.title,
          'duration': video.duration?.inSeconds,
          'author': video.author,
        },
      };
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[YouTubeDownload] ❌ Error getting download info: $e');
        debugPrint('[YouTubeDownload] Stack trace: $stackTrace');
      }
      return null;
    } finally {
      // Clean up client after operation
      if (client != null) {
        try {
          client.close();
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[YouTubeDownload] Error closing client: $e');
          }
        }
      }
      // Only clear _ytExplode if it was the client we just closed
      if (_ytExplode == client) {
        _ytExplode = null;
      }
    }
  }
  
  void dispose() {
    _ytExplode?.close();
    _ytExplode = null;
  }
}

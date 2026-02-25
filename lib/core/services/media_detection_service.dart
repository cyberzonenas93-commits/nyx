import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Detected media item
class DetectedMedia {
  final String url;
  final MediaType type;
  final String? title;
  final String? thumbnail;
  final Map<String, dynamic> metadata;
  
  DetectedMedia({
    required this.url,
    required this.type,
    this.title,
    this.thumbnail,
    Map<String, dynamic>? metadata,
  }) : metadata = metadata ?? {};
}

/// Media type classification
enum MediaType {
  progressiveVideo,    // Direct MP4, WebM, etc.
  progressiveAudio,    // Direct MP3, M4A, etc.
  adaptiveStream,      // HLS, DASH, etc.
  downloadableAsset,   // Any downloadable file
}

/// Detection result
class DetectionResult {
  final List<DetectedMedia> media;
  final bool hasMore;
  final String? nextPageToken;
  
  DetectionResult({
    required this.media,
    this.hasMore = false,
    this.nextPageToken,
  });
}

/// Universal media detection service - site-agnostic, format-adaptive
/// Detects any playable video/audio or downloadable media on any website
class MediaDetectionService {
  /// Continuously observe browser runtime for media
  /// This runs JavaScript in the WebView to detect media elements
  Future<DetectionResult> detectMediaFromWebView(
    dynamic webViewController, {
    String? currentUrl,
  }) async {
    try {
      // Check if WebView is ready by trying a simple JavaScript evaluation first
      try {
        await webViewController.runJavaScriptReturningResult('document.readyState');
      } catch (e) {
        // WebView not ready or JavaScript disabled, skip detection
        debugPrint('[MediaDetection] WebView not ready for JavaScript evaluation, skipping detection');
        return DetectionResult(media: []);
      }
      
      // Execute comprehensive media detection JavaScript
      final result = await webViewController.runJavaScriptReturningResult('''
        (function() {
          const media = [];
          const seenUrls = new Set();
          
          // Helper to add media and avoid duplicates
          function addMedia(url, type, title, thumbnail, metadata) {
            if (!url || seenUrls.has(url)) return;
            if (url.startsWith('blob:') || url.startsWith('data:')) return;
            if (url.length < 10) return;
            
            seenUrls.add(url);
            media.push({
              url: url,
              type: type,
              title: title || document.title || 'Media',
              thumbnail: thumbnail || null,
              metadata: metadata || {}
            });
          }
          
          // 1. Detect HTML5 video elements
          const videos = document.querySelectorAll('video');
          for (const video of videos) {
            const src = video.src || video.currentSrc || '';
            if (src && (src.includes('.mp4') || src.includes('.webm') || src.includes('.mov'))) {
              addMedia(src, 'progressiveVideo', video.title || null, video.poster || null, {
                duration: video.duration || null,
                width: video.videoWidth || null,
                height: video.videoHeight || null,
              });
            }
            
            // Check source elements
            const sources = video.querySelectorAll('source');
            for (const source of sources) {
              const srcUrl = source.src || '';
              if (srcUrl && !srcUrl.includes('.m3u8')) {
                addMedia(srcUrl, 'progressiveVideo', video.title || null, video.poster || null, {
                  type: source.type || null,
                });
              }
            }
          }
          
          // 2. Detect HTML5 audio elements
          const audios = document.querySelectorAll('audio');
          for (const audio of audios) {
            const src = audio.src || audio.currentSrc || '';
            if (src && (src.includes('.mp3') || src.includes('.m4a') || src.includes('.ogg'))) {
              addMedia(src, 'progressiveAudio', audio.title || null, null, {
                duration: audio.duration || null,
              });
            }
            
            const sources = audio.querySelectorAll('source');
            for (const source of sources) {
              const srcUrl = source.src || '';
              if (srcUrl) {
                addMedia(srcUrl, 'progressiveAudio', audio.title || null, null, {
                  type: source.type || null,
                });
              }
            }
          }
          
          // 3. Detect adaptive streams (HLS, DASH)
          const scripts = document.querySelectorAll('script');
          for (const script of scripts) {
            const text = script.textContent || script.innerHTML || '';
            
            // HLS detection
            if (text.includes('.m3u8')) {
              const m3u8Match = text.match(/["']([^"']*\\.m3u8[^"']*)["']/g);
              if (m3u8Match) {
                for (const match of m3u8Match) {
                  const url = match.replace(/["']/g, '');
                  if (url.includes('.m3u8')) {
                    addMedia(url, 'adaptiveStream', document.title || null, null, {
                      format: 'hls',
                    });
                  }
                }
              }
            }
            
            // DASH detection
            if (text.includes('.mpd')) {
              const mpdMatch = text.match(/["']([^"']*\\.mpd[^"']*)["']/g);
              if (mpdMatch) {
                for (const match of mpdMatch) {
                  const url = match.replace(/["']/g, '');
                  if (url.includes('.mpd')) {
                    addMedia(url, 'adaptiveStream', document.title || null, null, {
                      format: 'dash',
                    });
                  }
                }
              }
            }
          }
          
          // 4. Detect downloadable assets (links with media extensions - all formats)
          const links = document.querySelectorAll('a[href]');
          for (const link of links) {
            const href = link.getAttribute('href') || '';
            // Detect all common video/audio/document formats
            const mediaPattern = /\\.(mp4|webm|mov|avi|mkv|flv|wmv|m4v|3gp|ogv|mpeg|mpg|mp3|m4a|aac|ogg|wav|flac|wma|opus|zip|pdf|doc|docx|xls|xlsx|ppt|pptx)([?]|\\\$)/i;
            if (href && mediaPattern.test(href)) {
              const fullUrl = href.startsWith('http') ? href : new URL(href, window.location.href).href;
              addMedia(fullUrl, 'downloadableAsset', link.textContent?.trim() || null, null, {});
            }
          }
          
          // 5. Detect media in data attributes (all video formats)
          const elementsWithData = document.querySelectorAll('[data-video], [data-src], [data-video-src], [data-mp4], [data-webm], [data-mov], [data-avi]');
          for (const el of elementsWithData) {
            const videoUrl = el.getAttribute('data-video') || 
                           el.getAttribute('data-src') || 
                           el.getAttribute('data-video-src') || 
                           el.getAttribute('data-mp4') ||
                           el.getAttribute('data-webm') ||
                           el.getAttribute('data-mov') ||
                           el.getAttribute('data-avi') || '';
            if (videoUrl && !videoUrl.includes('.m3u8')) {
              addMedia(videoUrl, 'progressiveVideo', el.getAttribute('title') || null, null, {});
            }
          }
          
          // 5b. Detect media URLs in JSON-LD structured data
          const jsonLdScripts = document.querySelectorAll('script[type="application/ld+json"]');
          for (const script of jsonLdScripts) {
            try {
              const jsonData = JSON.parse(script.textContent || '{}');
              if (jsonData.contentUrl || jsonData.embedUrl || jsonData.url) {
                const mediaUrl = jsonData.contentUrl || jsonData.embedUrl || jsonData.url;
                if (mediaUrl && typeof mediaUrl === 'string') {
                  const mediaPattern = /\\.(mp4|webm|mov|avi|mkv|flv|wmv|m4v|3gp|ogv|mpeg|mpg|mp3|m4a|aac|ogg|wav|flac)([?]|\\\$)/i;
                  if (mediaPattern.test(mediaUrl)) {
                    addMedia(mediaUrl, 'progressiveVideo', jsonData.name || jsonData.title || null, jsonData.thumbnailUrl || null, {});
                  }
                }
              }
            } catch (e) {
              // Invalid JSON, skip
            }
          }
          
          // 6. Detect YouTube videos specifically (preserve existing functionality)
          const isYouTube = window.location.hostname.includes('youtube.com') || 
                           window.location.hostname.includes('youtu.be');
          if (isYouTube) {
            try {
              // Extract video ID from URL (most reliable method)
              const videoIdMatch = window.location.href.match(/(?:youtube\.com\/watch\?v=|youtu\.be\/)([a-zA-Z0-9_-]{11})/);
              let extractedVideoId = null;
              let videoTitle = 'YouTube Video';
              let thumbnail = null;
              
              if (videoIdMatch && videoIdMatch[1]) {
                extractedVideoId = videoIdMatch[1];
              }
              
              // Try multiple methods to get video title
              const ogTitle = document.querySelector('meta[property="og:title"]')?.getAttribute('content');
              const pageTitle = document.querySelector('title')?.textContent;
              if (ogTitle) {
                videoTitle = ogTitle;
              } else if (pageTitle) {
                videoTitle = pageTitle.replace(' - YouTube', '').trim();
              }
              
              // Get thumbnail
              if (extractedVideoId) {
                thumbnail = 'https://img.youtube.com/vi/' + extractedVideoId + '/maxresdefault.jpg';
              }
              
              // If we have a video ID, add the media
              if (extractedVideoId) {
                addMedia(window.location.href, 'adaptiveStream', videoTitle, thumbnail, {
                  format: 'youtube',
                  videoId: extractedVideoId,
                  platform: 'youtube'
                });
              }
              
              // Also try to detect video data from YouTube's player (if available)
              try {
                if (window.ytInitialPlayerResponse) {
                  const playerResponse = window.ytInitialPlayerResponse;
                  if (playerResponse && playerResponse.videoDetails) {
                    const playerVideoId = playerResponse.videoDetails.videoId;
                    const playerTitle = playerResponse.videoDetails.title || videoTitle;
                    const playerThumbnail = thumbnail || ('https://img.youtube.com/vi/' + playerVideoId + '/maxresdefault.jpg');
                    
                    // Use player data if available (more reliable)
                    if (playerVideoId) {
                      addMedia(window.location.href, 'adaptiveStream', playerTitle, playerThumbnail, {
                        format: 'youtube',
                        videoId: playerVideoId,
                        platform: 'youtube'
                      });
                    }
                  }
                }
              } catch (playerError) {
                // Player data not available yet, that's okay
              }
            } catch (e) {
              console.error('YouTube detection error:', e);
            }
          }
          
          // 7. Detect MediaSource API usage (MSE)
          if (window.MediaSource) {
            // MediaSource is being used - try to detect source buffers
            // This is more complex and may require additional monitoring
          }
          
          return JSON.stringify(media);
        })();
      ''');
      
      if (result == null) {
        return DetectionResult(media: []);
      }
      
      // Parse JavaScript result
      String jsonString = result.toString();
      if (jsonString.startsWith('"') && jsonString.endsWith('"')) {
        jsonString = jsonString.substring(1, jsonString.length - 1);
        jsonString = jsonString.replaceAll('\\"', '"').replaceAll('\\n', '\n');
      }
      
      final decoded = jsonDecode(jsonString) as List;
      final detectedMedia = decoded.map((item) {
        final data = item as Map<String, dynamic>;
        return DetectedMedia(
          url: data['url'] as String,
          type: _parseMediaType(data['type'] as String),
          title: data['title'] as String?,
          thumbnail: data['thumbnail'] as String?,
          metadata: data['metadata'] as Map<String, dynamic>? ?? {},
        );
      }).toList();
      
      return DetectionResult(media: detectedMedia);
    } catch (e, stackTrace) {
      // Only log detailed errors if they're not expected JavaScript evaluation failures
      final errorString = e.toString();
      if (errorString.contains('FWFEvaluateJavaScriptError') || 
          errorString.contains('Failed evaluating JavaScript')) {
        // Expected error - page might not support JavaScript or WebView not ready
        // Silently return empty result
        return DetectionResult(media: []);
      }
      
      // Log unexpected errors
      debugPrint('[MediaDetection] Error detecting media: $e');
      debugPrint('[MediaDetection] Stack trace: $stackTrace');
      return DetectionResult(media: []);
    }
  }
  
  MediaType _parseMediaType(String type) {
    switch (type) {
      case 'progressiveVideo':
        return MediaType.progressiveVideo;
      case 'progressiveAudio':
        return MediaType.progressiveAudio;
      case 'adaptiveStream':
        return MediaType.adaptiveStream;
      case 'downloadableAsset':
        return MediaType.downloadableAsset;
      default:
        return MediaType.downloadableAsset;
    }
  }
}

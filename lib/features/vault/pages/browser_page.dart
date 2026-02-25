import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/vault_service.dart';
import '../../../core/services/youtube_download_service.dart';
import '../../../core/services/generic_video_detection_service.dart';
import '../../../core/services/download_manager_service.dart';
import '../../../core/services/media_extraction_engine.dart';
import '../../../core/services/browser_session_service.dart';
import '../../../core/services/redirect_blocker_service.dart';
import '../../../core/services/subscription_service.dart';
import '../../../core/models/vault_item.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'vault_home_page.dart';
import 'downloads_page.dart';
import 'browser_history_page.dart';
import '../../../features/subscription/pages/paywall_page.dart';

/// Premium browser with tabs, omnibox, and full navigation
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> with WidgetsBindingObserver {
  final List<_BrowserTab> _tabs = [];
  int _currentTabIndex = 0;
  final TextEditingController _addressBarController = TextEditingController();
  final FocusNode _addressBarFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  
  bool _isLoading = false;
  String _currentUrl = '';
  String _currentTitle = '';
  bool _canGoBack = false;
  bool _canGoForward = false;
  String _searchEngine = 'google';
  bool _isIncognito = false;
  bool _requestDesktopSite = false;
  bool _showBookmarksBar = false;
  bool _showSettingsMenu = false;
  Set<int> _selectedTabIndices = {}; // For multi-select in tabs sheet
  bool _showTabsSheet = false;
  bool _isRedirectBlockerEnabled = true;
  List<String> _searchSuggestions = [];
  
  // YouTube download
  final YouTubeDownloadService _youtubeDownloadService = YouTubeDownloadService();
  bool _isDownloadingYouTube = false;
  bool _isDownloadButtonMinimized = false;
  
  // Generic video detection
  final GenericVideoDetectionService _genericVideoDetection = GenericVideoDetectionService();
  List<DetectedVideo> _detectedVideos = [];
  bool _isDetectingVideos = false;
  bool _isDownloadingGenericVideo = false;
  bool _showVideoSelectionDialog = false;
  
  bool _hasLoadedSession = false;
  BrowserSessionService? _sessionService; // Store reference for safe access in dispose
  final RedirectBlockerService _redirectBlocker = RedirectBlockerService();
  String? _pendingRedirectUrl;
  String? _pendingRedirectTabId;
  // Track user-initiated navigations (when user types URL or clicks link)
  final Map<String, bool> _userInitiatedNavigations = {};
  final Map<String, String> _lastNavigationUrl = {};
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Delay loading session until after first frame to ensure Provider is available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSession();
      _loadRedirectBlockerState();
      // Ensure at least one tab exists after a delay (fallback for macOS)
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && _tabs.isEmpty) {
          debugPrint('[Browser] No tabs found after session load, creating default tab');
          _createNewTab('https://www.google.com');
          _hasLoadedSession = true;
        }
      });
    });
    _addressBarFocusNode.addListener(_onAddressBarFocusChanged);
    _addressBarController.addListener(_onAddressBarChanged);
  }
  
  Future<void> _loadRedirectBlockerState() async {
    await _redirectBlocker.loadEnabledState();
      if (mounted) {
        setState(() {
        _isRedirectBlockerEnabled = _redirectBlocker.isEnabled;
      });
    }
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Store reference to session service for safe access in dispose
    _sessionService = Provider.of<BrowserSessionService>(context, listen: false);
    
    // Restore active tab when route becomes active again (e.g., when navigating back from vault)
    // Only restore if session is loaded and we have tabs
    if (_hasLoadedSession && _tabs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreActiveTab();
      });
    }
  }
  

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _addressBarController.dispose();
    _addressBarFocusNode.dispose();
    _searchController.dispose();
    // Stop YouTube URL polling
    _stopYouTubeUrlPolling();
    // Save session using stored reference (safe to call even if widget is deactivated)
    _saveSessionSafe();
    // WebViewController doesn't need explicit disposal
    super.dispose();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
        _saveSession();
      } else if (state == AppLifecycleState.resumed) {
        // Restore active tab when app resumes
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _restoreActiveTab();
        });
      }
  }
  
  Future<void> _loadSession() async {
    if (!mounted || _hasLoadedSession) return;
    
    try {
      final sessionService = Provider.of<BrowserSessionService>(context, listen: false);
      final sessions = sessionService.sessions;
      final currentIndex = sessionService.currentTabIndex;
      
      if (sessions.isNotEmpty) {
        // Restore tabs from session
        for (final session in sessions) {
          if (!mounted) return;
          _createNewTab(session.url, isIncognito: session.isIncognito);
          if (_tabs.isNotEmpty) {
            _tabs.last.title = session.title;
          }
        }
        if (mounted && currentIndex < _tabs.length) {
          setState(() {
            _currentTabIndex = currentIndex;
          });
          _updateCurrentTab();
        }
        _hasLoadedSession = true;
      } else {
        if (mounted) {
          _createNewTab('https://www.google.com');
          _hasLoadedSession = true;
        }
      }
    } catch (e) {
      debugPrint('[Browser] Error loading session: $e');
      // Fallback: create a default tab if session loading fails
      if (mounted && _tabs.isEmpty) {
        _createNewTab('https://www.google.com');
        _hasLoadedSession = true;
      }
    }
  }
  
  /// Restore the active tab from the saved session when returning to the browser
  Future<void> _restoreActiveTab() async {
    if (!mounted || _tabs.isEmpty) return;
    
    try {
      final sessionService = Provider.of<BrowserSessionService>(context, listen: false);
      final savedIndex = sessionService.currentTabIndex;
      
      // Only switch if the saved index is different and valid
      if (savedIndex >= 0 && savedIndex < _tabs.length && savedIndex != _currentTabIndex) {
        debugPrint('[Browser] Restoring active tab: $savedIndex (was $_currentTabIndex)');
        setState(() {
          _currentTabIndex = savedIndex;
        });
        _updateCurrentTab();
      }
    } catch (e) {
      debugPrint('[Browser] Error restoring active tab: $e');
    }
  }
  
  Future<void> _saveSession() async {
    if (!mounted) return;
    
    try {
      final sessionService = Provider.of<BrowserSessionService>(context, listen: false);
      final sessions = _tabs.map((tab) => BrowserSession(
        id: tab.id,
        url: tab.url,
        title: tab.title,
        isIncognito: tab.isIncognito,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      )).toList();
      await sessionService.saveSessions(sessions, _currentTabIndex);
    } catch (e) {
      debugPrint('[Browser] Error saving session: $e');
    }
  }
  
  /// Safe version of _saveSession that can be called from dispose()
  /// Uses stored reference instead of accessing context
  Future<void> _saveSessionSafe() async {
    if (_sessionService == null) return;
    
    try {
      final sessions = _tabs.map((tab) => BrowserSession(
        id: tab.id,
        url: tab.url,
        title: tab.title,
        isIncognito: tab.isIncognito,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      )).toList();
      await _sessionService!.saveSessions(sessions, _currentTabIndex);
    } catch (e) {
      debugPrint('[Browser] Error saving session (safe): $e');
    }
  }
  
  void _onAddressBarChanged() {
    if (!mounted) return;
    
    final query = _addressBarController.text;
    if (query.isNotEmpty && _addressBarFocusNode.hasFocus) {
      try {
        final sessionService = Provider.of<BrowserSessionService>(context, listen: false);
        final historyResults = sessionService.searchHistory(query);
        if (mounted) {
          setState(() {
            _searchSuggestions = historyResults.take(5).map((e) => e.title).toList();
          });
        }
      } catch (e) {
        debugPrint('[Browser] Error searching history: $e');
      }
    } else {
      if (mounted) {
        setState(() {
          _searchSuggestions = [];
        });
      }
    }
  }
  
  void _onAddressBarFocusChanged() {
    if (_addressBarFocusNode.hasFocus) {
      _addressBarController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _addressBarController.text.length,
      );
      _onAddressBarChanged();
        } else {
      setState(() {
        _searchSuggestions = [];
      });
    }
  }
  
  /// Creates a WebViewController, ensuring WKWebView (WebKit) is used on iOS
  /// for ALL website types. This is the ONLY method that creates WebView controllers
  /// to guarantee WKWebView usage on iOS for every website (YouTube, social media, etc.)
  /// 
  /// This provides:
  /// - Better performance and security
  /// - Consistent behavior across all websites
  /// - Proper media playback support
  /// - Modern web standards compliance
  WebViewController _createWebViewController() {
    // CRITICAL: Always use WKWebView (WebKit) on iOS for ALL website types
    // This ensures consistent behavior across all sites (YouTube, social media, streaming, etc.)
          if (Platform.isIOS) {
            final iosParams = WebKitWebViewControllerCreationParams(
        // Enable inline media playback (videos play inline, not fullscreen)
        // This is essential for proper video playback on all websites
              allowsInlineMediaPlayback: true,
        // No media types require user action (autoplay allowed)
        // This ensures videos can autoplay on all sites without user interaction
              mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
            );
      // Create WebViewController using WKWebView (WebKit) on iOS
      // IMPORTANT: This is the ONLY way to create WebView controllers on iOS
      // to ensure WKWebView usage. Never use WebViewController() directly on iOS.
      final controller = WebViewController.fromPlatformCreationParams(iosParams);
      debugPrint('[Browser] ✅ WKWebView (WebKit) initialized for iOS - ALL website types will use WebKit');
      return controller;
    } else if (Platform.isMacOS) {
      // macOS also uses WKWebView (WebKit) for consistency
      final macParams = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
      final controller = WebViewController.fromPlatformCreationParams(macParams);
      debugPrint('[Browser] ✅ WKWebView (WebKit) initialized for macOS');
      return controller;
          } else {
      // Android uses default WebView (Chromium-based)
      debugPrint('[Browser] Using default WebView for Android');
      return WebViewController();
    }
          }
          
  void _createNewTab(String initialUrl, {bool isIncognito = false}) {
    final tabId = DateTime.now().millisecondsSinceEpoch.toString();
    final controller = _createWebViewController();
    
    final userAgent = _getUserAgent();
          controller
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF1E1E1E));
    if (userAgent != null) {
      controller.setUserAgent(userAgent);
    }
    controller
            ..setNavigationDelegate(
              NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) async {
            // Intercept media file downloads
            if (_isMediaFile(request.url)) {
              _handleMediaDownload(request.url);
              return NavigationDecision.prevent; // Prevent navigation, download instead
            }
            
            // Check for spammy redirects
            if (_tabs.isNotEmpty && _currentTabIndex >= 0 && _currentTabIndex < _tabs.length) {
              final currentTab = _tabs[_currentTabIndex];
              
              // Get actual current URL from controller (more reliable than tab.url)
              String currentUrl = currentTab.url;
              try {
                final actualUrl = await currentTab.controller.currentUrl();
                if (actualUrl != null && actualUrl.isNotEmpty) {
                  currentUrl = actualUrl;
                }
    } catch (e) {
                debugPrint('[Browser] Error getting current URL: $e');
              }
              
              // Check if this is a redirect (URL changed) and not user-initiated
              if (currentUrl.isNotEmpty && currentUrl != request.url) {
                // Check if this navigation was user-initiated
                // User-initiated if:
                // 1. The URL matches what the user just typed/clicked
                // 2. It's the first navigation (currentUrl is empty or matches last navigation)
                final isUserInitiated = _userInitiatedNavigations.containsKey(request.url) ||
                                      _lastNavigationUrl[currentTab.id] == request.url ||
                                      (currentUrl.isEmpty || currentUrl == _lastNavigationUrl[currentTab.id]);
                
                debugPrint('[Browser] Redirect detected: $currentUrl -> ${request.url} (user-initiated: $isUserInitiated, lastNav: ${_lastNavigationUrl[currentTab.id]})');
                
                final decision = _redirectBlocker.shouldBlockRedirect(
                  fromUrl: currentUrl,
                  toUrl: request.url,
                  tabId: currentTab.id,
                  isUserInitiated: isUserInitiated,
                );
                
                switch (decision) {
                  case RedirectDecision.block:
                    // Block the redirect silently
                    debugPrint('[Browser] Blocked redirect: ${request.url}');
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Blocked suspicious redirect to: ${Uri.parse(request.url).host}'),
                          backgroundColor: AppTheme.warning,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                    return NavigationDecision.prevent;
                    
                  case RedirectDecision.askUser:
                    // Ask user for confirmation
                    _pendingRedirectUrl = request.url;
                    _pendingRedirectTabId = currentTab.id;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _showRedirectConfirmationDialog(request.url);
                      }
                    });
                    return NavigationDecision.prevent;
                    
                  case RedirectDecision.allow:
                    // Allow the redirect
                    debugPrint('[Browser] Allowing redirect: ${request.url}');
                    break;
                }
    } else {
                // Same URL or first navigation - mark as user-initiated if it matches last navigation
                if (_lastNavigationUrl[currentTab.id] == request.url) {
                  _userInitiatedNavigations[request.url] = true;
                }
              }
            }
            
            return NavigationDecision.navigate;
          },
          onPageStarted: (String url) {
            _onPageStarted(url, tabId);
          },
          onPageFinished: (String url) {
            _onPageFinished(url, tabId);
          },
          onProgress: (int progress) {
            _onProgress(progress, tabId);
          },
          onWebResourceError: (WebResourceError error) {
            _onWebResourceError(error, tabId);
          },
        ),
      );
    
    final tab = _BrowserTab(
      id: tabId,
      controller: controller,
      url: initialUrl,
      title: '',
      isLoading: false,
      isIncognito: isIncognito,
    );

    setState(() {
      _tabs.add(tab);
        _currentTabIndex = _tabs.length - 1;
    });
    
    controller.loadRequest(Uri.parse(initialUrl));
      _updateCurrentTab();
  }

  void _onPageStarted(String url, String tabId) {
    final tabIndex = _tabs.indexWhere((tab) => tab.id == tabId);
    if (tabIndex != -1) {
      setState(() {
        _tabs[tabIndex].url = url;
        _tabs[tabIndex].isLoading = true;
        if (tabIndex == _currentTabIndex) {
          _currentUrl = url;
          _isLoading = true;
          _addressBarController.text = url;
          // Clear redirect history when page starts loading
          _redirectBlocker.clearHistory(tabId);
        }
      });
    }
  }

  void _onPageFinished(String url, String tabId) {
    debugPrint('[Browser] 📄 Page finished loading: $url (tab: $tabId)');
    final tabIndex = _tabs.indexWhere((tab) => tab.id == tabId);
    if (tabIndex != -1) {
      // Update tab URL
      _tabs[tabIndex].url = url;
      
      // Inject JavaScript to block client-side redirects
      _injectRedirectBlocker(tabId);
      
      // Update current URL immediately for current tab
      if (tabIndex == _currentTabIndex) {
        setState(() {
          _currentUrl = url;
        });
        // Also check YouTube video immediately
        _checkYouTubeVideo(url);
        // Check for generic videos on non-YouTube pages
        if (!_isYouTubeUrl(url)) {
          _detectGenericVideos(tabId);
        }
      }
      
      // Get actual URL from JavaScript (handles SPA navigation on iOS)
      _tabs[tabIndex].controller.currentUrl().then((actualUrl) {
        if (mounted && tabIndex < _tabs.length && _tabs[tabIndex].id == tabId) {
          final finalUrl = actualUrl?.toString() ?? url;
          
          // Update tab URL if JavaScript returned a different URL
          if (finalUrl != url && finalUrl.isNotEmpty) {
            _tabs[tabIndex].url = finalUrl;
            if (tabIndex == _currentTabIndex) {
              setState(() {
                _currentUrl = finalUrl;
              });
              // Re-check YouTube video with actual URL
              _checkYouTubeVideo(finalUrl);
            }
          }
        }
      }).catchError((e) {
        debugPrint('[Browser] Error getting current URL from JavaScript: $e');
      });
      
      _tabs[tabIndex].controller.getTitle().then((title) {
        if (mounted && tabIndex < _tabs.length && _tabs[tabIndex].id == tabId) {
          setState(() {
            _tabs[tabIndex].title = title ?? '';
            _tabs[tabIndex].isLoading = false;
            if (tabIndex == _currentTabIndex) {
              _currentTitle = title ?? '';
              _isLoading = false;
            }
          });
          _updateNavigationState();
          
          // Save to history (only if not incognito)
          if (mounted && !_tabs[tabIndex].isIncognito) {
            try {
              final sessionService = Provider.of<BrowserSessionService>(context, listen: false);
              sessionService.addHistoryEntry(url, title ?? '');
            } catch (e) {
              debugPrint('[Browser] Error saving history: $e');
            }
          }
          
          // Save session periodically
          if (mounted) {
          _saveSession();
        }
        }
      });
    }
  }
  
  /// Check if current page is a YouTube video and enable download
  void _checkYouTubeVideo(String url) {
    // Only check YouTube URLs to avoid unnecessary processing and log messages
    if (!_isYouTubeUrl(url)) {
      // Not a YouTube URL, stop any polling and reset state
      if (mounted) {
        setState(() {
          _isDownloadButtonMinimized = false;
        });
        _stopYouTubeUrlPolling();
      }
      return;
    }
    
    debugPrint('[Browser] Checking YouTube video for URL: $url');
    final videoId = _youtubeDownloadService.extractVideoId(url);
    if (videoId != null && mounted) {
      debugPrint('[Browser] ✅ YouTube video detected: $videoId');
      setState(() {
        // Reset minimized state when navigating to a new video
        _isDownloadButtonMinimized = false;
      });
      
      // On iOS, periodically check URL in case of SPA navigation
      if (Platform.isIOS) {
        _startYouTubeUrlPolling();
      }
    } else if (mounted) {
      debugPrint('[Browser] Not a YouTube video URL');
      // Not a YouTube video, reset minimized state
      setState(() {
        _isDownloadButtonMinimized = false;
      });
      // Stop polling if active
      _stopYouTubeUrlPolling();
    }
  }
  
  Timer? _youtubeUrlPollingTimer;
  
  void _startYouTubeUrlPolling() {
    _stopYouTubeUrlPolling(); // Stop any existing timer
    
    // Increase polling interval to reduce CPU usage (5 seconds instead of 2)
    _youtubeUrlPollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
        _stopYouTubeUrlPolling();
        return;
      }
      
      final tab = _tabs[_currentTabIndex];
      tab.controller.currentUrl().then((url) {
        if (mounted && url != null) {
          final urlString = url.toString();
          if (urlString != _currentUrl) {
            debugPrint('[Browser] URL changed via polling: $urlString');
            Future.microtask(() {
              if (mounted) {
                setState(() {
                  _currentUrl = urlString;
                });
                _checkYouTubeVideo(urlString);
              }
            });
          }
        }
      }).catchError((e) {
        debugPrint('[Browser] Error polling URL: $e');
      });
    });
  }
  
  void _stopYouTubeUrlPolling() {
    _youtubeUrlPollingTimer?.cancel();
    _youtubeUrlPollingTimer = null;
  }
  
  /// Check if URL is a YouTube URL
  bool _isYouTubeUrl(String url) {
    if (url.isEmpty) return false;
    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();
      return host.contains('youtube.com') || host.contains('youtu.be');
    } catch (e) {
      return false;
    }
  }
  
  /// Detect generic videos on non-YouTube pages
  Future<void> _detectGenericVideos(String tabId) async {
    final tabIndex = _tabs.indexWhere((tab) => tab.id == tabId);
    if (tabIndex == -1 || tabIndex != _currentTabIndex) return;
    
    if (_isDetectingVideos) return; // Already detecting
    
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _isDetectingVideos = true;
          _detectedVideos = [];
        });
      }
    });
    
    try {
      final tab = _tabs[tabIndex];
      final videos = await _genericVideoDetection.detectVideos(tab.controller);
      
      if (mounted && tabIndex == _currentTabIndex) {
        Future.microtask(() {
          if (mounted && tabIndex == _currentTabIndex) {
            setState(() {
              _detectedVideos = videos;
              _isDetectingVideos = false;
            });
            
            if (videos.isNotEmpty) {
              debugPrint('[Browser] ✅ Detected ${videos.length} generic video(s)');
            }
          }
        });
      }
    } catch (e) {
      debugPrint('[Browser] Error detecting generic videos: $e');
      if (mounted) {
        Future.microtask(() {
          if (mounted) {
            setState(() {
              _isDetectingVideos = false;
              _detectedVideos = [];
            });
          }
        });
      }
    }
  }
  
  /// Download generic video
  Future<void> _downloadGenericVideo(DetectedVideo video) async {
    final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
    if (!subscriptionService.canExtractMedia) {
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const PaywallPage()),
        );
      }
      return;
    }
    
    if (mounted) {
      Future.microtask(() {
        if (mounted) {
          setState(() {
            _isDownloadingGenericVideo = true;
            _showVideoSelectionDialog = false;
          });
        }
      });
    }
    
    try {
      final downloadManager = Provider.of<DownloadManagerService>(context, listen: false);
      final extractionEngine = MediaExtractionEngine(downloadManager);
      
      // Extract media using the extraction engine
      final result = await extractionEngine.extractMedia(
        video.url,
        title: video.title ?? _currentTitle,
      );
      
      if (!result.success || result.streams.isEmpty) {
        throw Exception(result.error ?? 'Could not extract video');
      }
      
      // Get the best quality stream
      final stream = result.streams.first;
      
      // Determine filename
      String filename = video.title ?? 'video';
      filename = filename.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
      if (filename.isEmpty) filename = 'video';
      
      // Add extension based on URL or MIME type
      final urlLower = video.url.toLowerCase();
      if (urlLower.contains('.mp4')) {
        filename += '.mp4';
      } else if (urlLower.contains('.webm')) {
        filename += '.webm';
      } else if (urlLower.contains('.mov')) {
        filename += '.mov';
      } else if (urlLower.contains('.m3u8')) {
        filename += '.m3u8';
      } else {
        filename += '.mp4'; // Default
      }
      
      // Start download
      await downloadManager.addDownload(
        url: stream.url,
        filename: filename,
        mimeType: stream.mimeType ?? 'video/mp4',
        source: VaultItemSource.browser,
        sourceSite: Uri.parse(_currentUrl).host,
        metadata: {
          ...?video.metadata,
          'title': video.title,
          'thumbnail': video.thumbnail,
          'width': video.width,
          'height': video.height,
          'duration': video.duration,
        },
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Video download started'),
            action: SnackBarAction(
              label: 'View',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const DownloadsPage()),
                );
              },
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Browser] Error downloading generic video: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to download video: ${e.toString()}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingGenericVideo = false;
        });
      }
    }
  }
  
  /// Show video selection dialog if multiple videos detected
  void _showVideoSelectionDialogIfNeeded() {
    if (_detectedVideos.isEmpty) return;
    
    if (_detectedVideos.length == 1) {
      // Single video, download directly
      _downloadGenericVideo(_detectedVideos.first);
    } else {
      // Multiple videos, show selection dialog
      setState(() {
        _showVideoSelectionDialog = true;
      });
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select Video to Download'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _detectedVideos.length,
              itemBuilder: (context, index) {
                final video = _detectedVideos[index];
                return ListTile(
                  title: Text(
                    video.title ?? 'Video ${index + 1}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    video.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: video.width != null && video.height != null
                      ? Text('${video.width}x${video.height}')
                      : null,
                  onTap: () {
                    Navigator.of(context).pop();
                    _downloadGenericVideo(video);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _showVideoSelectionDialog = false;
                });
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ).then((_) {
        if (mounted) {
          setState(() {
            _showVideoSelectionDialog = false;
          });
        }
      });
    }
  }
  
  /// Download YouTube video using download manager
  Future<void> _downloadYouTubeVideo(String url) async {
    final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
    if (!subscriptionService.canExtractMedia) {
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const PaywallPage()),
        );
      }
      return;
    }
    
    if (mounted) {
      setState(() {
        _isDownloadingYouTube = true;
      });
    }
    
    try {
      // Get video info and stream URL
      final downloadInfo = await _youtubeDownloadService.getVideoDownloadInfo(url);
      
      if (downloadInfo == null) {
        throw Exception('Could not get video information');
      }
      
      final streamUrl = downloadInfo['streamUrl'] as String;
      final title = downloadInfo['title'] as String;
      final metadata = downloadInfo['metadata'] as Map<String, dynamic>;
      
      // Add download to download manager
      final downloadManager = Provider.of<DownloadManagerService>(context, listen: false);
      
      final filename = '${title.replaceAll(RegExp(r'[^\w\s.-]'), '_')}.mp4';
      
      await downloadManager.addDownload(
        url: streamUrl,
        filename: filename,
        mimeType: 'video/mp4',
        source: VaultItemSource.browser,
        sourceSite: 'youtube.com',
        metadata: {
          ...metadata,
          'youtube': true,
          'source': 'youtube',
          'original_url': url,
        },
      );
      
      if (mounted) {
        setState(() {
          _isDownloadingYouTube = false;
          // Auto-minimize button after starting download
          _isDownloadButtonMinimized = true;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download started: $title'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'View',
              textColor: AppTheme.primary,
              onPressed: () {
                // Use a post-frame callback to ensure context is valid
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    _navigateToDownloadsPage();
                  }
                });
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloadingYouTube = false;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start download: ${e.toString()}'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _onProgress(int progress, String tabId) {
    final tabIndex = _tabs.indexWhere((tab) => tab.id == tabId);
    if (tabIndex != -1 && tabIndex == _currentTabIndex) {
      setState(() {
        _tabs[tabIndex].isLoading = progress < 100;
        _isLoading = progress < 100;
      });
    }
  }

  void _onWebResourceError(WebResourceError error, String tabId) {
    if (error.errorCode == -999) return; // Cancelled request
    
    debugPrint('[Browser] Error: ${error.description} (${error.errorCode})');
    final tabIndex = _tabs.indexWhere((tab) => tab.id == tabId);
    if (tabIndex != -1) {
      setState(() {
        _tabs[tabIndex].isLoading = false;
        if (tabIndex == _currentTabIndex) {
          _isLoading = false;
        }
      });
    }
  }

  void _showRedirectConfirmationDialog(String redirectUrl) {
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppTheme.warning, size: 24),
            SizedBox(width: 8),
            Text(
              'Redirect Detected',
              style: TextStyle(color: AppTheme.text),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This page is trying to redirect you to:',
              style: TextStyle(color: AppTheme.text),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                redirectUrl,
                style: const TextStyle(
                  color: AppTheme.text,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Do you want to continue?',
              style: TextStyle(color: AppTheme.text),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _pendingRedirectUrl = null;
              _pendingRedirectTabId = null;
            },
            child: const Text('Stay on Page'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              if (_pendingRedirectUrl != null && _pendingRedirectTabId != null) {
                final tabIndex = _tabs.indexWhere((tab) => tab.id == _pendingRedirectTabId);
                if (tabIndex != -1) {
                  _tabs[tabIndex].controller.loadRequest(Uri.parse(_pendingRedirectUrl!));
                  // Add to trusted domains for this session
                  try {
                    final uri = Uri.parse(_pendingRedirectUrl!);
                    final domain = uri.host.toLowerCase();
                    if (domain.startsWith('www.')) {
                      _redirectBlocker.addTrustedDomain(domain.substring(4));
                    } else {
                      _redirectBlocker.addTrustedDomain(domain);
                    }
                  } catch (e) {
                    debugPrint('[Browser] Error adding trusted domain: $e');
                  }
                }
              }
              _pendingRedirectUrl = null;
              _pendingRedirectTabId = null;
            },
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.accent,
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateNavigationState() async {
    if (_tabs.isEmpty || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
      setState(() {
        _canGoBack = false;
        _canGoForward = false;
      });
      return;
    }

    try {
      final controller = _tabs[_currentTabIndex].controller;
      final canBack = await controller.canGoBack();
      // canForward is not available in this API version, set to false
      final canForward = false;
      
      if (mounted) {
        setState(() {
          _canGoBack = canBack;
          _canGoForward = canForward;
        });
      }
    } catch (e) {
      debugPrint('[Browser] Error updating navigation: $e');
    }
  }

  String _formatUrlForDisplay(String url) {
    if (url.isEmpty) return '';
    
    try {
      final uri = Uri.parse(url);
      if (!_addressBarFocusNode.hasFocus && uri.hasScheme) {
        String display = uri.host;
        if (uri.path.isNotEmpty && uri.path != '/') {
          final path = uri.path;
          if (path.length > 20) {
            display = '$display${path.substring(0, 17)}...';
          } else {
            display = '$display$path';
          }
        }
        return display;
      }
      return url;
    } catch (e) {
      return url;
    }
  }

  void _updateCurrentTab() {
    if (_tabs.isEmpty || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
      _stopYouTubeUrlPolling();
      return;
    }
    
    final tab = _tabs[_currentTabIndex];
    final displayUrl = _addressBarFocusNode.hasFocus ? tab.url : _formatUrlForDisplay(tab.url);
    
    setState(() {
      _currentUrl = tab.url;
      _currentTitle = tab.title;
      _addressBarController.text = displayUrl;
      _isLoading = tab.isLoading;
    });
    
    // Check for YouTube video and start/stop polling
    _checkYouTubeVideo(tab.url);
    // Check for generic videos on non-YouTube pages
    if (!_isYouTubeUrl(tab.url)) {
      _detectGenericVideos(tab.id);
    } else {
      // Clear generic videos when on YouTube
      setState(() {
        _detectedVideos = [];
      });
    }
    
    Future.microtask(() {
      if (mounted && _addressBarController.text != displayUrl) {
        _addressBarController.text = displayUrl;
      }
      _addressBarController.selection = TextSelection.fromPosition(
        TextPosition(offset: _addressBarController.text.length),
      );
    });
    
    _updateNavigationState();
  }

  String _buildSearchUrl(String query) {
    final encoded = Uri.encodeComponent(query);
    switch (_searchEngine) {
      case 'bing':
        return 'https://www.bing.com/search?q=$encoded';
      case 'duckduckgo':
        return 'https://duckduckgo.com/?q=$encoded';
      case 'yahoo':
        return 'https://search.yahoo.com/search?p=$encoded';
      default:
        return 'https://www.google.com/search?q=$encoded';
    }
  }

  void _navigateToUrl(String input) {
    var urlString = input.trim();
    
    if (urlString.startsWith('http://')) {
      urlString = urlString.replaceFirst('http://', 'https://');
    } else if (urlString.startsWith('https://')) {
      // Already HTTPS
    } else if (urlString.contains('.') && 
               !urlString.contains(' ') && 
               (urlString.length > 3 && urlString.split('.').length >= 2)) {
      urlString = 'https://$urlString';
    } else {
      urlString = _buildSearchUrl(urlString);
    }


    try {
      final uri = Uri.parse(urlString);
      
      // Mark this navigation as user-initiated
      if (_tabs.isNotEmpty && _currentTabIndex >= 0 && _currentTabIndex < _tabs.length) {
        final currentTab = _tabs[_currentTabIndex];
        _userInitiatedNavigations[urlString] = true;
        _lastNavigationUrl[currentTab.id] = urlString;
        // Clear after a short delay to allow redirect detection
        Future.delayed(const Duration(seconds: 2), () {
          _userInitiatedNavigations.remove(urlString);
        });
      }
      if (_tabs.isEmpty || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
        _createNewTab(urlString);
      } else {
        _tabs[_currentTabIndex].controller.loadRequest(uri);
      }
      _addressBarFocusNode.unfocus();
    } catch (e) {
      debugPrint('[Browser] Error navigating: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _goBack() async {
    if (!_canGoBack || _tabs.isEmpty || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    
    try {
      await _tabs[_currentTabIndex].controller.goBack();
      _updateNavigationState();
    } catch (e) {
      debugPrint('[Browser] Error going back: $e');
    }
  }

  Future<void> _goForward() async {
    if (!_canGoForward || _tabs.isEmpty || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    
    try {
      await _tabs[_currentTabIndex].controller.goForward();
      _updateNavigationState();
    } catch (e) {
      debugPrint('[Browser] Error going forward: $e');
    }
  }

  void _navigateToDownloadsPage() {
    if (!mounted) return;
    
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const DownloadsPage(),
        settings: const RouteSettings(name: '/downloads'),
      ),
    );
  }

  void _reload() {
    if (_tabs.isEmpty || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    _tabs[_currentTabIndex].controller.reload();
  }
  
  void _closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    
    // WebViewController doesn't need explicit disposal
    setState(() {
      _tabs.removeAt(index);
      if (_currentTabIndex >= _tabs.length) {
        _currentTabIndex = _tabs.length - 1;
      }
      if (_currentTabIndex < 0 && _tabs.isNotEmpty) {
        _currentTabIndex = 0;
      }
      if (_tabs.isEmpty) {
        _createNewTab('https://www.google.com');
      }
    });
    _updateCurrentTab();
      _saveSession();
  }
  
  void _switchTab(int index) {
    if (index >= 0 && index < _tabs.length) {
      setState(() {
        _currentTabIndex = index;
      });
      _updateCurrentTab();
      _saveSession();
    }
  }

  String? _getUserAgent() {
    if (_requestDesktopSite) {
      // Desktop user agent
      if (Platform.isIOS) {
        return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
      } else {
        return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
      }
    }
    return null; // Use default mobile user agent
  }
  
  void _toggleDesktopSite() {
    setState(() {
      _requestDesktopSite = !_requestDesktopSite;
    });
    
    // Apply to all tabs
    final userAgent = _getUserAgent();
    for (final tab in _tabs) {
      if (userAgent != null) {
        tab.controller.setUserAgent(userAgent);
      }
    }
    
    // Reload current tab
    _reload();
    
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_requestDesktopSite ? 'Desktop site enabled' : 'Mobile site enabled'),
          duration: const Duration(seconds: 1),
          ),
        );
      }
  }
  
  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) {
      return const Scaffold(
        backgroundColor: AppTheme.primary,
        body: Center(
          child: CircularProgressIndicator(color: AppTheme.accent),
        ),
      );
    }
    
    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        if (!didPop) {
          // Ensure we navigate back to the vault properly
          final navigator = Navigator.of(context);
          if (navigator.canPop()) {
            navigator.pop();
          } else {
            // If we can't pop, navigate to the vault home page
            navigator.pushReplacement(
              MaterialPageRoute(
                builder: (context) => const VaultHomePage(),
                settings: const RouteSettings(name: '/vault'),
              ),
            );
          }
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.primary,
        appBar: AppBar(
          backgroundColor: AppTheme.surface,
          elevation: 0,
          titleSpacing: 0,
          toolbarHeight: 56,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, size: 24),
            onPressed: () {
              // Ensure we navigate back to the vault properly
              final navigator = Navigator.of(context);
              // Check if we can pop
              if (navigator.canPop()) {
                navigator.pop();
              } else {
                // If we can't pop, navigate to the vault home page
                navigator.pushReplacement(
                  MaterialPageRoute(
                    builder: (context) => const VaultHomePage(),
                    settings: const RouteSettings(name: '/vault'),
                  ),
                );
              }
            },
            tooltip: 'Back to Vault',
            color: AppTheme.text,
          ),
        title: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Stack(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _addressBarController,
                      focusNode: _addressBarFocusNode,
                      style: const TextStyle(color: AppTheme.text, fontSize: 16),
                      decoration: InputDecoration(
                        hintText: 'Search or enter URL',
                        hintStyle: TextStyle(color: AppTheme.text.withOpacity(0.5)),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        suffixIcon: _isLoading
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.accent,
                                  ),
                                ),
                              )
                            : _addressBarController.text.isNotEmpty
                                ? SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: IconButton(
                                      icon: const Icon(Icons.close, size: 16),
                                      onPressed: () {
                                        _addressBarController.clear();
                                        _addressBarFocusNode.unfocus();
                                      },
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  )
                                : null,
                      ),
                      onSubmitted: _navigateToUrl,
                      textInputAction: TextInputAction.go,
                      // Remove autocorrect and autocapitalization
              autocorrect: false,
                      enableSuggestions: false,
              keyboardType: TextInputType.url,
                      textCapitalization: TextCapitalization.none,
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    icon: const Icon(Icons.add, size: 18),
                    onPressed: () {
                      _createNewTab('https://www.google.com');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
                          content: Text('New tab created'),
                          duration: Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    tooltip: 'New Tab',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
          ),
        ],
      ),
            // Search suggestions dropdown
            if (_searchSuggestions.isNotEmpty && _addressBarFocusNode.hasFocus)
              Positioned(
                top: 48,
                left: 0,
                right: 0,
                child: Material(
                  elevation: 8,
                  color: AppTheme.surface,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _searchSuggestions.length,
                    itemBuilder: (context, index) {
                      final suggestion = _searchSuggestions[index];
                      return ListTile(
                        leading: const Icon(Icons.history, size: 20),
                        title: Text(suggestion),
                        onTap: () {
                          _addressBarController.text = suggestion;
                          _navigateToUrl(suggestion);
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          // Bookmark button (always visible)
          Consumer<BrowserSessionService>(
            builder: (context, sessionService, _) {
              final currentTab = _tabs.isNotEmpty && _currentTabIndex >= 0 && _currentTabIndex < _tabs.length
                  ? _tabs[_currentTabIndex]
                  : null;
              final currentUrl = currentTab?.url ?? _currentUrl;
              final isBookmarked = currentUrl.isNotEmpty && sessionService.isBookmarked(currentUrl);
              
              return IconButton(
                icon: Icon(
                  isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                  size: 20,
                  color: isBookmarked ? AppTheme.accent : AppTheme.text,
                ),
                onPressed: () async {
                  if (currentTab == null || currentUrl.isEmpty) return;
                  
                  final url = currentTab.url;
                  final title = currentTab.title.isNotEmpty ? currentTab.title : _extractDomainFromUrl(url);
                  
                  if (isBookmarked) {
                    await sessionService.removeBookmark(url);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Bookmark removed'),
                          duration: Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
      ),
    );
  }
                  } else {
                    await sessionService.addBookmark(url, title);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Bookmark added'),
                          duration: Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
      ),
    );
  }
                  }
                },
                tooltip: isBookmarked ? 'Remove bookmark' : 'Bookmark this page',
              );
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(
              minWidth: 40,
              minHeight: 40,
            ),
            onSelected: (value) async {
              switch (value) {
                case 'new_tab':
                  _createNewTab('https://www.google.com');
                  break;
                case 'new_incognito_tab':
                  _createNewTab('https://www.google.com', isIncognito: true);
                  break;
                case 'history':
                  final url = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (context) => const BrowserHistoryPage(),
                    ),
                  );
                  if (url != null && mounted) {
                    _navigateToUrl(url);
                  }
                  break;
                case 'bookmarks':
                  _showBookmarksPage();
                  break;
                case 'desktop_site':
                  _toggleDesktopSite();
                  break;
                case 'incognito':
        setState(() {
                    _isIncognito = !_isIncognito;
                  });
                  break;
                case 'clear_history':
                  final sessionService = Provider.of<BrowserSessionService>(context, listen: false);
                  await sessionService.clearHistory();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('History cleared')),
                    );
                  }
                  break;
                case 'redirect_blocker':
                  // Toggle is handled in the menu item itself
                  break;
                case 'downloads':
                  _navigateToDownloadsPage();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'new_tab',
                child: Row(
        children: [
                    Icon(Icons.add, size: 20),
                    SizedBox(width: 8),
                    Text('New Tab'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'new_incognito_tab',
                child: Row(
                children: [
                    Icon(Icons.visibility_off, size: 20),
                    SizedBox(width: 8),
                    Text('New Incognito Tab'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'history',
                    child: Row(
                      children: [
                    Icon(Icons.history, size: 20),
                    SizedBox(width: 8),
                    Text('History'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'bookmarks',
                            child: Row(
                              children: [
                    Icon(Icons.bookmark, size: 20),
                    SizedBox(width: 8),
                    Text('Bookmarks'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'desktop_site',
                child: Row(
                  children: [
                    Icon(_requestDesktopSite ? Icons.phone_android : Icons.desktop_windows, size: 20),
                        const SizedBox(width: 8),
                    Text(_requestDesktopSite ? 'Mobile Site' : 'Desktop Site'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear_history',
                            child: Row(
                              children: [
                    Icon(Icons.delete_outline, size: 20),
                    SizedBox(width: 8),
                    Text('Clear History'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'redirect_blocker',
                child: StatefulBuilder(
                  builder: (context, setMenuState) {
                    return Row(
                      children: [
                        const Icon(Icons.shield, size: 20),
                                const SizedBox(width: 8),
                        const Expanded(child: Text('Redirect Blocker')),
                        Switch(
                          value: _isRedirectBlockerEnabled,
                          onChanged: (value) async {
                            setMenuState(() {
                              _isRedirectBlockerEnabled = value;
                            });
                            setState(() {
                              _isRedirectBlockerEnabled = value;
                            });
                            if (value) {
                              _redirectBlocker.enable();
                            } else {
                              _redirectBlocker.disable();
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    value 
                                      ? 'Redirect blocker enabled' 
                                      : 'Redirect blocker disabled',
                                  ),
                                  duration: const Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                          activeColor: AppTheme.accent,
                        ),
                      ],
                    );
                  },
                ),
              ),
              PopupMenuItem(
                value: 'downloads',
                child: Row(
                  children: [
                    const Icon(Icons.download, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Downloads')),
                  ],
                ),
              ),
            ],
                        ),
                      ],
                    ),
      body: Column(
        children: [
          // Bookmarks bar (if enabled)
          if (_showBookmarksBar)
                  Container(
                    height: 36,
              color: AppTheme.surface,
              padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                  Consumer<BrowserSessionService>(
                    builder: (context, sessionService, _) {
                      final currentTab = _tabs.isNotEmpty ? _tabs[_currentTabIndex] : null;
                      final currentUrl = currentTab?.url ?? _currentUrl;
                      final isBookmarked = sessionService.isBookmarked(currentUrl);
                      
                      return IconButton(
                        icon: Icon(
                          isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                          size: 18,
                          color: isBookmarked ? AppTheme.accent : null,
                        ),
                        onPressed: () async {
                          if (currentTab == null) return;
                          
                          final url = currentTab.url;
                          final title = currentTab.title.isNotEmpty ? currentTab.title : _extractDomainFromUrl(url);
                          
                          if (isBookmarked) {
                            await sessionService.removeBookmark(url);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Bookmark removed'),
                                  duration: Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          } else {
                            await sessionService.addBookmark(url, title);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Bookmark added'),
                                  duration: Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          }
                        },
                        tooltip: isBookmarked ? 'Remove bookmark' : 'Bookmark this page',
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Consumer<BrowserSessionService>(
                      builder: (context, sessionService, _) {
                        final bookmarks = sessionService.bookmarks;
                        
                        if (bookmarks.isEmpty) {
                          return Center(
                            child: Text(
                              'No bookmarks',
                              style: TextStyle(
                                color: AppTheme.text.withOpacity(0.5),
                                fontSize: 12,
                              ),
                            ),
                          );
                        }
                        
                        return ListView(
                          scrollDirection: Axis.horizontal,
                          children: bookmarks.map((bookmark) => 
                            _buildBookmarkItem(bookmark.title, bookmark.url, sessionService)
                          ).toList(),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          // WebView
          Expanded(
            child: WebViewWidget(controller: _tabs[_currentTabIndex].controller),
          ),
          // Bottom navigation bar
          Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: SafeArea(
              top: false,
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                    icon: const Icon(Icons.arrow_back, size: 24),
                  onPressed: _canGoBack ? _goBack : null,
                    tooltip: 'Back',
                    color: _canGoBack ? AppTheme.text : AppTheme.text.withOpacity(0.3),
                ),
                IconButton(
                    icon: const Icon(Icons.arrow_forward, size: 24),
                  onPressed: _canGoForward ? _goForward : null,
                    tooltip: 'Forward',
                    color: _canGoForward ? AppTheme.text : AppTheme.text.withOpacity(0.3),
                ),
                IconButton(
                    icon: const Icon(Icons.refresh, size: 24),
                    onPressed: _reload,
                    tooltip: 'Reload',
                    color: AppTheme.text,
                  ),
                  // Tabs button with long-press to create new tab
                  GestureDetector(
                    onLongPress: () {
                      // Long press: create new tab immediately
                      _createNewTab('https://www.google.com');
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('New tab created'),
                          duration: Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    child: IconButton(
                      icon: Stack(
                        children: [
                          const Icon(Icons.tab, size: 24),
                          if (_tabs.length > 1)
                            Positioned(
                              right: 0,
                              top: 0,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: AppTheme.accent,
                                  shape: BoxShape.circle,
                                ),
                                constraints: const BoxConstraints(
                                  minWidth: 16,
                                  minHeight: 16,
                                ),
                                child: Text(
                                  _tabs.length > 9 ? '9+' : '${_tabs.length}',
                                  style: const TextStyle(
                                    color: AppTheme.primary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                        ],
                      ),
                      onPressed: () {
                        // Single tap: show tabs management sheet
                        _showTabsManagementSheet();
                      },
                      tooltip: 'Tabs (${_tabs.length})\nLong press for new tab',
                      color: AppTheme.text,
            ),
          ),
        ],
      ),
      ),
          ),
        ],
      ),
      // Floating action button for video notifications
      floatingActionButton: _buildFloatingActionButton(),
      ),
    );
  }
  

  /// Build floating action button for video downloads
  Widget? _buildFloatingActionButton() {
    // Check for YouTube video first
    // Only call extractVideoId if URL is not empty (to avoid unnecessary processing)
    final isYouTube = _currentUrl.isNotEmpty && 
                      _youtubeDownloadService.extractVideoId(_currentUrl) != null;
    
    if (isYouTube && !_isDownloadButtonMinimized) {
      // YouTube download button
      return Stack(
        alignment: Alignment.bottomRight,
        children: [
          FloatingActionButton.extended(
            onPressed: () => _downloadYouTubeVideo(_currentUrl),
            backgroundColor: AppTheme.accent,
            icon: const Icon(Icons.download, color: AppTheme.primary),
            label: const Text(
              'Download Video',
              style: TextStyle(color: AppTheme.primary),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Material(
              color: AppTheme.surface,
              shape: const CircleBorder(),
              child: InkWell(
                onTap: () {
                  setState(() {
                    _isDownloadButtonMinimized = true;
                  });
                },
                customBorder: const CircleBorder(),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.surface,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.close,
                    size: 16,
                    color: AppTheme.text,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    } else if (isYouTube && _isDownloadingYouTube) {
      // YouTube downloading indicator
      return FloatingActionButton(
        onPressed: null,
        backgroundColor: AppTheme.surface,
        mini: true,
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
            strokeWidth: 2.5,
          ),
        ),
      );
    } else if (isYouTube && _isDownloadButtonMinimized) {
      // YouTube minimized button
      return FloatingActionButton(
        onPressed: () {
          setState(() {
            _isDownloadButtonMinimized = false;
          });
        },
        backgroundColor: AppTheme.surface,
        mini: true,
        child: const Icon(Icons.download, color: AppTheme.accent, size: 20),
      );
    } else if (!isYouTube && _detectedVideos.isNotEmpty && !_isDownloadingGenericVideo) {
      // Generic video download button
      return FloatingActionButton.extended(
        onPressed: () => _showVideoSelectionDialogIfNeeded(),
        backgroundColor: AppTheme.accent,
        icon: const Icon(Icons.download, color: AppTheme.primary),
        label: Text(
          _detectedVideos.length == 1 
              ? 'Download Video' 
              : 'Download Video (${_detectedVideos.length})',
          style: const TextStyle(color: AppTheme.primary),
        ),
      );
    } else if (!isYouTube && _isDownloadingGenericVideo) {
      // Generic video downloading indicator
      return FloatingActionButton(
        onPressed: null,
        backgroundColor: AppTheme.surface,
        mini: true,
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
            strokeWidth: 2.5,
          ),
        ),
      );
    } else if (!isYouTube && _isDetectingVideos) {
      // Detecting videos indicator
      return FloatingActionButton(
        onPressed: null,
        backgroundColor: AppTheme.surface,
        mini: true,
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
            strokeWidth: 2.5,
          ),
        ),
      );
    }
    
    return null;
  }
  
  /// Check if a URL points to a media file (video or audio)
  bool _isMediaFile(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path.toLowerCase();
      
      // Check file extension
      final mediaExtensions = [
        // Video formats
        '.mp4', '.m4v', '.mov', '.avi', '.mkv', '.webm', '.flv', '.wmv', '.3gp', '.ogv',
        // Audio formats
        '.mp3', '.m4a', '.aac', '.ogg', '.oga', '.wav', '.flac', '.wma', '.opus',
        // Streaming formats
        '.m3u8', '.m3u', '.mpd', '.ism',
      ];
      
      for (final ext in mediaExtensions) {
        if (path.endsWith(ext)) {
          return true;
        }
      }
      
      // Check query parameters for media indicators
      if (uri.queryParameters.containsKey('format') || 
          uri.queryParameters.containsKey('download') ||
          uri.queryParameters.containsKey('file') ||
          uri.queryParameters.containsKey('video') ||
          uri.queryParameters.containsKey('audio')) {
        // Could be a media file, check further
        final format = uri.queryParameters['format']?.toLowerCase() ?? '';
        final download = uri.queryParameters['download']?.toLowerCase() ?? '';
        if (format.contains('video') || format.contains('audio') || 
            format.contains('mp4') || format.contains('mp3') ||
            download == 'true' || download == '1') {
          return true;
        }
      }
      
      // Check for common media URL patterns (even without extension)
      final lowerUrl = url.toLowerCase();
      if (lowerUrl.contains('/video/') || 
          lowerUrl.contains('/audio/') ||
          lowerUrl.contains('/media/') ||
          lowerUrl.contains('/stream/') ||
          lowerUrl.contains('/download/')) {
        // Check if it's likely a media file by checking for common patterns
        if (lowerUrl.contains('mp4') || lowerUrl.contains('mp3') || 
            lowerUrl.contains('video') || lowerUrl.contains('audio')) {
          return true;
        }
      }
      
      return false;
      } catch (e) {
      debugPrint('[Browser] Error checking if URL is media file: $e');
      return false;
    }
  }
  
  /// Handle media file download when navigation is intercepted
  /// Note: This is disabled as we're focusing on YouTube downloads only
  Future<void> _handleMediaDownload(String url) async {
    // Disabled - using YouTube download service instead
    debugPrint('[Browser] Media download intercepted but not handled (YouTube-only mode): $url');
  }
  
  /// Extract filename from URL
  String _extractFilenameFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      
      // Try to get filename from path
      if (path.isNotEmpty && path != '/') {
        final segments = path.split('/');
        final lastSegment = segments.last;
        if (lastSegment.isNotEmpty && lastSegment.contains('.')) {
          return lastSegment;
        }
      }
      
      // Try to get filename from query parameters
      final filenameParam = uri.queryParameters['filename'] ?? 
                           uri.queryParameters['file'] ?? 
                           uri.queryParameters['name'];
      if (filenameParam != null && filenameParam.isNotEmpty) {
        return filenameParam;
      }
      
      // Fallback: generate filename based on URL and extension
      final extension = _getExtensionFromUrl(url);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      return 'media_$timestamp$extension';
    } catch (e) {
      debugPrint('[Browser] Error extracting filename: $e');
      final extension = _getExtensionFromUrl(url);
      return 'media_${DateTime.now().millisecondsSinceEpoch}$extension';
    }
  }
  
  /// Get file extension from URL
  String _getExtensionFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path.toLowerCase();
      
      // Video extensions
      if (path.endsWith('.mp4')) return '.mp4';
      if (path.endsWith('.m4v')) return '.m4v';
      if (path.endsWith('.mov')) return '.mov';
      if (path.endsWith('.avi')) return '.avi';
      if (path.endsWith('.mkv')) return '.mkv';
      if (path.endsWith('.webm')) return '.webm';
      if (path.endsWith('.flv')) return '.flv';
      if (path.endsWith('.wmv')) return '.wmv';
      if (path.endsWith('.3gp')) return '.3gp';
      if (path.endsWith('.ogv')) return '.ogv';
      if (path.endsWith('.m3u8')) return '.m3u8';
      if (path.endsWith('.m3u')) return '.m3u';
      if (path.endsWith('.mpd')) return '.mpd';
      
      // Audio extensions
      if (path.endsWith('.mp3')) return '.mp3';
      if (path.endsWith('.m4a')) return '.m4a';
      if (path.endsWith('.aac')) return '.aac';
      if (path.endsWith('.ogg')) return '.ogg';
      if (path.endsWith('.oga')) return '.oga';
      if (path.endsWith('.wav')) return '.wav';
      if (path.endsWith('.flac')) return '.flac';
      if (path.endsWith('.wma')) return '.wma';
      if (path.endsWith('.opus')) return '.opus';
      
      // Default based on query parameters or content type
      final format = uri.queryParameters['format']?.toLowerCase() ?? '';
      if (format.contains('mp4') || format.contains('video')) return '.mp4';
      if (format.contains('mp3') || format.contains('audio')) return '.mp3';
      
      return '.mp4'; // Default to mp4
    } catch (e) {
      return '.mp4';
    }
  }
  
  /// Get MIME type from URL
  String? _getMimeTypeFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path.toLowerCase();
      
      // Video MIME types
      if (path.endsWith('.mp4') || path.endsWith('.m4v')) return 'video/mp4';
      if (path.endsWith('.mov')) return 'video/quicktime';
      if (path.endsWith('.avi')) return 'video/x-msvideo';
      if (path.endsWith('.mkv')) return 'video/x-matroska';
      if (path.endsWith('.webm')) return 'video/webm';
      if (path.endsWith('.flv')) return 'video/x-flv';
      if (path.endsWith('.wmv')) return 'video/x-ms-wmv';
      if (path.endsWith('.3gp')) return 'video/3gpp';
      if (path.endsWith('.ogv')) return 'video/ogg';
      if (path.endsWith('.m3u8')) return 'application/vnd.apple.mpegurl';
      if (path.endsWith('.m3u')) return 'audio/x-mpegurl';
      if (path.endsWith('.mpd')) return 'application/dash+xml';
      
      // Audio MIME types
      if (path.endsWith('.mp3')) return 'audio/mpeg';
      if (path.endsWith('.m4a')) return 'audio/mp4';
      if (path.endsWith('.aac')) return 'audio/aac';
      if (path.endsWith('.ogg') || path.endsWith('.oga')) return 'audio/ogg';
      if (path.endsWith('.wav')) return 'audio/wav';
      if (path.endsWith('.flac')) return 'audio/flac';
      if (path.endsWith('.wma')) return 'audio/x-ms-wma';
      if (path.endsWith('.opus')) return 'audio/opus';
      
      return null;
      } catch (e) {
      return null;
    }
  }

  
  
  Widget _buildBookmarkItem(String title, String url, BrowserSessionService sessionService) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _navigateToUrl(url),
          onLongPress: () async {
            // Show delete confirmation
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                backgroundColor: AppTheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                ),
                title: const Text(
                  'Remove Bookmark?',
                  style: TextStyle(color: AppTheme.text),
                ),
                content: Text(
                  'Remove "$title" from bookmarks?',
                  style: const TextStyle(color: AppTheme.text),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: TextButton.styleFrom(foregroundColor: AppTheme.warning),
                    child: const Text('Remove'),
                  ),
                ],
              ),
            );
            
            if (confirmed == true) {
              await sessionService.removeBookmark(url);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Bookmark removed'),
                    duration: Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
            ),
          );
        }
            }
          },
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              title,
              style: TextStyle(
                color: AppTheme.text.withOpacity(0.8),
                fontSize: 13,
              ),
            ),
          ),
        ),
          ),
        );
      }
  
  String _extractDomainFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host.replaceFirst('www.', '');
    } catch (e) {
      return url;
    }
  }
  
  void _showBookmarksPage() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLarge)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
        decoration: BoxDecoration(
                color: AppTheme.text.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
        child: Row(
          children: [
                  const Icon(Icons.bookmark, color: AppTheme.accent, size: 24),
            const SizedBox(width: 8),
                  const Text(
                    'Bookmarks',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Consumer<BrowserSessionService>(
                    builder: (context, sessionService, _) {
                      return Text(
                        '${sessionService.bookmarks.length}',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppTheme.text.withOpacity(0.7),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Bookmarks list
            Expanded(
              child: Consumer<BrowserSessionService>(
                builder: (context, sessionService, _) {
                  final bookmarks = sessionService.bookmarks;
                  
                  if (bookmarks.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.bookmark_border,
                            size: 64,
                            color: AppTheme.text.withOpacity(0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No bookmarks yet',
                            style: TextStyle(
                              fontSize: 18,
                              color: AppTheme.text.withOpacity(0.7),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap the bookmark icon to save pages',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppTheme.text.withOpacity(0.5),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  
                  return ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: bookmarks.length,
                    itemBuilder: (context, index) {
                      final bookmark = bookmarks[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        color: AppTheme.surfaceVariant,
                        child: ListTile(
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppTheme.accent.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(
                              Icons.bookmark,
                              color: AppTheme.accent,
                              size: 20,
                            ),
                          ),
                          title: Text(
                            bookmark.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                              color: AppTheme.text,
                            ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            bookmark.url,
                style: TextStyle(
                  fontSize: 12,
                              color: AppTheme.text.withOpacity(0.6),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  backgroundColor: AppTheme.surface,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                                  ),
                                  title: const Text(
                                    'Remove Bookmark?',
                                    style: TextStyle(color: AppTheme.text),
                                  ),
                                  content: Text(
                                    'Remove "${bookmark.title}" from bookmarks?',
                                    style: const TextStyle(color: AppTheme.text),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(context).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.of(context).pop(true),
                                      style: TextButton.styleFrom(foregroundColor: AppTheme.warning),
                                      child: const Text('Remove'),
                                    ),
                                  ],
                                ),
                              );
                              
                              if (confirmed == true) {
                                await sessionService.removeBookmark(bookmark.url);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Bookmark removed'),
                                      duration: Duration(seconds: 1),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              }
                            },
                            tooltip: 'Remove bookmark',
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _navigateToUrl(bookmark.url);
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTabsManagementSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLarge)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
              children: [
            // Handle bar
                Container(
              margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                color: AppTheme.text.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                      children: [
                  const Text(
                    'Tabs',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_tabs.length}',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppTheme.text.withOpacity(0.7),
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () {
                  Navigator.pop(context);
                      _createNewTab('https://www.google.com');
                    },
                    tooltip: 'New Tab',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Tabs list
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.all(8),
                itemCount: _tabs.length,
                itemBuilder: (context, index) {
                  final tab = _tabs[index];
                  final isActive = index == _currentTabIndex;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: isActive ? AppTheme.accent.withOpacity(0.2) : AppTheme.surfaceVariant,
                    child: ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _isLoading && isActive 
                              ? AppTheme.accent 
                              : AppTheme.text.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: _isLoading && isActive
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.primary,
                                ),
                              )
                            : Icon(
                                Icons.language,
                                color: AppTheme.text.withOpacity(0.5),
                                size: 20,
                              ),
                      ),
                      title: Text(
                        tab.title.isNotEmpty ? tab.title : 'New Tab',
                        style: TextStyle(
                          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                          color: AppTheme.text,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        tab.url,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.text.withOpacity(0.6),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: _selectedTabIndices.isEmpty
                          ? SizedBox(
                              width: 80,
                              child: Row(
            mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.end,
            children: [
                                  if (isActive)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: AppTheme.accent,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Text(
                                          'Active',
                                          style: TextStyle(
                                            fontSize: 8,
                                            fontWeight: FontWeight.bold,
                                            color: AppTheme.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (_tabs.length > 1)
                                    IconButton(
                                      icon: const Icon(Icons.close, size: 16),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 28,
                                        minHeight: 28,
                                      ),
                                      onPressed: () {
                                        Navigator.pop(context);
                                        _closeTab(index);
                                      },
                                      tooltip: 'Close Tab',
                                    ),
                                ],
                              ),
                            )
                          : null,
                      onTap: () {
                        Navigator.pop(context);
                        _switchTab(index);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ).then((_) {
      setState(() {
        _showTabsSheet = false;
      });
    });
  }
  
  /// Inject JavaScript to block client-side redirects (window.location changes)
  Future<void> _injectRedirectBlocker(String tabId) async {
    final tabIndex = _tabs.indexWhere((tab) => tab.id == tabId);
    if (tabIndex == -1) return;
    
    final tab = _tabs[tabIndex];
    
    try {
      // Inject script to intercept window.location changes and meta refresh redirects
      await tab.controller.runJavaScript('''
        (function() {
          // Block window.location redirects
          const originalLocation = window.location;
          const originalReplace = window.location.replace;
          const originalAssign = window.location.assign;
          
          // Override window.location.replace
          window.location.replace = function(url) {
            console.log('[RedirectBlocker] Blocked window.location.replace:', url);
            // Don't allow automatic redirects
            return false;
          };
          
          // Override window.location.assign
          window.location.assign = function(url) {
            console.log('[RedirectBlocker] Blocked window.location.assign:', url);
            // Don't allow automatic redirects
            return false;
          };
          
          // Block meta refresh redirects
          const metaRefresh = document.querySelector('meta[http-equiv="refresh"]');
          if (metaRefresh) {
            const content = metaRefresh.getAttribute('content');
            if (content && content.includes('url=')) {
              console.log('[RedirectBlocker] Found meta refresh redirect:', content);
              metaRefresh.remove();
            }
          }
          
          // Monitor for new meta refresh tags
          const observer = new MutationObserver(function(mutations) {
            mutations.forEach(function(mutation) {
              mutation.addedNodes.forEach(function(node) {
                if (node.nodeType === 1 && node.tagName === 'META') {
                  const httpEquiv = node.getAttribute('http-equiv');
                  if (httpEquiv && httpEquiv.toLowerCase() === 'refresh') {
                    console.log('[RedirectBlocker] Blocked meta refresh redirect');
                    node.remove();
                  }
                }
              });
            });
          });
          
          observer.observe(document.head, { childList: true, subtree: true });
        })();
      ''');
      
      debugPrint('[Browser] Injected redirect blocker JavaScript for tab: $tabId');
    } catch (e) {
      debugPrint('[Browser] Error injecting redirect blocker: $e');
    }
  }
}

class _BrowserTab {
  final String id;
  final WebViewController controller;
  String url;
  String title;
  bool isLoading;
  final bool isIncognito;

  _BrowserTab({
    required this.id,
    required this.controller,
    required this.url,
    required this.title,
    required this.isLoading,
    required this.isIncognito,
  });
}

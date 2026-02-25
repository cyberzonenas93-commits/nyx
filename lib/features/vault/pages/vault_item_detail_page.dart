import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:open_filex/open_filex.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/services/permission_service.dart';
import '../../../app/theme.dart';
import '../../../core/models/vault_item.dart';
import '../../../core/models/vault_folder.dart';
import '../../../core/services/vault_service.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/subscription_service.dart';
import '../../../core/models/subscription_tier.dart';
import '../../../core/services/media_playback_manager.dart';
import '../../../core/services/media_converter_service.dart';
import '../../../features/subscription/pages/paywall_page.dart';
import '../widgets/video_player_widget.dart';
import '../widgets/audio_player_widget.dart';
import '../widgets/photo_viewer_widget.dart';

/// Detail view for a vault item with sharing support
class VaultItemDetailPage extends StatefulWidget {
  final VaultItem item;
  final List<VaultItem>? allItems; // All items for swipe navigation
  final int? initialIndex; // Initial index in allItems
  
  const VaultItemDetailPage({
    super.key, 
    required this.item,
    this.allItems,
    this.initialIndex,
  });

  @override
  State<VaultItemDetailPage> createState() => _VaultItemDetailPageState();
}

class _VaultItemDetailPageState extends State<VaultItemDetailPage> {
  // Single video controller (path-first design)
  VideoPlayerController? _videoController;
  String? _activeVideoItemId; // ID of item currently using the controller
  int _currentVideoInitId = 0; // Monotonic counter for cancellation
  
  // Path-based file references (no Uint8List loading for viewing)
  File? _audioFile;
  File? _documentFile;
  File? _tempFile; // Temp file for sharing/export
  
  // Error states
  String? _videoError;
  bool _videoInitializationFailed = false;
  
  // Services
  MediaPlaybackManager? _playbackManager;
  final MediaConverterService _converterService = MediaConverterService();
  bool _isConverting = false;
  double _conversionProgress = 0.0;
  String? _selectedAudioFormat;
  
  // Page navigation
  PageController? _pageController;
  int _currentIndex = 0;
  late VaultItem _currentItem;
  bool _isVideoFullscreen = false;
  bool _isPhotoFullscreen = false;
  bool _isVideoPlaying = false;
  
  // Thumbnail precaching (only for adjacent pages)
  final Set<String> _precachedThumbnails = {};
  // On-demand video poster generation (anti-crash: only attempt once per item)
  final Set<String> _requestedVideoPosters = {};
  bool _isGeneratingPoster = false;
  String? _posterStatus;

  // Color-coded tags (stored in VaultItem.metadata['tags'] as List<String>)
  static const Map<String, Color> _tagColorById = <String, Color>{
    'red': Color(0xFFE53935),
    'orange': Color(0xFFFB8C00),
    'yellow': Color(0xFFFDD835),
    'green': Color(0xFF43A047),
    'blue': Color(0xFF1E88E5),
    'purple': Color(0xFF8E24AA),
    'pink': Color(0xFFD81B60),
    'gray': Color(0xFF78909C),
  };

  @override
  void initState() {
    super.initState();
    _currentItem = widget.item;
    if (widget.allItems != null && widget.allItems!.isNotEmpty) {
      _currentIndex = widget.initialIndex ?? widget.allItems!.indexWhere((item) => item.id == widget.item.id);
      if (_currentIndex < 0) _currentIndex = 0;
      _pageController = PageController(initialPage: _currentIndex);
    }
    // Allow all orientations for video playback
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    
    // Initialize active page (thumbnail-first, then content)
    // Note: Thumbnail precaching moved to didChangeDependencies() to avoid MediaQuery access in initState
    _initializeActivePage();
  }
  
  void _onPageChanged(int index) async {
    if (widget.allItems == null || index < 0 || index >= widget.allItems!.length) return;
    
    final pageChangeStart = DateTime.now();
    debugPrint('[VaultItemDetail] Page changed to index: $index');
    
    final newItem = widget.allItems![index];
    
    // Cancel any ongoing video initialization
    _currentVideoInitId++;
    
    // Dispose previous video controller synchronously (await to ensure cleanup)
    try {
      await _disposeVideoController();
    } catch (e) {
      debugPrint('[VaultItemDetail] Error disposing video controller: $e');
    }
    
    // Update state immediately (thumbnail will show instantly)
    if (mounted) {
      setState(() {
        _currentIndex = index;
        _currentItem = newItem;
        _videoError = null;
        _videoInitializationFailed = false;
        _audioFile = null;
        _documentFile = null;
        _isPhotoFullscreen = false; // leaving photo page should restore app bar
      });
      
      // Precache thumbnails for adjacent pages (non-blocking)
      _precacheAdjacentThumbnails();
      
      // Initialize active page content (thumbnail already shown)
      _initializeActivePage();
      
      final pageChangeDuration = DateTime.now().difference(pageChangeStart);
      debugPrint('[VaultItemDetail] Page change completed in ${pageChangeDuration.inMilliseconds}ms');
    }
  }
  
  /// Dispose video controller synchronously (required for single controller lifecycle)
  Future<void> _disposeVideoController() async {
    if (_videoController != null) {
      try {
        await _videoController!.pause();
        if (_playbackManager != null) {
          _playbackManager!.unregisterVideo(_videoController!);
        }
        await _videoController!.dispose();
      } catch (e) {
        debugPrint('[VaultItemDetail] Error disposing video controller: $e');
      } finally {
        _videoController = null;
        _activeVideoItemId = null;
      }
    }
  }
  
  /// Precache thumbnails for adjacent pages (only thumbnails, not full files)
  void _precacheAdjacentThumbnails() {
    if (widget.allItems == null) return;
    
    final vaultService = Provider.of<VaultService>(context, listen: false);
    
    // Precache ±2 pages
    for (int i = _currentIndex - 2; i <= _currentIndex + 2; i++) {
      if (i >= 0 && i < widget.allItems!.length && i != _currentIndex) {
        final item = widget.allItems![i];
        final thumbnailPath = vaultService.getThumbnailPath(item.id);
        
        if (thumbnailPath != null && !_precachedThumbnails.contains(item.id)) {
          _precachedThumbnails.add(item.id);
          final thumbnailFile = File(thumbnailPath);
          if (thumbnailFile.existsSync()) {
            // Precache image for instant display
            precacheImage(FileImage(thumbnailFile), context).catchError((e) {
              debugPrint('[VaultItemDetail] Error precaching thumbnail: $e');
            });
          }
        }
      }
    }
  }
  
  /// Initialize active page content (thumbnail already shown)
  void _initializeActivePage() {
    if (!mounted) return;
    
    final item = _currentItem;
    
    if (item.type == VaultItemType.video) {
      // Safe on-demand poster generation (especially important on iOS where we skip auto-generation)
      _maybeGenerateVideoPoster(item);
      _initializeVideoPlayer();
    } else if (item.type == VaultItemType.audio) {
      _initializeAudioFile();
    } else if (item.type == VaultItemType.document) {
      _initializeDocumentFile();
    }
    // Photos don't need initialization - Image.file handles it
  }

  /// Generate a first-frame poster thumbnail when a video is opened/swiped to.
  /// This is intentionally conservative on iOS to avoid native crashes in thumbnail extraction.
  void _maybeGenerateVideoPoster(VaultItem item) {
    if (item.type != VaultItemType.video) return;
    if (_requestedVideoPosters.contains(item.id)) return;

    final vaultService = Provider.of<VaultService>(context, listen: false);
    final existingThumbPath = vaultService.getThumbnailPath(item.id);
    if (existingThumbPath != null && File(existingThumbPath).existsSync()) return;

    _requestedVideoPosters.add(item.id);

    Future.microtask(() async {
      try {
        final filePath = vaultService.getFilePath(item.id);
        if (filePath == null) return;

        // iOS safety gate: skip very large videos and unknown containers (reduces crash risk).
        if (Platform.isIOS) {
          final lower = filePath.toLowerCase();
          final isCommonContainer = lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.m4v');
          if (!isCommonContainer) {
            _requestedVideoPosters.remove(item.id);
            return;
          }

          final size = await File(filePath).length().catchError((_) => 0);
          if (size > 300 * 1024 * 1024) {
            // Keep placeholder for very large iOS videos; user can still play it normally.
            _requestedVideoPosters.remove(item.id);
            return;
          }
        }

        await vaultService.generateThumbnailForItem(item.id);

        // If thumbnail still doesn't exist, allow retry later.
        final newThumbPath = vaultService.getThumbnailPath(item.id);
        if (newThumbPath == null || !File(newThumbPath).existsSync()) {
          _requestedVideoPosters.remove(item.id);
        }

        // Refresh this page so the newly generated poster displays immediately.
        if (mounted) {
          setState(() {});
        }
      } catch (e) {
        debugPrint('[VaultItemDetail] Poster generation skipped/failed for ${item.id}: $e');
        _requestedVideoPosters.remove(item.id);
      }
    });
  }

  Future<void> _generatePosterManually(VaultItem item) async {
    if (item.type != VaultItemType.video) return;
    if (_isGeneratingPoster) return;

    final vaultService = Provider.of<VaultService>(context, listen: false);
    final filePath = vaultService.getFilePath(item.id);
    if (filePath == null) return;

    if (Platform.isIOS) {
      final lower = filePath.toLowerCase();
      final isCommonContainer = lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.m4v');
      if (!isCommonContainer) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Poster generation is disabled for this video format on iOS (stability).'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }
      final size = await File(filePath).length().catchError((_) => 0);
      if (size > 300 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Poster generation is disabled for very large videos on iOS (stability).'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }
    }

    if (mounted) {
      setState(() {
        _isGeneratingPoster = true;
        _posterStatus = 'Generating poster...';
      });
    }

    try {
      await vaultService.generateThumbnailForItem(item.id);
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('[VaultItemDetail] Manual poster generation failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Poster generation failed: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingPoster = false;
          _posterStatus = null;
        });
      }
    }
  }
  

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Capture playback manager reference
    _playbackManager = Provider.of<MediaPlaybackManager>(context, listen: false);
    
    // Precache thumbnails for adjacent pages (MediaQuery is now available)
    // Use post-frame callback to ensure context is fully ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _precacheAdjacentThumbnails();
      }
    });
  }

  @override
  void dispose() {
    // Dispose video controller synchronously
    _disposeVideoController();
    
    // Stop audio playback
    if (_playbackManager != null) {
      _playbackManager!.stopAll();
    }
    
    // Reset orientation
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    
    // Clean up temp files (ignore errors)
    _audioFile?.delete().catchError((_) {});
    _documentFile?.delete().catchError((_) {});
    _tempFile?.delete().catchError((_) {});
    _tempFile?.delete().catchError((_) {});
    
    super.dispose();
  }

  /// Get file data for share/export operations (rare - only when needed)
  Future<Uint8List?> _getFileDataForExport() async {
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final authService = Provider.of<AuthService>(context, listen: false);
    final masterKey = authService.masterKey;
    if (masterKey == null) return null;
    return await vaultService.getFileData(_currentItem.id, masterKey: masterKey);
  }
  
  /// Initialize video player using direct file path (no temp file rewriting)
  Future<void> _initializeVideoPlayer() async {
    if (!mounted) return;
    
    final item = _currentItem;
    if (item.type != VaultItemType.video) return;
    
    final initId = ++_currentVideoInitId; // Monotonic counter for cancellation
    final videoInitStart = DateTime.now();
    
    try {
      // Get file path directly from vault (no memory loading, no temp file)
      final vaultService = Provider.of<VaultService>(context, listen: false);
      final videoFilePath = vaultService.getFilePath(item.id);
      
      if (videoFilePath == null) {
        throw Exception('Video file not found in vault');
      }
      
      final videoFile = File(videoFilePath);
      if (!await videoFile.exists()) {
        throw Exception('Video file does not exist: $videoFilePath');
      }
      
      // Check if cancelled or item changed
      if (!mounted || _currentItem.id != item.id || _currentVideoInitId != initId) {
        debugPrint('[VaultItemDetail] Video initialization cancelled: item changed');
        return;
      }
      
      debugPrint('[VaultItemDetail] Initializing video player from path: $videoFilePath');
      
      // Create controller directly from vault file path (NO temp file rewriting)
      _videoController = VideoPlayerController.file(videoFile);
      
      // Check cancellation again
      if (!mounted || _currentItem.id != item.id || _currentVideoInitId != initId) {
        await _videoController?.dispose();
        _videoController = null;
        return;
      }
      
      // Register with playback manager
      if (_playbackManager != null) {
        _playbackManager!.registerVideo(_videoController!, item.id);
      }
      
      _activeVideoItemId = item.id;
      
      // Set looping
      _videoController!.setLooping(true);
      
      // Initialize controller
      await _videoController!.initialize().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException('Video initialization timed out');
        },
      );
      
      // Final cancellation check
      if (!mounted || _currentItem.id != item.id || _currentVideoInitId != initId) {
        await _videoController?.dispose();
        _videoController = null;
        _activeVideoItemId = null;
        return;
      }
      
      final initDuration = DateTime.now().difference(videoInitStart);
      debugPrint('[VaultItemDetail] ✅ Video initialized in ${initDuration.inMilliseconds}ms');
      
      // Final check before playing
      if (!mounted || _currentItem.id != item.id || _currentVideoInitId != initId) {
        await _videoController?.dispose();
        _videoController = null;
        _activeVideoItemId = null;
        return;
      }
      
      // Auto-play video after initialization (for smooth swiping experience)
      try {
        await _videoController!.play();
        debugPrint('[VaultItemDetail] ✅ Video started playing automatically');
      } catch (e) {
        debugPrint('[VaultItemDetail] ⚠️ Error starting video playback: $e');
        // Don't fail initialization if play fails - user can tap to play
      }
      
      if (mounted && _currentItem.id == item.id) {
        setState(() {
          _videoError = null;
          _videoInitializationFailed = false;
        });
      }
    } catch (e, stackTrace) {
      debugPrint('[VaultItemDetail] ❌ Video initialization error: $e');
      debugPrint('[VaultItemDetail] Stack trace: $stackTrace');
      
      // Only show error if this is still the active item
      if (mounted && _currentItem.id == item.id && _currentVideoInitId == initId) {
        String errorMessage;
        final errorString = e.toString().toLowerCase();
        
        if (errorString.contains('av1') || errorString.contains('av01') || 
            (errorString.contains('codec') && errorString.contains('not supported'))) {
          errorMessage = 'AV1 video format is not supported on iOS.\n\nPlease download videos in H.264 or H.265 format.';
        } else if (errorString.contains('timeout')) {
          errorMessage = 'Video took too long to load. The file may be corrupted.';
        } else {
          errorMessage = 'Unable to play video: ${e.toString()}';
        }
        
        setState(() {
          _videoError = errorMessage;
          _videoInitializationFailed = true;
        });
      }
      
      await _videoController?.dispose();
      _videoController = null;
      _activeVideoItemId = null;
    }
  }
  
  Future<void> _initializeAudioFile() async {
    final audioInitStart = DateTime.now();
    try {
      // Get file path from vault (path-first design)
      final vaultService = Provider.of<VaultService>(context, listen: false);
      final filePath = vaultService.getFilePath(_currentItem.id);
      
      if (filePath == null) {
        throw Exception('Audio file not found in vault');
      }
      
      final sourceFile = File(filePath);
      if (!await sourceFile.exists()) {
        throw Exception('Audio file does not exist: $filePath');
      }
      
      // Create temporary file for audio player
      final tempDir = await getTemporaryDirectory();
      // Use MIME type to determine extension, fallback to item extension, then default to m4a
      String extension = 'm4a'; // Default to m4a for better iOS compatibility
      if (_currentItem.mimeType != null && _currentItem.mimeType!.startsWith('audio/')) {
        final mimeExt = _currentItem.mimeType!.split('/').last;
        // Map common MIME types to extensions
        if (mimeExt == 'mpeg' || mimeExt == 'mp3') {
          extension = 'mp3';
        } else if (mimeExt == 'x-m4a' || mimeExt == 'm4a') {
          extension = 'm4a';
        } else if (mimeExt == 'wav') {
          extension = 'wav';
        } else if (mimeExt == 'ogg') {
          extension = 'ogg';
        } else {
          extension = mimeExt;
        }
      } else if (_currentItem.extension != null) {
        extension = _currentItem.extension!;
      }
      _audioFile = File('${tempDir.path}/audio_${_currentItem.id}_${DateTime.now().millisecondsSinceEpoch}.$extension');
      
      // Stream copy (no memory loading)
      final writeStart = DateTime.now();
      final sourceStream = sourceFile.openRead();
      final destSink = _audioFile!.openWrite();
      try {
        await sourceStream.pipe(destSink);
        await destSink.flush();
      } finally {
        await destSink.close();
        // Stream is automatically closed when pipe completes
      }
      final writeDuration = DateTime.now().difference(writeStart);
      debugPrint('[VaultItemDetail] Copying audio temp file took: ${writeDuration.inMilliseconds}ms');
      
      if (mounted) {
        setState(() {});
      }
      
      final totalAudioInitDuration = DateTime.now().difference(audioInitStart);
      debugPrint('[VaultItemDetail] Total audio initialization took: ${totalAudioInitDuration.inMilliseconds}ms');
    } catch (e) {
      debugPrint('[VaultItemDetail] Error initializing audio file: $e');
    }
  }
  
  /// Check if video is AV1 format (not supported on iOS)
  bool _isAV1Video() {
    // Check MIME type for AV1 indicators
    if (_currentItem.mimeType != null) {
      final mimeType = _currentItem.mimeType!.toLowerCase();
      if (mimeType.contains('av1') || 
          mimeType.contains('av01') ||
          mimeType.contains('codec=av01') ||
          mimeType.contains('codec=av1')) {
        return true;
      }
    }
    
    // Check filename/extension for AV1 indicators
    final filename = _currentItem.displayName.toLowerCase();
    if (filename.contains('av1') || filename.contains('av01')) {
      return true;
    }
    
    // Note: File data check removed - path-first design doesn't load files into memory
    // AV1 detection will rely on MIME type and filename, or let the player handle it
    
    return false;
  }
  
  /// Check if file header matches known video formats
  bool _isVideoFileHeader(List<int> header) {
    if (header.length < 4) return false;
    
    // MP4/M4V: starts with ftyp box (ftyp at offset 4)
    if (header.length >= 8) {
      final ftyp = String.fromCharCodes(header.sublist(4, 8));
      if (ftyp == 'ftyp') return true;
    }
    
    // WebM/MKV: starts with 1A 45 DF A3
    if (header[0] == 0x1A && header[1] == 0x45 && header[2] == 0xDF && header[3] == 0xA3) {
      return true;
    }
    
    // AVI: starts with RIFF...AVI
    if (header.length >= 12) {
      final riff = String.fromCharCodes(header.sublist(0, 4));
      final avi = String.fromCharCodes(header.sublist(8, 12));
      if (riff == 'RIFF' && avi.contains('AVI')) return true;
    }
    
    // MOV/QuickTime: starts with ftyp or moov
    if (header.length >= 8) {
      final ftyp = String.fromCharCodes(header.sublist(4, 8));
      if (ftyp == 'ftyp' || ftyp == 'moov') return true;
    }
    
    // FLV: starts with FLV
    if (header.length >= 3) {
      final flv = String.fromCharCodes(header.sublist(0, 3));
      if (flv == 'FLV') return true;
    }
    
    // WMV/ASF: starts with 30 26 B2 75 8E 66 CF 11
    if (header.length >= 8 &&
        header[0] == 0x30 && header[1] == 0x26 && header[2] == 0xB2 && header[3] == 0x75 &&
        header[4] == 0x8E && header[5] == 0x66 && header[6] == 0xCF && header[7] == 0x11) {
      return true;
    }
    
    // 3GP/3G2: starts with ftyp box with 3gp or 3g2 brand
    if (header.length >= 20) {
      final ftyp = String.fromCharCodes(header.sublist(4, 8));
      if (ftyp == 'ftyp') {
        final brand = String.fromCharCodes(header.sublist(8, 12));
        if (brand == '3gp ' || brand == '3g2a' || brand == '3g2b') return true;
      }
    }
    
    // MPEG: starts with 00 00 01 BA or 00 00 01 B3
    if (header.length >= 4 &&
        header[0] == 0x00 && header[1] == 0x00 && header[2] == 0x01 &&
        (header[3] == 0xBA || header[3] == 0xB3)) {
      return true;
    }
    
    // OGV/OGG: starts with OggS
    if (header.length >= 4) {
      final oggs = String.fromCharCodes(header.sublist(0, 4));
      if (oggs == 'OggS') return true;
    }
    
    // If header check fails but file extension suggests video, allow it
    // The video player will handle format validation
    return false;
    if (header.length >= 8 &&
        header[0] == 0x30 && header[1] == 0x26 && header[2] == 0xB2 && header[3] == 0x75 &&
        header[4] == 0x8E && header[5] == 0x66 && header[6] == 0xCF && header[7] == 0x11) {
      return true;
    }
    
    // 3GP/3G2: starts with ftyp box with 3gp or 3g2 brand
    if (header.length >= 20) {
      final ftyp = String.fromCharCodes(header.sublist(4, 8));
      if (ftyp == 'ftyp') {
        final brand = String.fromCharCodes(header.sublist(8, 12));
        if (brand == '3gp ' || brand == '3g2a' || brand == '3g2b') return true;
      }
    }
    
    // MPEG: starts with 00 00 01 BA or 00 00 01 B3
    if (header.length >= 4 &&
        header[0] == 0x00 && header[1] == 0x00 && header[2] == 0x01 &&
        (header[3] == 0xBA || header[3] == 0xB3)) {
      return true;
    }
    
    // OGV/OGG: starts with OggS
    if (header.length >= 4) {
      final oggs = String.fromCharCodes(header.sublist(0, 4));
      if (oggs == 'OggS') return true;
    }
    
    // If header check fails but file extension suggests video, allow it
    // The video player will handle format validation
    return false;
  }
  
  Future<void> _initializeDocumentFile() async {
    try {
      // Get file path from vault (path-first design)
      final vaultService = Provider.of<VaultService>(context, listen: false);
      final filePath = vaultService.getFilePath(_currentItem.id);
      
      if (filePath == null) {
        throw Exception('Document file not found in vault');
      }
      
      final sourceFile = File(filePath);
      if (!await sourceFile.exists()) {
        throw Exception('Document file does not exist: $filePath');
      }
      
      // Create temporary file for document viewer (copy from vault)
      final tempDir = await getTemporaryDirectory();
      final extension = _currentItem.extension ?? 'bin';
      _documentFile = File('${tempDir.path}/doc_${_currentItem.id}_${DateTime.now().millisecondsSinceEpoch}.$extension');
      
      // Stream copy (no memory loading)
      final sourceStream = sourceFile.openRead();
      final destSink = _documentFile!.openWrite();
      try {
        await sourceStream.pipe(destSink);
        await destSink.flush();
      } finally {
        await destSink.close();
        // Stream is automatically closed when pipe completes
      }
      
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('[VaultItemDetail] Error initializing document file: $e');
    }
  }
  
  bool _isPdfFile() {
    final extension = _currentItem.extension?.toLowerCase() ?? '';
    return extension == 'pdf' || _currentItem.mimeType?.toLowerCase() == 'application/pdf';
  }
  
  bool _isImageFile() {
    final extension = _currentItem.extension?.toLowerCase() ?? '';
    final mimeType = _currentItem.mimeType?.toLowerCase() ?? '';
    return extension == 'jpg' || extension == 'jpeg' || extension == 'png' || 
           extension == 'gif' || extension == 'webp' ||
           mimeType.startsWith('image/') ||
           _currentItem.type == VaultItemType.photo;
  }
  
  bool _isOfficeDocument() {
    final extension = _currentItem.extension?.toLowerCase() ?? '';
    return extension == 'doc' || extension == 'docx' || 
           extension == 'xls' || extension == 'xlsx' ||
           extension == 'ppt' || extension == 'pptx' ||
           extension == 'pages' || extension == 'numbers' || extension == 'key';
  }
  
  Future<void> _openDocumentWithExternalApp() async {
    if (_documentFile == null) {
      await _initializeDocumentFile();
    }
    
    if (_documentFile != null) {
      try {
        final result = await OpenFilex.open(_documentFile!.path);
        debugPrint('[VaultItemDetail] Open file result: ${result.message}');
        if (!result.type.toString().contains('done')) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Could not open file: ${result.message}'),
                backgroundColor: AppTheme.warning,
              ),
            );
          }
        }
      } catch (e) {
        debugPrint('[VaultItemDetail] Error opening file: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error opening file: $e'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
    }
  }

  Future<void> _shareFile() async {
    try {
      // Get file data for sharing (rare operation - ok to load into memory)
      final fileData = await _getFileDataForExport();
      if (fileData == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to load file'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      // Create temporary file for sharing
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final extension = _currentItem.extension ?? 'bin';
      _tempFile = File('${tempDir.path}/share_${_currentItem.id}_$timestamp.$extension');
      
      await _tempFile!.writeAsBytes(fileData);
      
      // Share via system share sheet
      await Share.shareXFiles(
        [XFile(_tempFile!.path)],
        text: 'Shared from Nyx Vault',
        subject: _currentItem.displayName,
      );
      
      // Clean up temp file after a delay
      Future.delayed(const Duration(seconds: 5), () {
        _cleanupTempFile();
      });
    } catch (e) {
      debugPrint('[VaultItemDetail] Error sharing file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sharing file: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }

  Future<void> _shareViaEmail() async {
    try {
      // Get file data for sharing (rare operation)
      final fileData = await _getFileDataForExport();
      if (fileData == null) return;

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final extension = _currentItem.extension ?? 'bin';
      _tempFile = File('${tempDir.path}/email_${_currentItem.id}_$timestamp.$extension');
      
      await _tempFile!.writeAsBytes(fileData);
      
      // Share via email (uses system share sheet which includes email)
      await Share.shareXFiles(
        [XFile(_tempFile!.path)],
        text: 'File from Nyx Vault',
        subject: _currentItem.displayName,
      );
      
      Future.delayed(const Duration(seconds: 5), () {
        _cleanupTempFile();
      });
    } catch (e) {
      debugPrint('[VaultItemDetail] Error sharing via email: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sharing: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }

  void _cleanupTempFile() {
    _tempFile?.delete().catchError((_) {});
    _tempFile = null;
  }

  Future<void> _moveToFolder() async {
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final folders = vaultService.folders;
    
    if (folders.isEmpty) {
      // If no folders exist, ask to create one
      final createFolder = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text('No Folders'),
          content: const Text(
            'You need to create a folder first. Would you like to create one now?',
            style: TextStyle(color: AppTheme.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: AppTheme.primary,
              ),
              child: const Text('Create Folder'),
            ),
          ],
        ),
      );
      
      if (createFolder == true) {
        // Navigate back to vault to create folder
        Navigator.of(context).pop();
        // The vault home page will handle folder creation
        return;
      }
      return;
    }
    
    // Find which folder this item is currently in (if any)
    String? currentFolderId;
    for (final folder in folders) {
      if (folder.itemIds.contains(_currentItem.id)) {
        currentFolderId = folder.id;
        break;
      }
    }
    
    // Show folder selection dialog
    String? selectedFolderId = currentFolderId;
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text(
            'Move to Folder',
            style: TextStyle(color: AppTheme.text),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: folders.length + 1, // +1 for "None" option
              itemBuilder: (context, index) {
                if (index == 0) {
                  // "None" option to remove from folder
                  return RadioListTile<String?>(
                    title: const Text('None (Remove from folder)'),
                    value: null,
                    groupValue: selectedFolderId,
                    onChanged: (value) {
                      setDialogState(() {
                        selectedFolderId = value;
                      });
                    },
                    activeColor: AppTheme.accent,
                  );
                }
                
                final folder = folders[index - 1];
                return RadioListTile<String>(
                  title: Text(folder.name),
                  subtitle: Text('${folder.itemIds.length} items'),
                  value: folder.id,
                  groupValue: selectedFolderId,
                  onChanged: (value) {
                    setDialogState(() {
                      selectedFolderId = value;
                    });
                  },
                  activeColor: AppTheme.accent,
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: AppTheme.primary,
              ),
              child: const Text('Move'),
            ),
          ],
        ),
      ),
    );
    
    if (result != true) return;
    
    try {
      // Remove from current folder if any
      if (currentFolderId != null) {
        await vaultService.removeItemFromFolder(_currentItem.id, currentFolderId);
      }
      
      // Add to selected folder (or leave in root if null)
      if (selectedFolderId != null) {
        await vaultService.addItemToFolder(_currentItem.id, selectedFolderId!);
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              selectedFolderId == null
                  ? 'Removed from folder'
                  : 'Moved to folder',
            ),
            backgroundColor: AppTheme.accent,
          ),
        );
      }
    } catch (e) {
      debugPrint('[VaultItemDetail] Error moving item: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error moving item: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }
  
  Future<void> _deleteItem() async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: const Text(
          'Delete Item',
          style: TextStyle(color: AppTheme.text),
        ),
        content: Text(
          'Are you sure you want to delete "${_currentItem.displayName}"? This action cannot be undone.',
          style: const TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.warning,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final vaultService = Provider.of<VaultService>(context, listen: false);
      final success = await vaultService.deleteItem(_currentItem.id);

      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Item deleted successfully'),
              backgroundColor: AppTheme.accent,
            ),
          );
          Navigator.of(context).pop(); // Go back to vault
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to delete item'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[VaultItemDetail] Error deleting item: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting item: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }

  Future<void> _downloadToDevice() async {
    try {
      // Get file data for export (rare operation)
      final fileData = await _getFileDataForExport();
      if (fileData == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to load file'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      // For photos and videos on iOS, save to Photos library
      // For audio and other files, save to Files app (no permission needed)
      if (Platform.isIOS && (widget.item.type == VaultItemType.photo || widget.item.type == VaultItemType.video)) {
        await _saveToPhotosLibrary(fileData);
      } else {
        // For other files (audio, documents, etc.) or Android, save to Downloads/Files
        await _saveToFiles(fileData);
      }
    } catch (e) {
      debugPrint('[VaultItemDetail] Error downloading file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving file: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }

  Future<void> _saveToPhotosLibrary(Uint8List fileData) async {
    // Only for iOS - photos and videos should save to photo library
    if (!Platform.isIOS) {
      // Android: use Files/Downloads
      await _saveToFiles(fileData);
      return;
    }
    
    // Check photo library add permission (photosAddOnly for iOS)
    // Try to request permission silently, but don't block or show errors
    // We'll check the actual save result instead
    var status = await Permission.photosAddOnly.status;
    
    // If not granted, try to request it
    if (!status.isGranted && !status.isLimited) {
      status = await Permission.photosAddOnly.request();
    }
    
    // Proceed to save regardless - we'll check the result after
    
    // Permission is granted or limited - proceed to save

    try {
      // Create temporary file
      final tempDir = await getTemporaryDirectory();
      final extension = _currentItem.extension ?? (_currentItem.type == VaultItemType.photo ? 'jpg' : 'mp4');
      final tempFile = File('${tempDir.path}/save_${_currentItem.id}_${DateTime.now().millisecondsSinceEpoch}.$extension');
      await tempFile.writeAsBytes(fileData);

      bool savedToPhotos = false;
      
      // Try to save to Photos library
      try {
        if (widget.item.type == VaultItemType.photo) {
          final result = await PhotoManager.editor.saveImageWithPath(
            tempFile.path,
            title: _currentItem.displayName,
          );
          savedToPhotos = result != null;
        } else if (_currentItem.type == VaultItemType.video) {
          final result = await PhotoManager.editor.saveVideo(
            tempFile,
            title: _currentItem.displayName,
          );
          savedToPhotos = result != null;
        }
      } catch (e) {
        debugPrint('[VaultItemDetail] Error saving to Photos library: $e');
        // Fallback to Files app
        savedToPhotos = false;
      }

      if (mounted) {
        if (savedToPhotos) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${widget.item.type == VaultItemType.photo ? "Photo" : "Video"} saved to Photos library'),
              backgroundColor: AppTheme.accent,
            ),
          );
        } else {
          // Fallback: save to Files app
          final fileData = await _getFileDataForExport();
          if (fileData != null) {
            await _saveToFiles(fileData);
          }
        }
      }

      // Clean up temp file
      tempFile.delete().catchError((_) {});
    } catch (e) {
      debugPrint('[VaultItemDetail] Error saving to Photos: $e');
      // Fallback to Files app
      final fileData = await _getFileDataForExport();
      if (fileData != null) {
        await _saveToFiles(fileData);
      }
    }
  }

  void _showPaywall() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const PaywallPage(showCloseButton: true),
      ),
    );
  }
  
  void _showConvertToAudioDialog() {
    final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
    final hasPremium = subscriptionService.currentTier.isUnlimited || subscriptionService.isInTrial;
    
    if (!hasPremium) {
      _showPaywall();
      return;
    }
    
    // Get video file path
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final videoFilePath = vaultService.getFilePath(_currentItem.id);
    
    if (videoFilePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Video file not found'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    final videoExtension = _currentItem.extension ?? 'mp4';
    final recommendedFormat = _converterService.getRecommendedAudioFormat(videoExtension);
    final supportedFormats = _converterService.getSupportedAudioFormats();
    
    // Initialize selected format with recommended format
    _selectedAudioFormat = recommendedFormat;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          ),
          title: const Text(
            'Convert to Audio',
            style: TextStyle(color: AppTheme.text),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select audio format:',
                style: TextStyle(color: AppTheme.text),
              ),
              const SizedBox(height: 16),
              ...supportedFormats.map((format) => RadioListTile<String>(
                title: Text(format.toUpperCase()),
                value: format,
                groupValue: _selectedAudioFormat,
                onChanged: (value) {
                  setDialogState(() {
                    _selectedAudioFormat = value;
                  });
                },
                activeColor: AppTheme.accent,
              )),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _selectedAudioFormat = null;
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: _selectedAudioFormat != null
                  ? () {
                      Navigator.of(context).pop();
                      if (_selectedAudioFormat != null) {
                        _convertVideoToAudio(_selectedAudioFormat!);
                      }
                      _selectedAudioFormat = null;
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: AppTheme.primary,
              ),
              child: const Text('Convert'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _convertVideoToAudio(String audioFormat) async {
    // Get video file path (path-first design)
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final videoFilePath = vaultService.getFilePath(_currentItem.id);
    
    if (videoFilePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Video file not found'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }
    
    final videoFile = File(videoFilePath);
    if (!await videoFile.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Video file not ready for conversion'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    setState(() {
      _isConverting = true;
      _conversionProgress = 0.0;
    });

    try {
      // Convert video to audio
      final audioPath = await _converterService.convertVideoToAudio(
        videoFilePath: videoFilePath,
        outputFormat: audioFormat,
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _conversionProgress = progress;
            });
          }
        },
      );

      if (audioPath == null) {
        throw Exception('Conversion failed');
      }

      // Read the converted audio file
      final audioFile = File(audioPath);
      final audioData = await audioFile.readAsBytes();

      // Import the audio file to the vault
      final vaultService = Provider.of<VaultService>(context, listen: false);
      final authService = Provider.of<AuthService>(context, listen: false);
      final masterKey = authService.masterKey;

      if (masterKey == null) {
        throw Exception('Vault not unlocked');
      }

      // Create audio filename
      final actualFormat = audioFormat;
      final videoName = _currentItem.displayName.split('.').first;
      final audioFileName = '$videoName.$actualFormat';

      // Import audio to vault with correct MIME type
      final audioItem = await vaultService.storeFile(
        data: audioData,
        filename: audioFileName,
        mimeType: 'audio/$actualFormat', // Use actual format, not requested format
        source: VaultItemSource.unknown,
      );

      // Clean up temporary audio file
      await audioFile.delete().catchError((_) {});

      if (mounted) {
        setState(() {
          _isConverting = false;
          _conversionProgress = 0.0;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Converted to ${audioFormat.toUpperCase()} successfully'),
            backgroundColor: AppTheme.accent,
            action: SnackBarAction(
              label: 'View',
              textColor: AppTheme.primary,
              onPressed: () {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (context) => VaultItemDetailPage(item: audioItem),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[VaultItemDetail] Error converting video to audio: $e');
      if (mounted) {
        setState(() {
          _isConverting = false;
          _conversionProgress = 0.0;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Conversion failed: ${e.toString()}'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }

  Future<void> _saveToFiles(Uint8List fileData) async {
    try {
      // Get Downloads directory (or Documents on iOS)
      Directory? targetDir;
      if (Platform.isAndroid) {
        // Android: Use Downloads directory
        final downloadsDir = Directory('/storage/emulated/0/Download');
        if (await downloadsDir.exists()) {
          targetDir = downloadsDir;
        } else {
          // Fallback to app documents directory
          targetDir = await getApplicationDocumentsDirectory();
        }
      } else {
        // iOS: Use Documents directory (accessible via Files app)
        targetDir = await getApplicationDocumentsDirectory();
      }

      if (targetDir == null) {
        throw Exception('Could not access Downloads directory');
      }

      // Create file in Downloads/Documents
      final extension = _currentItem.extension ?? 'bin';
      final filename = _currentItem.displayName;
      final file = File('${targetDir.path}/$filename');
      await file.writeAsBytes(fileData);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('File saved to ${Platform.isAndroid ? "Downloads" : "Files"} app'),
            backgroundColor: AppTheme.accent,
            action: Platform.isIOS
                ? SnackBarAction(
                    label: 'Open',
                    textColor: AppTheme.primary,
                    onPressed: () {
                      OpenFilex.open(file.path);
                    },
                  )
                : null,
          ),
        );
      }
    } catch (e) {
      debugPrint('[VaultItemDetail] Error saving to Files: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving file: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }

  Future<void> _showTagsDialogForCurrentItem() async {
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final selected = vaultService.getItemTagIds(_currentItem.id).toSet();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              backgroundColor: AppTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
              ),
              title: const Text(
                'Tags',
                style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w700),
              ),
              content: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _tagColorById.entries.map((entry) {
                  final tagId = entry.key;
                  final color = entry.value;
                  final isSelected = selected.contains(tagId);
                  return InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () {
                      setLocalState(() {
                        if (isSelected) {
                          selected.remove(tagId);
                        } else {
                          selected.add(tagId);
                        }
                      });
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? AppTheme.accent : Colors.white.withOpacity(0.9),
                          width: isSelected ? 4 : 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: color.withOpacity(0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: isSelected
                          ? const Icon(Icons.check, color: Colors.white, size: 18)
                          : null,
                    ),
                  );
                }).toList(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Cancel',
                    style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await vaultService.setItemTagIds(_currentItem.id, selected.toList());
                    if (!mounted) return;
                    setState(() {
                      final meta = Map<String, dynamic>.from(_currentItem.metadata ?? const {});
                      if (selected.isEmpty) {
                        meta.remove('tags');
                      } else {
                        meta['tags'] = selected.toList()..sort();
                      }
                      _currentItem = _currentItem.copyWith(metadata: meta);
                    });
                    if (mounted) Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    foregroundColor: AppTheme.primary,
                  ),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvoked: (didPop) {
        if (didPop) {
          // Stop video playback when exiting
          if (_videoController != null) {
            try {
              _videoController!.pause(); // Stop playback immediately
              if (_playbackManager != null) {
                _playbackManager!.unregisterVideo(_videoController!);
              }
            } catch (e) {
              debugPrint('[VaultItemDetail] Error stopping video on pop: $e');
            }
          }
          // Stop all media playback
          if (_playbackManager != null) {
            _playbackManager!.stopAll();
          }
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.primary,
        appBar: (_isVideoFullscreen || _isPhotoFullscreen) ? null : AppBar(
        title: Text(_currentItem.displayName),
        backgroundColor: AppTheme.surface,
        elevation: 0,
        actions: [
          if (_currentItem.type == VaultItemType.video)
            Consumer<SubscriptionService>(
              builder: (context, subscriptionService, _) {
                final hasPremium = subscriptionService.currentTier.isUnlimited || subscriptionService.isInTrial;
                return IconButton(
                  icon: _isConverting 
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            value: _conversionProgress > 0 ? _conversionProgress : null,
                            color: AppTheme.accent,
                          ),
                        )
                      : Icon(
                          Icons.audiotrack,
                          color: hasPremium ? null : AppTheme.text.withOpacity(0.4),
                        ),
                  onPressed: _isConverting 
                      ? null 
                      : (hasPremium 
                          ? _showConvertToAudioDialog 
                          : _showPaywall),
                  tooltip: hasPremium ? 'Convert to Audio' : 'Convert to Audio (Premium)',
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _downloadToDevice,
            tooltip: 'Save to Device',
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _shareFile,
            tooltip: 'Share',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'tags':
                  _showTagsDialogForCurrentItem();
                  break;
                case 'move_to_folder':
                  _moveToFolder();
                  break;
                case 'delete':
                  _deleteItem();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'tags',
                child: Row(
                  children: [
                    Icon(Icons.local_offer_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Tags'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'move_to_folder',
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Move to Folder'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 20, color: AppTheme.warning),
                    SizedBox(width: 12),
                    Text('Delete', style: TextStyle(color: AppTheme.warning)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: widget.allItems != null && widget.allItems!.length > 1
          ? PageView.builder(
              controller: _pageController,
              onPageChanged: _onPageChanged,
              itemCount: widget.allItems!.length,
              allowImplicitScrolling: true, // Can be true - only thumbnails are preloaded
              physics: const PageScrollPhysics(), // Ensure PageView can handle horizontal swipes
              itemBuilder: (context, index) {
                final item = widget.allItems![index];
                final isCurrentPage = index == _currentIndex;
                
                // For all pages: show thumbnail/poster immediately (no loading spinner)
                // For current page: show full content once initialized
                return _buildPageContent(item, isCurrentPage);
              },
            )
          : _buildPageContent(_currentItem, true),
      ),
    );
  }

  /// Build page content with thumbnail-first rendering
  /// Shows thumbnail immediately, then full content when active
  Widget _buildPageContent(VaultItem item, bool isActivePage) {
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final thumbnailPath = vaultService.getThumbnailPath(item.id);
    
    // Always show thumbnail first (instant display)
    Widget thumbnailWidget;
    if (thumbnailPath != null) {
      final thumbnailFile = File(thumbnailPath);
      if (thumbnailFile.existsSync()) {
        thumbnailWidget = Image.file(
          thumbnailFile,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: 800, // Limit decode size for performance
        );
      } else {
        thumbnailWidget = _buildPlaceholder(item);
      }
    } else {
      thumbnailWidget = _buildPlaceholder(item);
    }
    
    // For active page, show full content overlay once initialized
    if (isActivePage) {
      final hasPoster = thumbnailPath != null && File(thumbnailPath).existsSync();
      final showPosterButton = Platform.isIOS && item.type == VaultItemType.video && !hasPoster;

      return Stack(
        children: [
          // Thumbnail/poster background (always visible)
          Positioned.fill(child: thumbnailWidget),
          
          // Full content overlay (when ready)
          // For videos, wrap in a widget that allows horizontal gestures to pass through when not in fullscreen
          item.type == VaultItemType.video && !_isVideoFullscreen
              ? GestureDetector(
                  // Only handle vertical gestures and taps, let horizontal pass through to PageView
                  onHorizontalDragStart: null,
                  onHorizontalDragUpdate: null,
                  onHorizontalDragEnd: null,
                  child: _buildFullContent(item),
                )
              : _buildFullContent(item),

          // iOS manual poster generation (only when poster is missing)
          if (showPosterButton)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: SafeArea(
                top: false,
                child: Center(
                  child: ElevatedButton.icon(
                    onPressed: _isGeneratingPoster ? null : () => _generatePosterManually(item),
                    icon: _isGeneratingPoster
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary),
                          )
                        : const Icon(Icons.image_outlined),
                    label: Text(_isGeneratingPoster ? (_posterStatus ?? 'Generating...') : 'Generate poster'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black.withOpacity(0.65),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    } else {
      // Non-active pages: just show thumbnail
      return thumbnailWidget;
    }
  }
  
  /// Build full content for active page (overlay on thumbnail)
  Widget _buildFullContent(VaultItem item) {
    // For videos: show player when controller is ready
    if (item.type == VaultItemType.video) {
      // Check if controller is ready and matches current item
      final isControllerReady = _videoController != null && 
          _videoController!.value.isInitialized && 
          _activeVideoItemId == item.id;
      
      if (isControllerReady) {
        // Ensure video is playing (might have been paused during swipe or initialization)
        // Use microtask to avoid setState during build
        Future.microtask(() {
          if (mounted && 
              _videoController != null && 
              _videoController!.value.isInitialized &&
              _activeVideoItemId == item.id &&
              !_videoController!.value.isPlaying &&
              !_videoController!.value.isCompleted) {
            // Auto-play if not already playing
            _videoController!.play().catchError((e) {
              debugPrint('[VaultItemDetail] Error auto-playing video after swipe: $e');
            });
          }
        });
        
        return VideoPlayerWidget(
          controller: _videoController!,
          mediaId: item.id,
          autoPlay: true,
          autoFullscreen: false, // No auto-fullscreen on swipe
          onFullscreenChanged: (isFullscreen) {
            if (mounted) {
              setState(() {
                _isVideoFullscreen = isFullscreen;
              });
            }
          },
          onPlayingStateChanged: (isPlaying) {
            if (mounted) {
              setState(() {
                _isVideoPlaying = isPlaying;
              });
            }
          },
          onDismiss: () {
            // Swipe down to close - navigate back
            if (mounted) {
              Navigator.of(context).pop();
            }
          },
        );
      } else if (_videoInitializationFailed) {
        return _buildVideoError();
      } else {
        // Video initializing - show thumbnail (already in background)
        return const SizedBox.shrink();
      }
    }
    
    // For photos: show Image.file with ResizeImage
    if (item.type == VaultItemType.photo) {
      final vaultService = Provider.of<VaultService>(context, listen: false);
      final filePath = vaultService.getFilePath(item.id);
      if (filePath != null) {
        final photoFile = File(filePath);
        if (photoFile.existsSync()) {
          return PhotoViewerWidget(
            imageFile: photoFile,
            title: item.displayName,
            onDismiss: () {
              if (mounted) Navigator.of(context).pop();
            },
            onFullscreenChanged: (isFullscreen) {
              if (!mounted) return;
              setState(() {
                _isPhotoFullscreen = isFullscreen;
              });
            },
          );
        }
      }
      return _buildPlaceholder(item);
    }
    
    // For audio: show player
    if (item.type == VaultItemType.audio) {
      final vaultService = Provider.of<VaultService>(context, listen: false);
      final filePath = vaultService.getFilePath(item.id);
      if (filePath != null && _audioFile != null) {
        return AudioPlayerWidget(
          audioPath: _audioFile!.path,
          title: item.displayName,
          mediaId: item.id,
        );
      }
      return _buildPlaceholder(item);
    }
    
    // For documents: show viewer
    if (item.type == VaultItemType.document) {
      if (_documentFile != null) {
        return SfPdfViewer.file(_documentFile!);
      }
      return _buildPlaceholder(item);
    }
    
    return _buildPlaceholder(item);
  }
  
  /// Build placeholder widget
  Widget _buildPlaceholder(VaultItem item) {
    IconData icon;
    Color color;
    
    switch (item.type) {
      case VaultItemType.photo:
        icon = Icons.image;
        color = Colors.blue;
        break;
      case VaultItemType.video:
        icon = Icons.videocam;
        color = Colors.red;
        break;
      case VaultItemType.audio:
        icon = Icons.audiotrack;
        color = Colors.purple;
        break;
      case VaultItemType.document:
        icon = Icons.insert_drive_file;
        color = Colors.orange;
        break;
      default:
        icon = Icons.insert_drive_file;
        color = Colors.grey;
    }
    
    return Container(
      color: AppTheme.primary,
      child: Center(
        child: Icon(icon, size: 64, color: color.withOpacity(0.5)),
      ),
    );
  }
  
  /// Build video error widget
  Widget _buildVideoError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: AppTheme.warning),
            const SizedBox(height: 16),
            Text(
              'Video Playback Error',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _videoError ?? 'Unable to play this video file.',
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.text.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _videoError = null;
                  _videoInitializationFailed = false;
                });
                _initializeVideoPlayer();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildContent() {
    // Legacy method - redirect to new path-based method
    return _buildPageContent(_currentItem, true);
  }
  
  Widget _buildVideoInfo() {
    return Container(
      height: 200,
      color: AppTheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Video Information',
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoRow('Name', _currentItem.displayName),
            _buildInfoRow('Type', _currentItem.type.toString().split('.').last),
            if (_currentItem.mimeType != null)
              _buildInfoRow('MIME Type', _currentItem.mimeType!),
            _buildInfoRow('Size', _formatFileSize(_currentItem.sizeBytes)),
            _buildInfoRow('Date Added', _formatDate(_currentItem.dateAdded)),
            if (_currentItem.sourceSite != null)
              _buildInfoRow('Source', _currentItem.sourceSite!),
            if (_videoController != null && _videoController!.value.isInitialized)
              _buildInfoRow(
                'Duration',
                _formatDuration(_videoController!.value.duration),
              ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildAudioInfo() {
    return Container(
      height: 200,
      color: AppTheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Audio Information',
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoRow('Name', _currentItem.displayName),
            _buildInfoRow('Type', _currentItem.type.toString().split('.').last),
            if (_currentItem.mimeType != null)
              _buildInfoRow('MIME Type', _currentItem.mimeType!),
            _buildInfoRow('Size', _formatFileSize(_currentItem.sizeBytes)),
            _buildInfoRow('Date Added', _formatDate(_currentItem.dateAdded)),
            if (_currentItem.sourceSite != null)
              _buildInfoRow('Source', _currentItem.sourceSite!),
          ],
        ),
      ),
    );
  }
  
  Widget _buildPhotoInfo() {
    return Container(
      height: 200,
      color: AppTheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Photo Information',
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoRow('Name', _currentItem.displayName),
            _buildInfoRow('Type', _currentItem.type.toString().split('.').last),
            if (_currentItem.mimeType != null)
              _buildInfoRow('MIME Type', _currentItem.mimeType!),
            _buildInfoRow('Size', _formatFileSize(_currentItem.sizeBytes)),
            _buildInfoRow('Date Added', _formatDate(_currentItem.dateAdded)),
            if (_currentItem.sourceSite != null)
              _buildInfoRow('Source', _currentItem.sourceSite!),
          ],
        ),
      ),
    );
  }
  
  Widget _buildDocumentInfo() {
    return Container(
      height: 200,
      color: AppTheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Document Information',
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoRow('Name', _currentItem.displayName),
            _buildInfoRow('Type', _currentItem.type.toString().split('.').last),
            if (_currentItem.mimeType != null)
              _buildInfoRow('MIME Type', _currentItem.mimeType!),
            _buildInfoRow('Size', _formatFileSize(_currentItem.sizeBytes)),
            _buildInfoRow('Date Added', _formatDate(_currentItem.dateAdded)),
            if (_currentItem.sourceSite != null)
              _buildInfoRow('Source', _currentItem.sourceSite!),
          ],
        ),
      ),
    );
  }
  
  IconData _getDocumentIcon() {
    final extension = widget.item.extension?.toLowerCase() ?? '';
    switch (extension) {
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'pages':
        return Icons.article;
      case 'numbers':
        return Icons.grid_on;
      case 'key':
        return Icons.present_to_all;
      default:
        return Icons.insert_drive_file;
    }
  }
  
  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: TextStyle(
                color: AppTheme.text.withOpacity(0.7),
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppTheme.text,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/services/media_playback_manager.dart';

/// Modern full-featured video player widget with advanced controls
class VideoPlayerWidget extends StatefulWidget {
  final VideoPlayerController controller;
  final String? mediaId;
  final ValueChanged<bool>? onFullscreenChanged;
  final ValueChanged<bool>? onPlayingStateChanged;
  final VoidCallback? onDismiss; // Called when user swipes down to close
  final bool autoPlay; // Auto-play when initialized
  final bool autoFullscreen; // Auto-enter fullscreen when initialized
  
  const VideoPlayerWidget({
    super.key,
    required this.controller,
    this.mediaId,
    this.onFullscreenChanged,
    this.onPlayingStateChanged,
    this.onDismiss,
    this.autoPlay = false,
    this.autoFullscreen = false,
  });
  
  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  bool _showControls = true;
  double _volume = 1.0;
  double _brightness = 1.0;
  bool _isDragging = false;
  double _dragPosition = 0.0;
  bool _isFullscreen = false;
  double _playbackSpeed = 1.0;
  bool _showSettings = false;
  bool _showSpeedMenu = false;
  Timer? _hideControlsTimer;
  double _lastTapPosition = 0.0;
  DateTime? _lastTapTime;
  
  // Gesture tracking
  double _gestureStartY = 0.0;
  double _gestureStartX = 0.0;
  bool _isVerticalGesture = false;
  bool _isHorizontalGesture = false;
  double _gestureVolume = 1.0;
  double _gestureBrightness = 1.0;
  
  // Dismiss gesture tracking
  double _dismissOffset = 0.0;
  bool _isDismissing = false;
  double _dismissOpacity = 1.0;
  double _dismissScale = 1.0;
  DateTime? _dismissStartTime; // Track gesture start time for velocity calculation
  
  // Store reference to MediaPlaybackManager to safely access in dispose()
  MediaPlaybackManager? _playbackManager;
  
  static const List<double> _playbackSpeeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  
  void _updateState() {
    if (mounted) {
      // Defer setState to avoid calling during build phase
      Future.microtask(() {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }
  
  void _togglePlayPause() {
    if (!widget.controller.value.isInitialized) {
      debugPrint('[VideoPlayer] Controller not initialized, cannot play/pause');
      return;
    }
    
    try {
      if (widget.controller.value.isPlaying) {
        widget.controller.pause();
      } else {
        widget.controller.play().catchError((error) {
          debugPrint('[VideoPlayer] Error playing video: $error');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error playing video: $error'),
                backgroundColor: AppTheme.warning,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        });
      }
      _showControlsTemporarily();
    } catch (e) {
      debugPrint('[VideoPlayer] Exception in togglePlayPause: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppTheme.warning,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }
  
  void _seekTo(double position) {
    final duration = widget.controller.value.duration;
    final newPosition = position * duration.inMilliseconds.toDouble();
    widget.controller.seekTo(Duration(milliseconds: newPosition.round()));
    _showControlsTemporarily();
  }
  
  void _skipForward() {
    final currentPosition = widget.controller.value.position;
    final duration = widget.controller.value.duration;
    final newPosition = currentPosition + const Duration(seconds: 10);
    widget.controller.seekTo(newPosition > duration ? duration : newPosition);
    _showControlsTemporarily();
  }
  
  void _skipBackward() {
    final currentPosition = widget.controller.value.position;
    final newPosition = currentPosition - const Duration(seconds: 10);
    widget.controller.seekTo(newPosition < Duration.zero ? Duration.zero : newPosition);
    _showControlsTemporarily();
  }
  
  void _setPlaybackSpeed(double speed) {
    // Defer setState to avoid calling during build phase
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _playbackSpeed = speed;
          _showSpeedMenu = false;
        });
      }
    });
    widget.controller.setPlaybackSpeed(speed);
    _showControlsTemporarily();
  }
  
  @override
  void initState() {
    super.initState();
    _volume = widget.controller.value.volume;
    _playbackSpeed = widget.controller.value.playbackSpeed;
    widget.controller.addListener(_updateState);
    widget.controller.addListener(_onVideoStateChanged);
    
    // Get initial brightness
    _brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark ? 0.5 : 1.0;
    
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    
    // Auto-play and auto-fullscreen if enabled
    // Use post-frame callback to avoid calling setState during build
    if (widget.controller.value.isInitialized) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _handleAutoPlayAndFullscreen();
        }
      });
    } else {
      // Wait for initialization
      widget.controller.addListener(_onInitialized);
    }
  }
  
  void _onInitialized() {
    if (widget.controller.value.isInitialized) {
      widget.controller.removeListener(_onInitialized);
      // Use post-frame callback to avoid calling setState during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _handleAutoPlayAndFullscreen();
        }
      });
    }
  }
  
  void _handleAutoPlayAndFullscreen() {
    if (!mounted || !widget.controller.value.isInitialized) return;
    
    // Auto-enter fullscreen first (if enabled)
    if (widget.autoFullscreen && !_isFullscreen) {
      _enterFullscreenAuto();
    }
    
    // Auto-play (if enabled) - use microtask to avoid calling during build
    if (widget.autoPlay && !widget.controller.value.isPlaying) {
      Future.microtask(() {
        if (mounted && widget.controller.value.isInitialized) {
          widget.controller.play().catchError((error) {
            debugPrint('[VideoPlayer] Error auto-playing video: $error');
          });
        }
      });
    }
  }
  
  void _enterFullscreenAuto() async {
    if (_isFullscreen || !mounted) return;
    
    debugPrint('[VideoPlayer] Auto-entering fullscreen mode');
    
    // Use microtask to ensure setState is called after build completes
    Future.microtask(() {
      if (!mounted) return;
      setState(() {
        _isFullscreen = true;
        _showControls = false; // Hide controls immediately for auto-fullscreen
      });
      
      // Notify parent of fullscreen state change
      widget.onFullscreenChanged?.call(_isFullscreen);
    });
    
    // Detect video orientation and set up fullscreen (defer to avoid build conflicts)
    Future.microtask(() async {
      if (!mounted) return;
      
      final videoAspectRatio = widget.controller.value.aspectRatio;
      final isVideoPortrait = videoAspectRatio > 0 && videoAspectRatio < 1.0;
      final isVideoLandscape = videoAspectRatio >= 1.0;
      
      try {
        // First, allow all orientations
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        
        // Then lock to appropriate orientation based on video aspect ratio
        Future.delayed(const Duration(milliseconds: 100), () async {
          if (mounted && _isFullscreen) {
            if (isVideoLandscape) {
              // Landscape video - lock to landscape
              await SystemChrome.setPreferredOrientations([
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]);
              debugPrint('[VideoPlayer] Auto-locked to landscape orientation (landscape video)');
            } else if (isVideoPortrait) {
              // Portrait video - lock to portrait
              await SystemChrome.setPreferredOrientations([
                DeviceOrientation.portraitUp,
                DeviceOrientation.portraitDown,
              ]);
              debugPrint('[VideoPlayer] Auto-locked to portrait orientation (portrait video)');
            }
          }
        });
      } catch (e) {
        debugPrint('[VideoPlayer] Error setting orientation for auto-fullscreen: $e');
      }
      
      // Hide system UI for immersive fullscreen
      try {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        debugPrint('[VideoPlayer] Enabled immersive sticky mode for auto-fullscreen');
      } catch (e) {
        debugPrint('[VideoPlayer] Error setting immersive mode: $e');
      }
    });
  }
  
  void _onVideoStateChanged() {
    // Notify parent of playing state changes (defer to avoid setState during build)
    if (widget.controller.value.isInitialized && mounted) {
      Future.microtask(() {
        if (!mounted) return;
        widget.onPlayingStateChanged?.call(widget.controller.value.isPlaying);
        
        // Handle video completion - restart if looping is enabled
        if (widget.controller.value.isCompleted && widget.controller.value.isLooping) {
          // Video ended and looping is enabled - restart playback
          widget.controller.seekTo(Duration.zero);
          widget.controller.play().catchError((error) {
            debugPrint('[VideoPlayer] Error restarting looped video: $error');
          });
        }
      });
    }
  }
  
  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    
    // Use stored reference instead of accessing Provider in dispose()
    if (widget.mediaId != null && _playbackManager != null) {
      try {
        _playbackManager!.unregisterVideo(widget.controller);
      } catch (e) {
        debugPrint('[VideoPlayer] Error unregistering: $e');
      }
    }
    
    // Defer system UI changes to avoid setState during dispose
    Future.microtask(() {
      try {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } catch (e) {
        debugPrint('[VideoPlayer] Error restoring system UI: $e');
      }
    });
    
    widget.controller.removeListener(_updateState);
    widget.controller.removeListener(_onVideoStateChanged);
    widget.controller.removeListener(_onInitialized);
    super.dispose();
  }
  
  void _toggleFullscreen() async {
    debugPrint('[VideoPlayer] Toggling fullscreen from ${_isFullscreen} to ${!_isFullscreen}');
    
    final newFullscreenState = !_isFullscreen;
    
    // Defer setState to avoid calling during build phase
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _isFullscreen = newFullscreenState;
          // Show controls briefly when entering/exiting fullscreen
          _showControls = true;
        });
        
        // Notify parent of fullscreen state change (after setState)
        widget.onFullscreenChanged?.call(_isFullscreen);
        debugPrint('[VideoPlayer] Notified parent of fullscreen change: $_isFullscreen');
        
        // Hide controls after a delay when entering fullscreen
        // For portrait videos, hide immediately; for landscape, hide after 2 seconds
        if (_isFullscreen) {
          final videoAspectRatio = widget.controller.value.aspectRatio;
          final isVideoPortrait = videoAspectRatio > 0 && videoAspectRatio < 1.0;
          final hideDelay = isVideoPortrait ? Duration.zero : const Duration(seconds: 2);
          
          Future.delayed(hideDelay, () {
            if (mounted && _isFullscreen && widget.controller.value.isPlaying) {
              Future.microtask(() {
                if (mounted) {
                  setState(() {
                    _showControls = false;
                  });
                }
              });
            }
          });
        }
      }
    });
    
    if (_isFullscreen) {
      debugPrint('[VideoPlayer] Entering fullscreen mode');
      
      // Detect video orientation
      final videoAspectRatio = widget.controller.value.aspectRatio;
      final isVideoPortrait = videoAspectRatio > 0 && videoAspectRatio < 1.0;
      final isVideoLandscape = videoAspectRatio >= 1.0;
      
      try {
        // First, allow all orientations
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        
        // Then lock to appropriate orientation based on video aspect ratio
        Future.delayed(const Duration(milliseconds: 100), () async {
          if (mounted && _isFullscreen) {
            if (isVideoLandscape) {
              // Landscape video - lock to landscape
              await SystemChrome.setPreferredOrientations([
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]);
              debugPrint('[VideoPlayer] Locked to landscape orientation (landscape video)');
            } else if (isVideoPortrait) {
              // Portrait video - lock to portrait
              await SystemChrome.setPreferredOrientations([
                DeviceOrientation.portraitUp,
                DeviceOrientation.portraitDown,
              ]);
              debugPrint('[VideoPlayer] Locked to portrait orientation (portrait video)');
            }
          }
        });
      } catch (e) {
        debugPrint('[VideoPlayer] Error setting landscape orientation: $e');
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
      
      // Hide system UI for immersive fullscreen
      try {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        debugPrint('[VideoPlayer] Enabled immersive sticky mode');
      } catch (e) {
        debugPrint('[VideoPlayer] Error setting immersive mode: $e');
      }
    } else {
      debugPrint('[VideoPlayer] Exiting fullscreen mode');
      try {
        // Restore portrait orientation
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        debugPrint('[VideoPlayer] Restored portrait orientation');
      } catch (e) {
        debugPrint('[VideoPlayer] Error setting portrait orientation: $e');
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
      
      // Restore system UI
      try {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        debugPrint('[VideoPlayer] Restored edge-to-edge mode');
      } catch (e) {
        debugPrint('[VideoPlayer] Error restoring system UI: $e');
      }
    }
    
    // Force a rebuild to ensure UI updates
    if (mounted) {
      setState(() {});
    }
  }
  
  void _setVolume(double volume) {
    final clampedVolume = volume.clamp(0.0, 1.0);
    // Defer setState to avoid calling during gesture handling
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _volume = clampedVolume;
        });
      }
    });
    widget.controller.setVolume(clampedVolume);
    _showControlsTemporarily();
  }
  
  void _toggleMute() {
    final newVolume = _volume > 0 ? 0.0 : 1.0;
    // Defer setState to avoid calling during build phase
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _volume = newVolume;
        });
      }
    });
    widget.controller.setVolume(newVolume);
    _showControlsTemporarily();
  }
  
  void _showControlsTemporarily() {
    _hideControlsTimer?.cancel();
    // Defer setState to avoid calling during build phase
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _showControls = true;
        });
      }
    });
    
    if (widget.controller.value.isPlaying && !_isDragging) {
      // For portrait videos in fullscreen, hide controls faster (2 seconds)
      // For landscape videos, hide after 3 seconds
      final videoAspectRatio = widget.controller.value.aspectRatio;
      final isVideoPortrait = videoAspectRatio > 0 && videoAspectRatio < 1.0;
      final hideDelay = (_isFullscreen && isVideoPortrait) 
          ? const Duration(seconds: 2) 
          : const Duration(seconds: 3);
      
      _hideControlsTimer = Timer(hideDelay, () {
        if (mounted && !_isDragging && !_showSettings && !_showSpeedMenu) {
          Future.microtask(() {
            if (mounted) {
              setState(() {
                _showControls = false;
              });
            }
          });
        }
      });
    }
  }
  
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }
  
  void _handleDoubleTap(double x) {
    final screenWidth = MediaQuery.of(context).size.width;
    if (x < screenWidth / 2) {
      // Left side - skip backward
      _skipBackward();
    } else {
      // Right side - skip forward
      _skipForward();
    }
  }
  
  Widget _buildVideoPlayer({bool isFullscreen = false}) {
    final videoPlayer = VideoPlayer(
      widget.controller,
      key: ValueKey(widget.controller.hashCode),
    );
    
    if (isFullscreen) {
      final aspectRatio = widget.controller.value.aspectRatio;
      
      if (aspectRatio > 0) {
        return Center(
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: widget.controller.value.size.width > 0 
                    ? widget.controller.value.size.width 
                    : 1920,
                height: widget.controller.value.size.height > 0 
                    ? widget.controller.value.size.height 
                    : 1080,
                child: videoPlayer,
              ),
            ),
          ),
        );
      } else {
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: widget.controller.value.size.width > 0 
                ? widget.controller.value.size.width 
                : 1920,
            height: widget.controller.value.size.height > 0 
                ? widget.controller.value.size.height 
                : 1080,
            child: videoPlayer,
          ),
        );
      }
    } else {
      return widget.controller.value.aspectRatio > 0
          ? AspectRatio(
              aspectRatio: widget.controller.value.aspectRatio,
              child: videoPlayer,
            )
          : FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: widget.controller.value.size.width > 0 
                    ? widget.controller.value.size.width 
                    : 1920,
                height: widget.controller.value.size.height > 0 
                    ? widget.controller.value.size.height 
                    : 1080,
                child: videoPlayer,
              ),
            );
    }
  }
  
  Widget _buildSettingsMenu() {
    return Positioned(
      bottom: 100,
      right: 16,
      child: Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 200,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Playback Speed
              InkWell(
                onTap: () {
                  setState(() {
                    _showSpeedMenu = !_showSpeedMenu;
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.speed, color: Colors.white, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Playback Speed',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                      Text(
                        '${_playbackSpeed}x',
                        style: TextStyle(color: AppTheme.accent, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showSpeedMenu)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: _playbackSpeeds.map((speed) {
                      return InkWell(
                        onTap: () => _setPlaybackSpeed(speed),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: _playbackSpeed == speed ? AppTheme.accent.withOpacity(0.2) : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              if (_playbackSpeed == speed)
                                Icon(Icons.check, color: AppTheme.accent, size: 16),
                              if (_playbackSpeed == speed) const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${speed}x',
                                  style: TextStyle(
                                    color: _playbackSpeed == speed ? AppTheme.accent : Colors.white,
                                    fontSize: 14,
                                    fontWeight: _playbackSpeed == speed ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildFullscreenControls() {
    return Stack(
      children: [
          // Exit fullscreen button (top right) - always accessible
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: SafeArea(
              child: GestureDetector(
                onTap: () {
                  debugPrint('[VideoPlayer] Exit fullscreen button tapped from controls');
                  _toggleFullscreen();
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.fullscreen_exit,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
            ),
          ),
          // Bottom controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Progress bar
                    VideoProgressBar(
                      controller: widget.controller,
                      onDragStart: () {
                        setState(() {
                          _isDragging = true;
                        });
                      },
                      onDragUpdate: (position) {
                        setState(() {
                          _dragPosition = position;
                        });
                      },
                      onDragEnd: (position) {
                        _seekTo(position);
                        setState(() {
                          _isDragging = false;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    // Bottom row controls
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Skip backward
                        IconButton(
                          icon: const Icon(Icons.replay_10, color: Colors.white),
                          onPressed: _skipBackward,
                          tooltip: 'Skip backward 10s',
                        ),
                        // Play/Pause
                        IconButton(
                          icon: Icon(
                            widget.controller.value.isInitialized && widget.controller.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: Colors.white,
                            size: 32,
                          ),
                          onPressed: _togglePlayPause,
                          tooltip: widget.controller.value.isInitialized && widget.controller.value.isPlaying
                              ? 'Pause'
                              : 'Play',
                        ),
                        // Skip forward
                        IconButton(
                          icon: const Icon(Icons.forward_10, color: Colors.white),
                          onPressed: _skipForward,
                          tooltip: 'Skip forward 10s',
                        ),
                        const SizedBox(width: 16),
                        // Settings button
                        IconButton(
                          icon: Icon(
                            _showSettings ? Icons.close : Icons.settings,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              _showSettings = !_showSettings;
                              if (_showSettings) {
                                _showSpeedMenu = false;
                              }
                            });
                            _showControlsTemporarily();
                          },
                          tooltip: _showSettings ? 'Close settings' : 'Settings',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Settings overlay
          if (_showSettings)
            Positioned(
              bottom: 100,
              right: 16,
              child: _buildSettingsMenu(),
            ),
      ],
    );
  }
  
  Widget _buildControls() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final hasLimitedHeight = constraints.maxHeight < 200;
        
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.5),
                Colors.transparent,
                Colors.transparent,
                Colors.black.withOpacity(0.8),
              ],
              stops: const [0.0, 0.2, 0.7, 1.0],
            ),
          ),
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top controls
                  SafeArea(
                    bottom: false,
                    minimum: EdgeInsets.zero,
                    child: Padding(
                      padding: EdgeInsets.all(hasLimitedHeight ? 2.0 : 8.0),
                      child: Row(
                        children: [
                          // Fullscreen button
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: IconButton(
                              icon: Icon(
                                _isFullscreen || MediaQuery.of(context).orientation == Orientation.landscape
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen,
                                color: Colors.white,
                                size: hasLimitedHeight ? 24 : 28,
                              ),
                              onPressed: () {
                                debugPrint('[VideoPlayer] Fullscreen button pressed');
                                _toggleFullscreen();
                              },
                              tooltip: _isFullscreen || MediaQuery.of(context).orientation == Orientation.landscape
                                  ? 'Exit fullscreen'
                                  : 'Enter fullscreen',
                              padding: EdgeInsets.all(hasLimitedHeight ? 4.0 : 8.0),
                              constraints: BoxConstraints(
                                minWidth: hasLimitedHeight ? 40 : 48,
                                minHeight: hasLimitedHeight ? 40 : 48,
                              ),
                            ),
                          ),
                          const Spacer(),
                          // Settings button
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: IconButton(
                              icon: Icon(
                                _showSettings ? Icons.close : Icons.settings,
                                color: Colors.white,
                                size: hasLimitedHeight ? 24 : 28,
                              ),
                              onPressed: () {
                                setState(() {
                                  _showSettings = !_showSettings;
                                  if (_showSettings) {
                                    _showSpeedMenu = false;
                                  }
                                });
                                _showControlsTemporarily();
                              },
                              tooltip: _showSettings ? 'Close settings' : 'Settings',
                              padding: EdgeInsets.all(hasLimitedHeight ? 4.0 : 8.0),
                              constraints: BoxConstraints(
                                minWidth: hasLimitedHeight ? 40 : 48,
                                minHeight: hasLimitedHeight ? 40 : 48,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  // Bottom controls
                  SafeArea(
                    top: false,
                    minimum: EdgeInsets.zero,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: hasLimitedHeight ? 8.0 : 16.0,
                        vertical: hasLimitedHeight ? 2.0 : 8.0,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Progress bar
                          VideoProgressBar(
                            controller: widget.controller,
                            onDragStart: () {
                              setState(() {
                                _isDragging = true;
                              });
                            },
                            onDragUpdate: (position) {
                              setState(() {
                                _dragPosition = position;
                              });
                            },
                            onDragEnd: (position) {
                              _seekTo(position);
                              setState(() {
                                _isDragging = false;
                              });
                            },
                          ),
                          
                          SizedBox(height: hasLimitedHeight ? 2 : 8),
                          
                          // Bottom row controls
                          Row(
                            children: [
                              // Skip backward
                              IconButton(
                                icon: Icon(Icons.replay_10, color: Colors.white, size: hasLimitedHeight ? 20 : 24),
                                onPressed: _skipBackward,
                                tooltip: 'Skip backward 10s',
                                padding: EdgeInsets.all(hasLimitedHeight ? 2.0 : 8.0),
                                constraints: BoxConstraints(
                                  minWidth: hasLimitedHeight ? 32 : 48,
                                  minHeight: hasLimitedHeight ? 32 : 48,
                                ),
                              ),
                              
                              // Play/Pause
                              IconButton(
                                icon: Icon(
                                  widget.controller.value.isInitialized && widget.controller.value.isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: Colors.white,
                                  size: hasLimitedHeight ? 20 : 24,
                                ),
                                onPressed: _togglePlayPause,
                                tooltip: widget.controller.value.isInitialized && widget.controller.value.isPlaying
                                    ? 'Pause'
                                    : 'Play',
                                padding: EdgeInsets.all(hasLimitedHeight ? 2.0 : 8.0),
                                constraints: BoxConstraints(
                                  minWidth: hasLimitedHeight ? 32 : 48,
                                  minHeight: hasLimitedHeight ? 32 : 48,
                                ),
                              ),
                              
                              // Skip forward
                              IconButton(
                                icon: Icon(Icons.forward_10, color: Colors.white, size: hasLimitedHeight ? 20 : 24),
                                onPressed: _skipForward,
                                tooltip: 'Skip forward 10s',
                                padding: EdgeInsets.all(hasLimitedHeight ? 2.0 : 8.0),
                                constraints: BoxConstraints(
                                  minWidth: hasLimitedHeight ? 32 : 48,
                                  minHeight: hasLimitedHeight ? 32 : 48,
                                ),
                              ),
                              
                              const Spacer(),
                              
                              // Time indicators
                              Flexible(
                                child: Text(
                                  _isDragging
                                      ? _formatDuration(Duration(
                                          milliseconds: (_dragPosition *
                                                  widget.controller.value.duration.inMilliseconds)
                                              .round(),
                                        ))
                                      : _formatDuration(widget.controller.value.position),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: hasLimitedHeight ? 11 : 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              
                              Text(
                                ' / ${_formatDuration(widget.controller.value.duration)}',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.7),
                                  fontSize: hasLimitedHeight ? 11 : 12,
                                ),
                              ),
                              
                              const SizedBox(width: 8),
                              
                              // Volume control
                              IconButton(
                                icon: Icon(
                                  _volume == 0
                                      ? Icons.volume_off
                                      : _volume < 0.5
                                          ? Icons.volume_down
                                          : Icons.volume_up,
                                  color: Colors.white,
                                  size: hasLimitedHeight ? 20 : 24,
                                ),
                                onPressed: _toggleMute,
                                tooltip: _volume > 0 ? 'Mute' : 'Unmute',
                                padding: EdgeInsets.all(hasLimitedHeight ? 4.0 : 8.0),
                                constraints: BoxConstraints(
                                  minWidth: hasLimitedHeight ? 36 : 48,
                                  minHeight: hasLimitedHeight ? 36 : 48,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              
              // Settings menu overlay
              if (_showSettings && !hasLimitedHeight)
                _buildSettingsMenu(),
            ],
          ),
        );
      },
    );
  }
  
  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final inFullscreen = _isFullscreen || isLandscape;
    
    // Detect if video is originally portrait (aspectRatio < 1) or landscape (aspectRatio >= 1)
    final videoAspectRatio = widget.controller.value.aspectRatio;
    final isVideoPortrait = videoAspectRatio > 0 && videoAspectRatio < 1.0;
    final isVideoLandscape = videoAspectRatio >= 1.0;
    
    debugPrint('[VideoPlayer] Build called - _isFullscreen: $_isFullscreen, isLandscape: $isLandscape, inFullscreen: $inFullscreen, videoAspectRatio: $videoAspectRatio, isVideoPortrait: $isVideoPortrait');
    
    // Only lock to landscape if video is landscape and we're in fullscreen
    if (_isFullscreen && isLandscape && isVideoLandscape) {
      try {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]).catchError((e) {
          debugPrint('[VideoPlayer] Error setting landscape in build: $e');
        });
      } catch (e) {
        debugPrint('[VideoPlayer] Error setting landscape orientation in build: $e');
      }
    } else if (_isFullscreen && isVideoPortrait) {
      // For portrait videos in fullscreen, allow portrait orientation
      try {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]).catchError((e) {
          debugPrint('[VideoPlayer] Error setting portrait in build: $e');
        });
      } catch (e) {
        debugPrint('[VideoPlayer] Error setting portrait orientation in build: $e');
      }
    }
    
    return AnimatedContainer(
      duration: _isDismissing ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      transform: Matrix4.identity()
        ..translate(0.0, _dismissOffset)
        ..scale(_dismissScale),
      child: Opacity(
        opacity: _dismissOpacity,
        child: GestureDetector(
          // Use translucent to allow gestures to pass through when not handled
          // When horizontal drag handlers are null (not in fullscreen), gestures pass through to PageView
          behavior: HitTestBehavior.translucent,
          onTap: () {
        final now = DateTime.now();
        if (_lastTapTime != null && now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
          // Double tap detected
          final RenderBox? box = context.findRenderObject() as RenderBox?;
          if (box != null) {
            final tapPosition = _lastTapPosition;
            _handleDoubleTap(tapPosition);
          }
        } else {
          // Single tap - show controls (especially important in fullscreen)
          debugPrint('[VideoPlayer] Video tapped - showing controls (fullscreen: $_isFullscreen)');
          // Defer setState to avoid calling during build phase
          Future.microtask(() {
            if (mounted) {
              setState(() {
                _showControls = true;
                _showSettings = false;
                _showSpeedMenu = false;
              });
            }
          });
          _showControlsTemporarily();
        }
        _lastTapTime = now;
      },
      onTapDown: (details) {
        final RenderBox? box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          _lastTapPosition = details.localPosition.dx;
        }
      },
      onVerticalDragStart: (details) {
        _gestureStartY = details.localPosition.dy;
        _gestureStartX = details.localPosition.dx;
        _isVerticalGesture = true;
        _isHorizontalGesture = false;
        _gestureVolume = _volume;
        _gestureBrightness = _brightness;
        _dismissStartTime = DateTime.now(); // Track start time for velocity calculation
        // Defer to avoid setState during gesture handling
        Future.microtask(() {
          _showControlsTemporarily();
        });
      },
      onVerticalDragUpdate: (details) {
        if (!_isVerticalGesture) return;
        
        final screenHeight = MediaQuery.of(context).size.height;
        final screenWidth = MediaQuery.of(context).size.width;
        final deltaY = details.localPosition.dy - _gestureStartY;
        final isLeftSide = _gestureStartX < screenWidth / 2;
        final isDownwardSwipe = deltaY > 0;
        
        // Check if this is a dismiss gesture (swipe down from anywhere)
        // Dismiss gesture: any downward swipe (more than 30px) from anywhere
        // OR swipe down from top 40% of screen (more permissive)
        final isTopArea = _gestureStartY < screenHeight * 0.4;
        final isDownwardMovement = isDownwardSwipe && deltaY > 30; // Lowered from 50px to 30px
        
        // Prioritize dismiss gesture if:
        // 1. Starting from top area, OR
        // 2. Any downward movement (more than 30px) - micro swipe support
        if ((isTopArea || isDownwardMovement) && isDownwardSwipe && widget.onDismiss != null) {
          // Dismiss gesture - show visual feedback
          _isDismissing = true;
          _dismissOffset = deltaY;
          
          // Calculate opacity and scale based on drag distance
          // More sensitive feedback - changes start earlier
          final dragProgress = (deltaY / screenHeight).clamp(0.0, 1.0);
          _dismissOpacity = 1.0 - (dragProgress * 0.6); // Fade more aggressively
          _dismissScale = 1.0 - (dragProgress * 0.15); // Scale down more (to 85%)
          
          Future.microtask(() {
            if (mounted) {
              setState(() {});
            }
          });
          return;
        }
        
        // Only do volume/brightness control if not dismissing
        if (!_isDismissing) {
          // Regular volume/brightness control (middle/bottom area)
          if (isLeftSide) {
            // Left side - brightness control
            final brightnessDelta = -deltaY / screenHeight;
            final newBrightness = (_gestureBrightness + brightnessDelta).clamp(0.0, 1.0);
            // Defer setState to avoid calling during gesture handling
            Future.microtask(() {
              if (mounted) {
                setState(() {
                  _brightness = newBrightness;
                });
              }
            });
            // Note: Actual brightness control would require platform channel
          } else {
            // Right side - volume control
            final volumeDelta = -deltaY / screenHeight;
            final newVolume = (_gestureVolume + volumeDelta).clamp(0.0, 1.0);
            _setVolume(newVolume);
          }
        }
      },
      onVerticalDragEnd: (details) {
        if (_isDismissing) {
          final screenHeight = MediaQuery.of(context).size.height;
          final dragProgress = (_dismissOffset / screenHeight).clamp(0.0, 1.0);
          
          // Calculate velocity for quick swipe detection
          double velocity = 0.0;
          if (_dismissStartTime != null) {
            final duration = DateTime.now().difference(_dismissStartTime!);
            if (duration.inMilliseconds > 0) {
              velocity = _dismissOffset / duration.inMilliseconds; // pixels per millisecond
            }
          }
          
          // Much lower threshold for micro swipe support
          // Dismiss if:
          // 1. Dragged more than 15% of screen height, OR
          // 2. Dragged more than 100px (micro swipe), OR
          // 3. High velocity swipe (more than 0.5 pixels/ms) with at least 50px movement
          final absoluteThreshold = 100.0; // Fixed pixel threshold for micro swipes
          final relativeThreshold = 0.15; // 15% of screen height (lowered from 25%)
          final velocityThreshold = 0.5; // pixels per millisecond
          final minVelocityDistance = 50.0; // Minimum distance for velocity-based dismissal
          
          final shouldDismiss = (dragProgress > relativeThreshold || 
                                 _dismissOffset > absoluteThreshold ||
                                 (velocity > velocityThreshold && _dismissOffset > minVelocityDistance));
          
          if (shouldDismiss && widget.onDismiss != null) {
            widget.onDismiss!();
          } else {
            // Snap back animation
            _isDismissing = false;
            _dismissOffset = 0.0;
            _dismissOpacity = 1.0;
            _dismissScale = 1.0;
            _dismissStartTime = null;
            Future.microtask(() {
              if (mounted) {
                setState(() {});
              }
            });
          }
        }
        _isVerticalGesture = false;
        _dismissStartTime = null;
      },
      // Only register horizontal drag handlers in fullscreen mode
      // When not in fullscreen, these handlers are null so gestures pass through to PageView
      onHorizontalDragStart: _isFullscreen ? (details) {
        // Only enable horizontal seek in fullscreen mode to avoid conflicts with PageView
        if (!_isDismissing) {
          _isHorizontalGesture = true;
          _isVerticalGesture = false;
          _gestureStartX = details.localPosition.dx;
          _showControlsTemporarily();
        }
      } : null,
      onHorizontalDragUpdate: _isFullscreen ? (details) {
        if (_isHorizontalGesture && !_isDismissing && widget.controller.value.isInitialized) {
          final screenWidth = MediaQuery.of(context).size.width;
          final deltaX = details.localPosition.dx - _gestureStartX;
          final duration = widget.controller.value.duration;
          
          // Calculate seek position based on drag distance
          // 1 screen width = full video duration
          final seekDelta = (deltaX / screenWidth) * duration.inMilliseconds;
          final currentPosition = widget.controller.value.position;
          final newPositionMs = (currentPosition.inMilliseconds + seekDelta.round()).clamp(0, duration.inMilliseconds);
          final clampedPosition = Duration(milliseconds: newPositionMs);
          
          // Update drag position for visual feedback
          _dragPosition = clampedPosition.inMilliseconds / duration.inMilliseconds;
          
          // Seek to new position
          widget.controller.seekTo(clampedPosition);
          
          Future.microtask(() {
            if (mounted) {
              setState(() {
                _isDragging = true;
              });
            }
          });
        }
      } : null,
      onHorizontalDragEnd: _isFullscreen ? (details) {
        if (_isHorizontalGesture) {
          Future.microtask(() {
            if (mounted) {
              setState(() {
                _isDragging = false;
                _isHorizontalGesture = false;
              });
            }
          });
        }
      } : null,
      child: inFullscreen
          ? OrientationBuilder(
              builder: (context, orientation) {
                // For portrait videos in fullscreen, hide all overlays by default
                final shouldHideOverlays = isVideoPortrait && widget.controller.value.isPlaying;
                
                return Container(
                  color: Colors.black,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildVideoPlayer(isFullscreen: true),
                      // Play button (shown when paused and controls are hidden)
                      if (!widget.controller.value.isPlaying && widget.controller.value.isInitialized && !_showControls)
                        Center(
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                _togglePlayPause();
                                // Hide play button immediately when tapped
                                setState(() {
                                  _showControls = false;
                                });
                              },
                              borderRadius: BorderRadius.circular(36),
                              child: Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.black.withOpacity(0.6),
                                ),
                                child: const Icon(
                                  Icons.play_circle_outline,
                                  size: 72,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      // Exit fullscreen button (hidden for portrait videos when playing, shown on tap)
                      if (!shouldHideOverlays || _showControls)
                        Positioned(
                          top: MediaQuery.of(context).padding.top + 8,
                          right: 8,
                          child: SafeArea(
                            child: GestureDetector(
                              onTap: () {
                                debugPrint('[VideoPlayer] Exit fullscreen button tapped');
                                _toggleFullscreen();
                              },
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.7),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.fullscreen_exit,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                            ),
                          ),
                        ),
                      // Full controls overlay (shown on tap, hidden by default for portrait videos)
                      // Background gradient that allows taps to pass through to parent GestureDetector
                      if (_showControls)
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: true, // Don't consume taps - let parent GestureDetector handle them
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withOpacity(0.5),
                                    Colors.transparent,
                                    Colors.transparent,
                                    Colors.black.withOpacity(0.8),
                                  ],
                                  stops: const [0.0, 0.2, 0.7, 1.0],
                                ),
                              ),
                            ),
                          ),
                        ),
                      // Controls (buttons handle their own taps)
                      if (_showControls)
                        _buildFullscreenControls(),
                      // Gesture indicators
                      if (_isVerticalGesture && !_isDismissing)
                        Positioned(
                          left: _gestureStartX < MediaQuery.of(context).size.width / 2 ? 50 : null,
                          right: _gestureStartX >= MediaQuery.of(context).size.width / 2 ? 50 : null,
                          top: MediaQuery.of(context).size.height / 2 - 30,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _gestureStartX < MediaQuery.of(context).size.width / 2
                                      ? Icons.brightness_6
                                      : _volume == 0
                                          ? Icons.volume_off
                                          : Icons.volume_up,
                                  color: Colors.white,
                                  size: 24,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _gestureStartX < MediaQuery.of(context).size.width / 2
                                      ? '${(_brightness * 100).round()}%'
                                      : '${(_volume * 100).round()}%',
                                  style: const TextStyle(color: Colors.white, fontSize: 16),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // Dismiss gesture indicator
                      if (_isDismissing)
                        Positioned(
                          top: MediaQuery.of(context).padding.top + 16,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(25),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.keyboard_arrow_down,
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Swipe down to close',
                                    style: const TextStyle(color: Colors.white, fontSize: 14),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // Horizontal seek indicator
                      if (_isHorizontalGesture && !_isDismissing)
                        Positioned(
                          top: MediaQuery.of(context).size.height / 2 - 30,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(25),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _gestureStartX > MediaQuery.of(context).size.width / 2
                                        ? Icons.fast_forward
                                        : Icons.fast_rewind,
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    _formatDuration(widget.controller.value.position),
                                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                                  const Text(
                                    ' / ',
                                    style: TextStyle(color: Colors.white70, fontSize: 16),
                                  ),
                                  Text(
                                    _formatDuration(widget.controller.value.duration),
                                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            )
          : Builder(
              builder: (context) {
                final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
                final isPlaying = widget.controller.value.isInitialized && widget.controller.value.isPlaying;
                
                // In portrait mode when playing, fill the screen and hide all metadata
                if (isPortrait && isPlaying && !_isFullscreen) {
                  return Container(
                    width: double.infinity,
                    height: double.infinity,
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Video fills entire screen
                        Center(
                          child: FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: widget.controller.value.size.width > 0 
                                  ? widget.controller.value.size.width 
                                  : MediaQuery.of(context).size.width,
                              height: widget.controller.value.size.height > 0 
                                  ? widget.controller.value.size.height 
                                  : MediaQuery.of(context).size.height,
                              child: _buildVideoPlayer(isFullscreen: false),
                            ),
                          ),
                        ),
                        // Minimal controls - only show on tap
                        if (_showControls)
                          GestureDetector(
                            onTap: () {},
                            behavior: HitTestBehavior.translucent,
                            child: _buildControls(),
                          ),
                        // Play button when paused (centered)
                        if (!isPlaying && widget.controller.value.isInitialized && !_showControls)
                          Center(
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () {
                                  _togglePlayPause();
                                  setState(() {
                                    _showControls = false;
                                  });
                                },
                                borderRadius: BorderRadius.circular(36),
                                child: Container(
                                  width: 72,
                                  height: 72,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.black.withOpacity(0.6),
                                  ),
                                  child: const Icon(
                                    Icons.play_circle_outline,
                                    size: 72,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                }
                
                // Normal portrait mode (not playing or paused)
                final screenSize = MediaQuery.of(context).size;
                final maxWidth = screenSize.width * 0.95;
                final maxHeight = screenSize.height * 0.6;
                
                double videoWidth = maxWidth;
                double videoHeight = maxHeight;
                
                if (widget.controller.value.aspectRatio > 0) {
                  if (widget.controller.value.aspectRatio > 1) {
                    videoHeight = videoWidth / widget.controller.value.aspectRatio;
                    if (videoHeight > maxHeight) {
                      videoHeight = maxHeight;
                      videoWidth = videoHeight * widget.controller.value.aspectRatio;
                    }
                  } else {
                    videoWidth = videoHeight * widget.controller.value.aspectRatio;
                    if (videoWidth > maxWidth) {
                      videoWidth = maxWidth;
                      videoHeight = videoWidth / widget.controller.value.aspectRatio;
                    }
                  }
                }
                
                return Center(
                  child: Container(
                    width: videoWidth,
                    height: videoHeight,
                    constraints: BoxConstraints(
                      maxWidth: maxWidth,
                      maxHeight: maxHeight,
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildVideoPlayer(isFullscreen: false),
                        if (_showControls && !_isFullscreen)
                          GestureDetector(
                            onTap: () {},
                            behavior: HitTestBehavior.translucent,
                            child: _buildControls(),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ),
      ),
    );
  }
}

/// Custom progress bar for video seeking
class VideoProgressBar extends StatefulWidget {
  final VideoPlayerController controller;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;
  
  const VideoProgressBar({
    super.key,
    required this.controller,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });
  
  @override
  State<VideoProgressBar> createState() => _VideoProgressBarState();
}

class _VideoProgressBarState extends State<VideoProgressBar> {
  double _dragValue = 0.0;
  bool _isDragging = false;
  
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: (details) {
        setState(() {
          _isDragging = true;
        });
        widget.onDragStart();
      },
      onHorizontalDragUpdate: (details) {
        final RenderBox? box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          final double dx = details.localPosition.dx;
          final double position = (dx / box.size.width).clamp(0.0, 1.0);
          
          setState(() {
            _dragValue = position;
          });
          widget.onDragUpdate(position);
        }
      },
      onHorizontalDragEnd: (details) {
        setState(() {
          _isDragging = false;
        });
        widget.onDragEnd(_dragValue);
      },
      onTapDown: (details) {
        final RenderBox? box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          final double dx = details.localPosition.dx;
          final double position = (dx / box.size.width).clamp(0.0, 1.0);
          
          setState(() {
            _dragValue = position;
          });
          widget.onDragEnd(position);
        }
      },
      child: Container(
        height: 6,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          color: Colors.white.withOpacity(0.3),
        ),
        child: Stack(
          children: [
            // Buffered progress
            FractionallySizedBox(
              widthFactor: widget.controller.value.buffered.isEmpty
                  ? 0.0
                  : widget.controller.value.buffered.last.end.inMilliseconds /
                      widget.controller.value.duration.inMilliseconds,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: Colors.white.withOpacity(0.5),
                ),
              ),
            ),
            
            // Current progress
            FractionallySizedBox(
              widthFactor: _isDragging
                  ? _dragValue
                  : widget.controller.value.position.inMilliseconds /
                      widget.controller.value.duration.inMilliseconds,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: AppTheme.accent,
                ),
              ),
            ),
            
            // Drag handle
            if (_isDragging)
              Positioned(
                left: (_dragValue * ((context.findRenderObject() as RenderBox?)?.size.width ?? 0.0)) - 8,
                top: -6,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.accent,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

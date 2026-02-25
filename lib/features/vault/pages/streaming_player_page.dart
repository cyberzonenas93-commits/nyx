import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../../../app/theme.dart';
import '../../../core/services/video_extraction_service.dart';

/// Streaming player page for one-click video playback
class StreamingPlayerPage extends StatefulWidget {
  final String videoUrl;
  final ExtractedVideo? extractedVideo;

  const StreamingPlayerPage({
    super.key,
    required this.videoUrl,
    this.extractedVideo,
  });

  @override
  State<StreamingPlayerPage> createState() => _StreamingPlayerPageState();
}

class _StreamingPlayerPageState extends State<StreamingPlayerPage> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _isLoading = true;
  bool _isPlaying = false;
  bool _userPaused = false; // Track if user manually paused
  String? _errorMessage;
  bool _showControls = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Timer? _autoResumeTimer; // Periodic check to keep video playing

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Ensure video starts in portrait/inline mode (not fullscreen)
    // This allows ads to be skipped in minimized mode
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _initializePlayer();
    _startAutoResumeTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoResumeTimer?.cancel();
    // Reset orientation when disposing
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _controller?.removeListener(_videoListener);
    _controller?.dispose();
    super.dispose();
  }

  /// Start periodic timer to check and resume video if it auto-paused
  /// This works in both minimized and fullscreen modes
  void _startAutoResumeTimer() {
    _autoResumeTimer?.cancel();
    _autoResumeTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted || _controller == null || !_controller!.value.isInitialized) {
        timer.cancel();
        return;
      }
      
      // If video should be playing but isn't, and user didn't pause it
      // Check more frequently (every 500ms) to catch auto-pauses quickly
      if (!_userPaused && 
          _controller!.value.position < _controller!.value.duration &&
          !_controller!.value.isPlaying) {
        // Check if pause was recent (within last 2 seconds) - likely automatic
        final pauseDuration = _lastPauseTime != null 
            ? DateTime.now().difference(_lastPauseTime!)
            : const Duration(seconds: 10); // If no pause time, assume it's been a while
        
        // Only auto-resume if pause was recent (likely automatic, not user-initiated)
        if (pauseDuration.inSeconds < 2) {
          try {
            _controller!.play();
            debugPrint('[VideoPlayer] Auto-resumed video from timer (was paused for ${pauseDuration.inMilliseconds}ms)');
          } catch (e) {
            debugPrint('[VideoPlayer] Error auto-resuming from timer: $e');
          }
        }
      }
    });
  }

  Future<void> _initializePlayer() async {
    try {
      // Use extracted video stream if available, otherwise use direct URL
      final streamUrl = widget.extractedVideo?.bestStream?.url ?? widget.videoUrl;
      
      _controller = VideoPlayerController.networkUrl(Uri.parse(streamUrl))
        ..addListener(_videoListener)
        ..setLooping(false);

      await _controller!.initialize();
      
      if (mounted) {
        setState(() {
          _isLoading = false;
          _duration = _controller!.value.duration;
        });
      }
    } catch (e) {
      debugPrint('Error initializing video player: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load video: $e';
        });
      }
    }
  }

  DateTime? _lastPauseTime;
  DateTime? _lastPlayTime;

  void _videoListener() {
    if (_controller != null && mounted) {
      final wasPlaying = _isPlaying;
      final isNowPlaying = _controller!.value.isPlaying;
      
      setState(() {
        _position = _controller!.value.position;
        _duration = _controller!.value.duration;
        _isPlaying = isNowPlaying;
      });
      
      // Track play/pause times
      if (isNowPlaying && !wasPlaying) {
        _lastPlayTime = DateTime.now();
        _userPaused = false; // Reset when video starts playing
      } else if (!isNowPlaying && wasPlaying) {
        _lastPauseTime = DateTime.now();
      }
      
      // Prevent auto-pause: if video was playing and got paused automatically, resume it
      // This works in both minimized and fullscreen modes
      // Only auto-resume if:
      // 1. User didn't manually pause (checked via _userPaused flag)
      // 2. Video is not at the end
      // 3. Pause happened very recently (< 1 second) - likely automatic
      if (wasPlaying && !isNowPlaying && !_userPaused && _controller!.value.position < _controller!.value.duration) {
        final pauseDuration = _lastPauseTime != null 
            ? DateTime.now().difference(_lastPauseTime!)
            : Duration.zero;
        
        // Auto-resume if pause was very recent (likely automatic)
        // More lenient timeout (1 second) to catch various auto-pause scenarios
        if (pauseDuration.inMilliseconds < 1000) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted && 
                _controller != null && 
                !_controller!.value.isPlaying && 
                !_userPaused &&
                _controller!.value.position < _controller!.value.duration) {
              try {
                _controller!.play();
                debugPrint('[VideoPlayer] Auto-resumed video from listener (pause duration: ${pauseDuration.inMilliseconds}ms)');
              } catch (e) {
                debugPrint('[VideoPlayer] Error auto-resuming video: $e');
              }
            }
          });
        }
      }
    }
  }

  void _togglePlayPause() {
    if (_controller == null) return;
    
    if (_controller!.value.isPlaying) {
      _userPaused = true;
      _controller!.pause();
    } else {
      _userPaused = false;
      _controller!.play();
    }
  }

  void _seekTo(Duration position) {
    _controller?.seekTo(position);
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.extractedVideo?.title ?? 'Video',
          style: const TextStyle(color: Colors.white),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.accent),
            )
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: AppTheme.warning,
                        size: 64,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.accent,
                        ),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                )
              : GestureDetector(
                  onTap: () {
                    setState(() {
                      _showControls = !_showControls;
                    });
                  },
                  child: Container(
                    color: Colors.black,
                    child: Stack(
                      children: [
                        // Video player - constrained to minimized/inline mode
                        Center(
                          child: Container(
                            // Constrain video to minimized/inline mode (not fullscreen)
                            // This allows ads to be skipped in minimized mode
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.95,
                              maxHeight: MediaQuery.of(context).size.height * 0.6,
                            ),
                            child: AspectRatio(
                              aspectRatio: _controller?.value.aspectRatio ?? 16 / 9,
                              child: VideoPlayer(_controller!),
                            ),
                          ),
                        ),
                        
                        // Controls overlay
                        if (_showControls)
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withOpacity(0.7),
                                    Colors.transparent,
                                    Colors.transparent,
                                    Colors.black.withOpacity(0.7),
                                  ],
                                ),
                              ),
                              child: Column(
                                children: [
                                  const Spacer(),
                                  
                                  // Progress bar
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    child: Column(
                                      children: [
                                        // Time indicators
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              _formatDuration(_position),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                              ),
                                            ),
                                            Text(
                                              _formatDuration(_duration),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        // Progress slider
                                        Slider(
                                          value: _position.inMilliseconds.toDouble(),
                                          min: 0,
                                          max: _duration.inMilliseconds > 0
                                              ? _duration.inMilliseconds.toDouble()
                                              : 1,
                                          onChanged: (value) {
                                            _seekTo(Duration(milliseconds: value.toInt()));
                                          },
                                          activeColor: AppTheme.accent,
                                        ),
                                      ],
                                    ),
                                  ),
                                  
                                  // Control buttons
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        IconButton(
                                          icon: Icon(
                                            _isPlaying ? Icons.pause : Icons.play_arrow,
                                            color: Colors.white,
                                            size: 48,
                                          ),
                                          onPressed: _togglePlayPause,
                                        ),
                                      ],
                                    ),
                                  ),
                                  
                                  const SizedBox(height: 16),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
    );
  }
}

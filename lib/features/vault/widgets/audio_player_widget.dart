import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/services/media_playback_manager.dart';

/// Full-featured audio player widget with controls
class AudioPlayerWidget extends StatefulWidget {
  final String audioPath;
  final String? title;
  final String? mediaId;
  
  const AudioPlayerWidget({
    super.key,
    required this.audioPath,
    this.title,
    this.mediaId,
  });
  
  @override
  State<AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<AudioPlayerWidget> {
  late AudioPlayer _audioPlayer;
  bool _isPlaying = false;
  bool _isLoading = true;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double _volume = 1.0;
  bool _isMuted = false;
  bool _isSeeking = false; // Prevent multiple simultaneous seek operations
  MediaPlaybackManager? _playbackManager; // Store reference for safe access in dispose
  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  bool _isDisposed = false;
  
  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    
    // In-app playback only (no background audio)
    _audioPlayer.setPlayerMode(PlayerMode.lowLatency);
    
    _initializePlayer();
    _stateSubscription = _audioPlayer.onPlayerStateChanged.listen((state) {
      if (_isDisposed || !mounted) return;
      Future.microtask(() {
        if (!_isDisposed && mounted) {
          setState(() {
            _isPlaying = state == PlayerState.playing;
          });
        }
      });
    });
    _durationSubscription = _audioPlayer.onDurationChanged.listen((duration) {
      if (_isDisposed || !mounted) return;
      Future.microtask(() {
        if (!_isDisposed && mounted) {
          setState(() {
            _duration = duration;
            _isLoading = false;
          });
        }
      });
    });
    _positionSubscription = _audioPlayer.onPositionChanged.listen((position) {
      if (_isDisposed || !mounted || _isSeeking) return;
      Future.microtask(() {
        if (!_isDisposed && mounted && !_isSeeking) {
          setState(() {
            _position = position;
          });
        }
      });
    });
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Store reference to playback manager for safe access in dispose
    if (_playbackManager == null && widget.mediaId != null) {
      _playbackManager = Provider.of<MediaPlaybackManager>(context, listen: false);
      _playbackManager!.registerAudio(_audioPlayer, widget.mediaId!);
    }
  }
  
  Future<void> _initializePlayer() async {
    try {
      await _audioPlayer.setSource(DeviceFileSource(widget.audioPath));
      
      await _audioPlayer.setReleaseMode(ReleaseMode.stop);
      
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[AudioPlayer] Error initializing: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
  
  Future<void> _togglePlayPause() async {
    try {
      if (_isPlaying) {
        await _audioPlayer.pause();
      } else {
        await _audioPlayer.resume();
      }
    } catch (e) {
      debugPrint('[AudioPlayer] Error toggling play/pause: $e');
    }
  }
  
  Future<void> _seekTo(double position) async {
    // Prevent seeking if already seeking, loading, or duration is invalid
    if (_isSeeking || _isLoading || _duration.inMilliseconds <= 0) {
      return;
    }
    
    try {
      _isSeeking = true;
      final positionMs = (position * _duration.inMilliseconds).round();
      
      // Clamp position to valid range (0 to duration)
      final clampedMs = positionMs.clamp(0, _duration.inMilliseconds);
      final clampedPosition = Duration(milliseconds: clampedMs);
      
      await _audioPlayer.seek(clampedPosition);
      
      // Update position immediately for better UX
      if (mounted) {
        setState(() {
          _position = clampedPosition;
        });
      }
    } catch (e) {
      debugPrint('[AudioPlayer] Error seeking: $e');
    } finally {
      // Reset seeking flag after a short delay to allow position updates
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _isSeeking = false;
        }
      });
    }
  }
  
  Future<void> _skipForward() async {
    if (_isSeeking || _isLoading || _duration.inMilliseconds <= 0) {
      return;
    }
    
    try {
      _isSeeking = true;
      final newPosition = _position + const Duration(seconds: 10);
      final clampedPosition = newPosition > _duration ? _duration : newPosition;
      await _audioPlayer.seek(clampedPosition);
      
      if (mounted) {
        setState(() {
          _position = clampedPosition;
        });
      }
    } catch (e) {
      debugPrint('[AudioPlayer] Error skipping forward: $e');
    } finally {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _isSeeking = false;
        }
      });
    }
  }
  
  Future<void> _skipBackward() async {
    if (_isSeeking || _isLoading || _duration.inMilliseconds <= 0) {
      return;
    }
    
    try {
      _isSeeking = true;
      final newPosition = _position - const Duration(seconds: 10);
      final clampedPosition = newPosition < Duration.zero ? Duration.zero : newPosition;
      await _audioPlayer.seek(clampedPosition);
      
      if (mounted) {
        setState(() {
          _position = clampedPosition;
        });
      }
    } catch (e) {
      debugPrint('[AudioPlayer] Error skipping backward: $e');
    } finally {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _isSeeking = false;
        }
      });
    }
  }
  
  Future<void> _setVolume(double volume) async {
    try {
      Future.microtask(() {
        if (!_isDisposed && mounted) {
          setState(() {
            _volume = volume.clamp(0.0, 1.0);
            _isMuted = _volume == 0.0;
          });
        }
      });
      await _audioPlayer.setVolume(volume.clamp(0.0, 1.0));
    } catch (e) {
      debugPrint('[AudioPlayer] Error setting volume: $e');
    }
  }
  
  Future<void> _toggleMute() async {
    try {
      if (_isMuted) {
        await _setVolume(1.0);
      } else {
        await _setVolume(0.0);
      }
    } catch (e) {
      debugPrint('[AudioPlayer] Error toggling mute: $e');
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
  
  @override
  void dispose() {
    _isDisposed = true;
    
    // Cancel all subscriptions
    _stateSubscription?.cancel();
    _stateSubscription = null;
    _durationSubscription?.cancel();
    _durationSubscription = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    
    if (widget.mediaId != null && _playbackManager != null) {
      try {
        _playbackManager!.unregisterAudio(_audioPlayer);
      } catch (e) {
        debugPrint('[AudioPlayer] Error unregistering: $e');
      }
    }
    
    _audioPlayer.stop();
    _audioPlayer.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.surface,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Title
          if (widget.title != null) ...[
            Text(
              widget.title!,
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
          ],
          
          // Progress bar
          Column(
            children: [
              Slider(
                value: _duration.inMilliseconds > 0
                    ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
                    : 0.0,
                onChanged: (_isLoading || _isSeeking || _duration.inMilliseconds <= 0) ? null : _seekTo,
                activeColor: AppTheme.accent,
                inactiveColor: AppTheme.text.withOpacity(0.3),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(_position),
                      style: TextStyle(
                        color: AppTheme.text.withOpacity(0.7),
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      _formatDuration(_duration),
                      style: TextStyle(
                        color: AppTheme.text.withOpacity(0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 16),
          
          // Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Skip backward
              IconButton(
                onPressed: _isLoading ? null : _skipBackward,
                icon: const Icon(Icons.replay_10, size: 32),
                color: AppTheme.text,
                tooltip: 'Skip backward 10s',
              ),
              const SizedBox(width: 8),
              
              // Play/Pause
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.accent,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  onPressed: _isLoading ? null : _togglePlayPause,
                  icon: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 40,
                  ),
                  color: AppTheme.primary,
                  tooltip: _isPlaying ? 'Pause' : 'Play',
                ),
              ),
              const SizedBox(width: 8),
              
              // Skip forward
              IconButton(
                onPressed: _isLoading ? null : _skipForward,
                icon: const Icon(Icons.forward_10, size: 32),
                color: AppTheme.text,
                tooltip: 'Skip forward 10s',
              ),
              const SizedBox(width: 16),
              
              // Volume control
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: _isLoading ? null : _toggleMute,
                    icon: Icon(
                      _isMuted ? Icons.volume_off : Icons.volume_up,
                      size: 24,
                    ),
                    color: AppTheme.text,
                    tooltip: _isMuted ? 'Unmute' : 'Mute',
                  ),
                  SizedBox(
                    width: 100,
                    child: Slider(
                      value: _volume,
                      onChanged: _isLoading ? null : _setVolume,
                      activeColor: AppTheme.accent,
                      inactiveColor: AppTheme.text.withOpacity(0.3),
                      min: 0.0,
                      max: 1.0,
                    ),
                  ),
                ],
              ),
            ],
          ),
          
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

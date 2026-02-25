import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';

/// Manages media playback to ensure only one video or audio plays at a time
class MediaPlaybackManager extends ChangeNotifier {
  static final MediaPlaybackManager _instance = MediaPlaybackManager._internal();
  factory MediaPlaybackManager() => _instance;
  MediaPlaybackManager._internal();

  VideoPlayerController? _currentVideoController;
  AudioPlayer? _currentAudioPlayer;
  String? _currentMediaId;

  /// Register a video controller as currently playing
  /// Stops any other playing media
  void registerVideo(VideoPlayerController controller, String mediaId) {
    // Stop any currently playing audio
    if (_currentAudioPlayer != null) {
      _stopCurrentAudio();
    }

    // Stop any currently playing video (except the new one)
    if (_currentVideoController != null && _currentVideoController != controller) {
      _stopCurrentVideo();
    }

    _currentVideoController = controller;
    _currentAudioPlayer = null;
    _currentMediaId = mediaId;
    notifyListeners();
  }

  /// Register an audio player as currently playing
  /// Stops any other playing media
  void registerAudio(AudioPlayer player, String mediaId) {
    // Stop any currently playing video
    if (_currentVideoController != null) {
      _stopCurrentVideo();
    }

    // Stop any currently playing audio (except the new one)
    if (_currentAudioPlayer != null && _currentAudioPlayer != player) {
      _stopCurrentAudio();
    }

    _currentVideoController = null;
    _currentAudioPlayer = player;
    _currentMediaId = mediaId;
    notifyListeners();
  }

  /// Unregister a video controller
  void unregisterVideo(VideoPlayerController controller) {
    if (_currentVideoController == controller) {
      _currentVideoController = null;
      if (_currentMediaId != null) {
        _currentMediaId = null;
      }
      notifyListeners();
    }
  }

  /// Unregister an audio player
  void unregisterAudio(AudioPlayer player) {
    if (_currentAudioPlayer == player) {
      _currentAudioPlayer = null;
      if (_currentMediaId != null) {
        _currentMediaId = null;
      }
      notifyListeners();
    }
  }

  /// Stop all currently playing media
  void stopAll() {
    _stopCurrentVideo();
    _stopCurrentAudio();
    _currentMediaId = null;
    notifyListeners();
  }

  void _stopCurrentVideo() {
    if (_currentVideoController != null) {
      try {
        if (_currentVideoController!.value.isPlaying) {
          _currentVideoController!.pause();
        }
      } catch (e) {
        debugPrint('[MediaPlaybackManager] Error stopping video: $e');
      }
      _currentVideoController = null;
    }
  }

  void _stopCurrentAudio() {
    if (_currentAudioPlayer != null) {
      try {
        _currentAudioPlayer!.stop();
      } catch (e) {
        debugPrint('[MediaPlaybackManager] Error stopping audio: $e');
      }
      _currentAudioPlayer = null;
    }
  }

  /// Check if a specific media is currently playing
  bool isMediaPlaying(String mediaId) {
    return _currentMediaId == mediaId;
  }

  /// Get the currently playing media ID
  String? get currentMediaId => _currentMediaId;
  
  /// Get the current video controller (if playing)
  VideoPlayerController? get currentVideoController => _currentVideoController;
  
  /// Get the current audio player (if playing)
  AudioPlayer? get currentAudioPlayer => _currentAudioPlayer;
  
  /// Check if video is currently playing
  bool get isVideoPlaying => _currentVideoController != null && _currentVideoController!.value.isPlaying;
  
  /// Check if audio is currently playing
  bool get isAudioPlaying => _currentAudioPlayer != null && _currentAudioPlayer!.state == PlayerState.playing;
}

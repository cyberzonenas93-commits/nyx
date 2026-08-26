import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/vault_item.dart';
import 'media_playback_manager.dart';
import 'vault_service.dart';

/// Background video-poster generation (safe, serialized).
///
/// Goal:
/// - Gradually generate missing *first-frame* posters for videos, without crashing iOS.
/// - Run only when the app is "idle enough":
///   - no background import currently processing
///   - no video currently playing
/// - Generate at most one poster per tick (low and steady).
///
/// Notes:
/// - On iOS, native thumbnail extraction can crash for certain codecs/containers.
///   This service uses a conservative safety gate on iOS:
///   - MP4/MOV/M4V only
///   - <= 300MB only
/// - Thumbnail generation itself is serialized inside [VaultService].
class VideoPosterBackgroundService extends ChangeNotifier {
  static const String _importProcessingKey = 'background_import_processing';

  final VaultService _vaultService;
  final MediaPlaybackManager _playbackManager;

  Timer? _timer;
  bool _tickInProgress = false;

  bool _enabled = false;
  bool get enabled => _enabled;

  /// How often to attempt generating one poster.
  final Duration interval;

  VideoPosterBackgroundService(
    this._vaultService,
    this._playbackManager, {
    this.interval = const Duration(seconds: 60),
  });

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (_enabled) {
      _timer ??= Timer.periodic(interval, (_) => _tick());
      unawaited(_tick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  Future<void> runNow() async => _tick();

  Future<void> _tick() async {
    if (!_enabled) return;
    if (_tickInProgress) return;
    if (!_vaultService.isInitialized) return;
    if (_playbackManager.isVideoPlaying) return;

    _tickInProgress = true;
    try {
      // Don't compete with bulk imports (highest crash risk period).
      final prefs = await SharedPreferences.getInstance();
      final isImporting = prefs.getBool(_importProcessingKey) ?? false;
      if (isImporting) return;

      final candidate = await _findNextCandidate();
      if (candidate == null) return;

      debugPrint(
          '[PosterBG] Generating poster for: ${candidate.displayName} (${candidate.id})');
      await _vaultService.generateThumbnailForItem(candidate.id);
      notifyListeners();

      // Small cooldown so we don't saturate I/O.
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      debugPrint('[PosterBG] Tick error: $e');
    } finally {
      _tickInProgress = false;
    }
  }

  Future<VaultItem?> _findNextCandidate() async {
    for (final item in _vaultService.items) {
      if (item.type != VaultItemType.video) continue;

      final thumbPath = _vaultService.getThumbnailPathForItem(item);
      if (thumbPath != null && await File(thumbPath).exists()) continue;

      final filePath = _vaultService.getFilePath(item.id);
      if (filePath == null) continue;

      final file = File(filePath);
      if (!await file.exists()) continue;

      // Avoid zero-byte / incomplete files. Prefer metadata so the scan does
      // not decrypt videos just to decide whether one needs a poster.
      final size = item.sizeBytes > 0
          ? item.sizeBytes
          : await file.length().catchError((_) => 0);
      if (size <= 0) continue;

      if (Platform.isIOS) {
        final lower = item.originalFilename.toLowerCase();
        final isCommonContainer = lower.endsWith('.mp4') ||
            lower.endsWith('.mov') ||
            lower.endsWith('.m4v');
        if (!isCommonContainer) continue;
        if (size > 300 * 1024 * 1024) continue;
      }

      return item;
    }

    return null;
  }
}

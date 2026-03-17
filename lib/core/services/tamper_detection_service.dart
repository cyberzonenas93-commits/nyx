import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'auth_service.dart';

/// Service for detecting tampering and optionally wiping data
/// Supports standard mode (lockouts) and strict mode (irreversible wipe)
class TamperDetectionService {
  final AuthService _authService;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  bool _strictModeEnabled = false;
  int _failedAttempts = 0;
  static const int maxFailedAttempts = 5;

  TamperDetectionService(this._authService);

  /// Check if strict mode is enabled
  Future<bool> isStrictModeEnabled() async {
    final enabled = await _secureStorage.read(key: 'tamper_strict_mode');
    _strictModeEnabled = enabled == 'true';
    return _strictModeEnabled;
  }

  /// Enable strict mode (requires explicit confirmation)
  Future<void> enableStrictMode() async {
    await _secureStorage.write(key: 'tamper_strict_mode', value: 'true');
    _strictModeEnabled = true;
  }

  /// Disable strict mode
  Future<void> disableStrictMode() async {
    await _secureStorage.write(key: 'tamper_strict_mode', value: 'false');
    _strictModeEnabled = false;
  }

  /// Check for tampering conditions
  Future<TamperResult> checkTampering() async {
    final strictMode = await isStrictModeEnabled();

    // Check for debugger attachment (simplified - would need platform channels)
    final hasDebugger = await _checkDebugger();

    // Check for root/jailbreak (simplified - would need platform channels)
    final isRooted = await _checkRoot();

    // Check for failed unlock attempts
    final tooManyFailures = _failedAttempts >= maxFailedAttempts;

    if (strictMode) {
      // Strict mode: Any tampering triggers wipe
      if (hasDebugger || isRooted || tooManyFailures) {
        return TamperResult(
          isTampered: true,
          reason: _getTamperReason(hasDebugger, isRooted, tooManyFailures),
          shouldWipe: true,
        );
      }
    } else {
      // Standard mode: Only lockouts, no wipe
      if (tooManyFailures) {
        return TamperResult(
          isTampered: true,
          reason: 'Too many failed unlock attempts',
          shouldWipe: false,
        );
      }
    }

    return TamperResult(
      isTampered: false,
      reason: null,
      shouldWipe: false,
    );
  }

  /// Record a failed unlock attempt
  Future<TamperResult> recordFailedAttempt() async {
    _failedAttempts++;
    await _secureStorage.write(
      key: 'failed_unlock_attempts',
      value: _failedAttempts.toString(),
    );

    // Check if we should trigger tamper response
    final result = await checkTampering();
    if (result.shouldWipe) {
      await _wipeVault();
    }
    return result;
  }

  /// Reset failed attempts (on successful unlock)
  Future<void> resetFailedAttempts() async {
    _failedAttempts = 0;
    await _secureStorage.write(
      key: 'failed_unlock_attempts',
      value: '0',
    );
  }

  /// Perform irreversible data wipe (strict mode only)
  Future<void> _wipeVault() async {
    debugPrint('[TamperDetection] Wiping data due to tampering');

    try {
      _failedAttempts = 0;
      await _authService.lockVault();

      // Clear all secure storage
      await _secureStorage.deleteAll();

      // Delete app data directories
      final appDir = await getApplicationDocumentsDirectory();

      await for (final entity in appDir.list(followLinks: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        final shouldDelete = name == 'messages' ||
            name == 'vault' ||
            name.startsWith('vault_') ||
            name == 'vault_backup' ||
            name.endsWith('_backup');

        if (!shouldDelete) {
          continue;
        }

        if (entity is Directory) {
          await entity.delete(recursive: true);
        } else if (entity is File) {
          await entity.delete();
        }
      }

      // Reset app state
      // Note: This would typically require app restart
      debugPrint('[TamperDetection] Data wiped successfully');
    } catch (e) {
      debugPrint('[TamperDetection] Error wiping data: $e');
    }
  }

  /// Check for debugger attachment (simplified)
  /// In production, use platform channels for proper detection
  Future<bool> _checkDebugger() async {
    // Simplified check - in production, use native code
    // Android: Debug.isDebuggerConnected()
    // iOS: ptrace(PT_DENY_ATTACH, 0, 0, 0)
    return false; // Placeholder
  }

  /// Check for root/jailbreak (simplified)
  /// In production, use platform channels for proper detection
  Future<bool> _checkRoot() async {
    // Simplified check - in production, use native code
    // Android: Check for su binary, root apps, etc.
    // iOS: Check for jailbreak indicators
    return false; // Placeholder
  }

  /// Get tamper reason string
  String _getTamperReason(
      bool hasDebugger, bool isRooted, bool tooManyFailures) {
    final reasons = <String>[];
    if (hasDebugger) reasons.add('Debugger detected');
    if (isRooted) reasons.add('Root/jailbreak detected');
    if (tooManyFailures) reasons.add('Too many failed attempts');
    return reasons.join(', ');
  }

  /// Load failed attempts from storage
  Future<void> loadFailedAttempts() async {
    final attempts = await _secureStorage.read(key: 'failed_unlock_attempts');
    _failedAttempts = attempts != null ? int.tryParse(attempts) ?? 0 : 0;
  }
}

/// Result of tamper detection check
class TamperResult {
  final bool isTampered;
  final String? reason;
  final bool shouldWipe;

  TamperResult({
    required this.isTampered,
    this.reason,
    required this.shouldWipe,
  });
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service to keep app active in background for imports
class BackgroundExecutionService {
  static const MethodChannel _channel = MethodChannel('com.nyx.app/background_execution');
  static BackgroundExecutionService? _instance;
  
  BackgroundExecutionService._();
  
  factory BackgroundExecutionService() {
    _instance ??= BackgroundExecutionService._();
    return _instance!;
  }
  
  /// Request background execution time (iOS) or start foreground service (Android)
  /// Returns true if background execution was granted/started
  Future<bool> requestBackgroundExecution({String? reason}) async {
    try {
      final result = await _channel.invokeMethod<bool>('requestBackgroundExecution', {
        'reason': reason ?? 'Importing files to vault',
      });
      return result ?? false;
    } catch (e) {
      debugPrint('[BackgroundExecutionService] Error requesting background execution: $e');
      return false;
    }
  }
  
  /// End background execution (iOS) or stop foreground service (Android)
  Future<void> endBackgroundExecution() async {
    try {
      await _channel.invokeMethod('endBackgroundExecution');
    } catch (e) {
      debugPrint('[BackgroundExecutionService] Error ending background execution: $e');
    }
  }
  
  /// Update background task progress (for notification on Android)
  Future<void> updateProgress({
    required int current,
    required int total,
    String? status,
  }) async {
    try {
      await _channel.invokeMethod('updateProgress', {
        'current': current,
        'total': total,
        'status': status ?? 'Processing...',
      });
    } catch (e) {
      debugPrint('[BackgroundExecutionService] Error updating progress: $e');
    }
  }
}

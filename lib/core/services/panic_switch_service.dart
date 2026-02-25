import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Service for panic switch - exits app when device is face-down
class PanicSwitchService {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  bool _isEnabled = false;
  bool _isMonitoring = false;
  double _lastZ = 0;
  int _faceDownCount = 0;
  
  /// Check if panic switch is enabled
  Future<bool> isEnabled() async {
    final enabled = await _secureStorage.read(key: 'panic_switch_enabled');
    return enabled == 'true';
  }
  
  /// Enable panic switch
  Future<void> enable() async {
    await _secureStorage.write(key: 'panic_switch_enabled', value: 'true');
    _isEnabled = true;
    await startMonitoring();
  }
  
  /// Disable panic switch
  Future<void> disable() async {
    await _secureStorage.write(key: 'panic_switch_enabled', value: 'false');
    _isEnabled = false;
    await stopMonitoring();
  }
  
  /// Start monitoring device orientation using accelerometer
  Future<void> startMonitoring() async {
    if (_isMonitoring) return;
    
    final enabled = await isEnabled();
    if (!enabled) {
      _isEnabled = false;
      return;
    }
    
    _isEnabled = true;
    _isMonitoring = true;
    _faceDownCount = 0;
    
    // Throttle accelerometer events to reduce CPU usage
    // Process only 5 events per second instead of potentially hundreds
    DateTime? _lastProcessedTime;
    const throttleInterval = Duration(milliseconds: 200); // 5 events per second
    
    // Listen to accelerometer to detect face-down
    _accelerometerSubscription = accelerometerEventStream().listen((event) {
      if (!_isMonitoring || !_isEnabled) return;
      
      // Throttle: only process if enough time has passed
      final now = DateTime.now();
      if (_lastProcessedTime != null && 
          now.difference(_lastProcessedTime!) < throttleInterval) {
        return; // Skip this event
      }
      _lastProcessedTime = now;
      
      // Z-axis pointing up (negative) indicates face-down
      // Threshold: z < -8 m/s² (device is face-down)
      final z = event.z;
      
      if (z < -8.0) {
        _faceDownCount++;
        // Require 3 consecutive readings to avoid false positives
        if (_faceDownCount >= 3) {
          _triggerPanicExit();
        }
      } else {
        _faceDownCount = 0; // Reset counter if not face-down
      }
      
      _lastZ = z;
    });
  }
  
  /// Stop monitoring
  Future<void> stopMonitoring() async {
    _isMonitoring = false;
    await _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    _faceDownCount = 0;
  }
  
  /// Handle face-down detection from widget (fallback)
  Future<void> checkFaceDown(dynamic orientation) async {
    // This is a fallback - accelerometer is primary method
    // Can be used for additional checks if needed
  }
  
  /// Trigger panic exit - minimize app or exit
  Future<void> _triggerPanicExit() async {
    if (!_isEnabled) return;
    
    // Stop monitoring to prevent multiple triggers
    await stopMonitoring();
    
    // Use SystemNavigator to exit app (or minimize)
    // On mobile, this typically minimizes the app
    SystemNavigator.pop();
  }
  
  /// Manual trigger (for testing)
  Future<void> triggerPanicExit() async {
    await _triggerPanicExit();
  }
}

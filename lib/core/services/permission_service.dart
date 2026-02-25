import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

/// Unified permission service for handling all app permissions
class PermissionService {
  static final PermissionService _instance = PermissionService._internal();
  factory PermissionService() => _instance;
  PermissionService._internal();

  /// Request camera permission
  /// Returns true if granted, false otherwise
  Future<bool> requestCameraPermission() async {
    try {
      debugPrint('[PermissionService] === Starting camera permission request ===');
      
      // First check current status
      var status = await Permission.camera.status;
      debugPrint('[PermissionService] Camera permission initial status: $status');
      debugPrint('[PermissionService] Camera permission - granted: ${status.isGranted}, denied: ${status.isDenied}, permanentlyDenied: ${status.isPermanentlyDenied}, restricted: ${status.isRestricted}, limited: ${status.isLimited}');
      
      if (status.isGranted) {
        debugPrint('[PermissionService] Camera permission already granted');
        return true;
      }
      
      if (status.isPermanentlyDenied) {
        debugPrint('[PermissionService] Camera permission permanently denied - user must enable in Settings');
        return false;
      }
      
      if (status.isRestricted) {
        debugPrint('[PermissionService] Camera permission restricted by system');
        return false;
      }
      
      // Request permission - this should show the system dialog
      // On iOS, we need to ensure we're on the main thread and the app is active
      debugPrint('[PermissionService] Calling Permission.camera.request()...');
      
      // Add a small delay to ensure UI is ready (especially important on iOS)
      await Future.delayed(const Duration(milliseconds: 100));
      
      final result = await Permission.camera.request();
      debugPrint('[PermissionService] Permission.camera.request() completed');
      debugPrint('[PermissionService] Camera permission request result: $result');
      debugPrint('[PermissionService] Camera permission - granted: ${result.isGranted}, denied: ${result.isDenied}, permanentlyDenied: ${result.isPermanentlyDenied}, restricted: ${result.isRestricted}, limited: ${result.isLimited}');
      
      // Wait a bit and check status again - sometimes the status updates after a delay
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Double-check status after request
      final finalStatus = await Permission.camera.status;
      debugPrint('[PermissionService] Camera permission final status check: $finalStatus');
      debugPrint('[PermissionService] Camera permission final status - granted: ${finalStatus.isGranted}, denied: ${finalStatus.isDenied}, permanentlyDenied: ${finalStatus.isPermanentlyDenied}');
      
      // If the request returned permanentlyDenied but status check shows denied,
      // trust the final status check - it's more accurate
      if (result.isPermanentlyDenied && finalStatus.isDenied && !finalStatus.isPermanentlyDenied) {
        debugPrint('[PermissionService] Status mismatch detected - request said permanentlyDenied but status is denied. Trusting final status.');
        // The permission is actually just denied, not permanently denied
        // Return false but the caller should know it's not permanently denied
        return false;
      }
      
      // If granted, return true
      if (result.isGranted || finalStatus.isGranted) {
        return true;
      }
      
      // If actually permanently denied, return false
      if (result.isPermanentlyDenied && finalStatus.isPermanentlyDenied) {
        return false;
      }
      
      // Otherwise, it's just denied (not permanently) - return false but caller can try again
      return false;
    } catch (e, stackTrace) {
      debugPrint('[PermissionService] ERROR requesting camera permission: $e');
      debugPrint('[PermissionService] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Request microphone permission
  /// Returns true if granted, false otherwise
  Future<bool> requestMicrophonePermission() async {
    try {
      debugPrint('[PermissionService] === Starting microphone permission request ===');
      
      if (Platform.isIOS) {
        debugPrint('[PermissionService] iOS platform detected');
        
        // First check current status
        var status = await Permission.microphone.status;
        debugPrint('[PermissionService] Microphone permission initial status: $status');
        debugPrint('[PermissionService] Microphone permission - granted: ${status.isGranted}, denied: ${status.isDenied}, permanentlyDenied: ${status.isPermanentlyDenied}, restricted: ${status.isRestricted}, limited: ${status.isLimited}');
        
        if (status.isGranted) {
          debugPrint('[PermissionService] Microphone permission already granted');
          return true;
        }
        
        if (status.isPermanentlyDenied) {
          debugPrint('[PermissionService] Microphone permission permanently denied');
          return false;
        }
        
        if (status.isRestricted) {
          debugPrint('[PermissionService] Microphone permission restricted by system');
          return false;
        }
        
        // Request permission - this should show the system dialog
        // On iOS, we need to ensure we're on the main thread and the app is active
        debugPrint('[PermissionService] Calling Permission.microphone.request()...');
        
        // Add a small delay to ensure UI is ready (especially important on iOS)
        await Future.delayed(const Duration(milliseconds: 100));
        
        final result = await Permission.microphone.request();
        debugPrint('[PermissionService] Permission.microphone.request() completed');
        debugPrint('[PermissionService] Microphone permission request result: $result');
        debugPrint('[PermissionService] Microphone permission - granted: ${result.isGranted}, denied: ${result.isDenied}, permanentlyDenied: ${result.isPermanentlyDenied}, restricted: ${result.isRestricted}, limited: ${result.isLimited}');
        
        // Wait a bit and check status again - sometimes the status updates after a delay
        await Future.delayed(const Duration(milliseconds: 500));
        
        // Double-check status after request
        final finalStatus = await Permission.microphone.status;
        debugPrint('[PermissionService] Microphone permission final status check: $finalStatus');
        debugPrint('[PermissionService] Microphone permission final status - granted: ${finalStatus.isGranted}, denied: ${finalStatus.isDenied}, permanentlyDenied: ${finalStatus.isPermanentlyDenied}');
        
        // If the request returned permanentlyDenied but status check shows denied,
        // trust the final status check - it's more accurate
        if (result.isPermanentlyDenied && finalStatus.isDenied && !finalStatus.isPermanentlyDenied) {
          debugPrint('[PermissionService] Status mismatch detected - request said permanentlyDenied but status is denied. Trusting final status.');
          // The permission is actually just denied, not permanently denied
          // Return false but the caller should know it's not permanently denied
          return false;
        }
        
        // If granted, return true
        if (result.isGranted || finalStatus.isGranted) {
          return true;
        }
        
        // If actually permanently denied, return false
        if (result.isPermanentlyDenied && finalStatus.isPermanentlyDenied) {
          return false;
        }
        
        // Otherwise, it's just denied (not permanently) - return false but caller can try again
        return false;
      } else {
        debugPrint('[PermissionService] Android platform detected');
        
        // First check current status
        var status = await Permission.microphone.status;
        debugPrint('[PermissionService] Microphone permission initial status: $status');
        debugPrint('[PermissionService] Microphone permission - granted: ${status.isGranted}, denied: ${status.isDenied}, permanentlyDenied: ${status.isPermanentlyDenied}, restricted: ${status.isRestricted}, limited: ${status.isLimited}');
        
        if (status.isGranted) {
          debugPrint('[PermissionService] Microphone permission already granted');
          return true;
        }
        
        if (status.isPermanentlyDenied) {
          debugPrint('[PermissionService] Microphone permission permanently denied');
          return false;
        }
        
        if (status.isRestricted) {
          debugPrint('[PermissionService] Microphone permission restricted by system');
          return false;
        }
        
        // Request permission
        debugPrint('[PermissionService] Calling Permission.microphone.request() (Android)...');
        
        // Add a small delay to ensure UI is ready
        await Future.delayed(const Duration(milliseconds: 100));
        
        final result = await Permission.microphone.request();
        debugPrint('[PermissionService] Permission.microphone.request() completed (Android)');
        debugPrint('[PermissionService] Microphone permission request result (Android): $result');
        debugPrint('[PermissionService] Microphone permission - granted: ${result.isGranted}, denied: ${result.isDenied}, permanentlyDenied: ${result.isPermanentlyDenied}, restricted: ${result.isRestricted}, limited: ${result.isLimited}');
        
        // Wait a bit and check status again - sometimes the status updates after a delay
        await Future.delayed(const Duration(milliseconds: 500));
        
        // Double-check status after request
        final finalStatus = await Permission.microphone.status;
        debugPrint('[PermissionService] Microphone permission final status check (Android): $finalStatus');
        debugPrint('[PermissionService] Microphone permission final status - granted: ${finalStatus.isGranted}, denied: ${finalStatus.isDenied}, permanentlyDenied: ${finalStatus.isPermanentlyDenied}');
        
        // If the request returned permanentlyDenied but status check shows denied,
        // trust the final status check - it's more accurate
        if (result.isPermanentlyDenied && finalStatus.isDenied && !finalStatus.isPermanentlyDenied) {
          debugPrint('[PermissionService] Status mismatch detected - request said permanentlyDenied but status is denied. Trusting final status.');
          // The permission is actually just denied, not permanently denied
          // Return false but the caller should know it's not permanently denied
          return false;
        }
        
        // If granted, return true
        if (result.isGranted || finalStatus.isGranted) {
          return true;
        }
        
        // If actually permanently denied, return false
        if (result.isPermanentlyDenied && finalStatus.isPermanentlyDenied) {
          return false;
        }
        
        // Otherwise, it's just denied (not permanently) - return false but caller can try again
        return false;
      }
    } catch (e, stackTrace) {
      debugPrint('[PermissionService] ERROR requesting microphone permission: $e');
      debugPrint('[PermissionService] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Request photo library permission
  /// Returns true if granted or limited, false otherwise
  Future<bool> requestPhotoLibraryPermission() async {
    try {
      debugPrint('[PermissionService] === Starting photo library permission request ===');
      
      if (Platform.isIOS) {
        debugPrint('[PermissionService] iOS platform detected');
        
        // On iOS, use photo_manager for better compatibility
        debugPrint('[PermissionService] Requesting permission via PhotoManager...');
        final pmStatus = await PhotoManager.requestPermissionExtend();
        debugPrint('[PermissionService] PhotoManager permission result: $pmStatus');
        
        if (pmStatus == PermissionState.authorized || pmStatus == PermissionState.limited) {
          debugPrint('[PermissionService] PhotoManager permission granted (authorized or limited)');
          return true;
        }
        
        // Fallback to permission_handler if photo_manager fails
        debugPrint('[PermissionService] PhotoManager permission not granted, trying permission_handler...');
        final permissionStatus = await Permission.photos.status;
        debugPrint('[PermissionService] Permission.photos.status: $permissionStatus');
        debugPrint('[PermissionService] Permission.photos - granted: ${permissionStatus.isGranted}, limited: ${permissionStatus.isLimited}, denied: ${permissionStatus.isDenied}, permanentlyDenied: ${permissionStatus.isPermanentlyDenied}');
        
        if (permissionStatus.isGranted || permissionStatus.isLimited) {
          debugPrint('[PermissionService] Permission.photos already granted or limited');
          return true;
        }
        
        if (permissionStatus.isPermanentlyDenied) {
          debugPrint('[PermissionService] Permission.photos permanently denied');
          return false;
        }
        
        debugPrint('[PermissionService] Calling Permission.photos.request()...');
        final result = await Permission.photos.request();
        debugPrint('[PermissionService] Permission.photos.request() completed');
        debugPrint('[PermissionService] Permission.photos request result: $result');
        debugPrint('[PermissionService] Permission.photos - granted: ${result.isGranted}, limited: ${result.isLimited}, denied: ${result.isDenied}, permanentlyDenied: ${result.isPermanentlyDenied}');
        
        return result.isGranted || result.isLimited;
      } else {
        debugPrint('[PermissionService] Android platform detected');
        
        // On Android, check Android version
        final androidInfo = await Permission.photos.status;
        debugPrint('[PermissionService] Permission.photos.status (Android): $androidInfo');
        debugPrint('[PermissionService] Permission.photos - granted: ${androidInfo.isGranted}, limited: ${androidInfo.isLimited}, denied: ${androidInfo.isDenied}, permanentlyDenied: ${androidInfo.isPermanentlyDenied}');
        
        if (androidInfo.isGranted || androidInfo.isLimited) {
          debugPrint('[PermissionService] Permission.photos already granted or limited');
          return true;
        }
        
        if (androidInfo.isPermanentlyDenied) {
          debugPrint('[PermissionService] Permission.photos permanently denied');
          return false;
        }
        
        debugPrint('[PermissionService] Calling Permission.photos.request() (Android)...');
        final result = await Permission.photos.request();
        debugPrint('[PermissionService] Permission.photos.request() completed (Android)');
        debugPrint('[PermissionService] Permission.photos request result (Android): $result');
        debugPrint('[PermissionService] Permission.photos - granted: ${result.isGranted}, limited: ${result.isLimited}, denied: ${result.isDenied}, permanentlyDenied: ${result.isPermanentlyDenied}');
        
        return result.isGranted || result.isLimited;
      }
    } catch (e, stackTrace) {
      debugPrint('[PermissionService] ERROR requesting photo library permission: $e');
      debugPrint('[PermissionService] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Request photo library add permission (for saving photos)
  /// Returns true if granted, false otherwise
  Future<bool> requestPhotoLibraryAddPermission() async {
    try {
      if (Platform.isIOS) {
        // On iOS, use permission_handler for NSPhotoLibraryAddUsageDescription
        final status = await Permission.photosAddOnly.status;
        
        if (status.isGranted) {
          return true;
        }
        
        if (status.isPermanentlyDenied) {
          return false;
        }
        
        final result = await Permission.photosAddOnly.request();
        return result.isGranted;
      } else {
        // On Android, use storage permission
        final status = await Permission.storage.status;
        
        if (status.isGranted) {
          return true;
        }
        
        if (status.isPermanentlyDenied) {
          return false;
        }
        
        final result = await Permission.storage.request();
        return result.isGranted;
      }
    } catch (e) {
      debugPrint('[PermissionService] Error requesting photo library add permission: $e');
      return false;
    }
  }

  /// Check if camera permission is granted
  Future<bool> isCameraGranted() async {
    try {
      final status = await Permission.camera.status;
      return status.isGranted;
    } catch (e) {
      debugPrint('[PermissionService] Error checking camera permission: $e');
      return false;
    }
  }

  /// Check if microphone permission is granted
  Future<bool> isMicrophoneGranted() async {
    try {
      if (Platform.isIOS) {
        final status = await Permission.microphone.status;
        return status.isGranted;
      } else {
        final status = await Permission.microphone.status;
        return status.isGranted;
      }
    } catch (e) {
      debugPrint('[PermissionService] Error checking microphone permission: $e');
      return false;
    }
  }

  /// Check if photo library permission is granted or limited
  Future<bool> isPhotoLibraryGranted() async {
    try {
      if (Platform.isIOS) {
        // Check photo_manager first
        final pmStatus = await PhotoManager.requestPermissionExtend();
        if (pmStatus == PermissionState.authorized || pmStatus == PermissionState.limited) {
          return true;
        }

        // Fallback to permission_handler
        final status = await Permission.photos.status;
        return status.isGranted || status.isLimited;
      } else {
        final status = await Permission.photos.status;
        return status.isGranted || status.isLimited;
      }
    } catch (e) {
      debugPrint('[PermissionService] Error checking photo library permission: $e');
      return false;
    }
  }

  /// Check if photo library add permission is granted
  Future<bool> isPhotoLibraryAddGranted() async {
    try {
      if (Platform.isIOS) {
        final status = await Permission.photosAddOnly.status;
        return status.isGranted;
      } else {
        final status = await Permission.storage.status;
        return status.isGranted;
      }
    } catch (e) {
      debugPrint('[PermissionService] Error checking photo library add permission: $e');
      return false;
    }
  }

  /// Check if permission is permanently denied
  Future<bool> isPermanentlyDenied(Permission permission) async {
    try {
      final status = await permission.status;
      return status.isPermanentlyDenied;
    } catch (e) {
      debugPrint('[PermissionService] Error checking permanently denied status: $e');
      return false;
    }
  }

  /// Open app settings
  Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (e) {
      debugPrint('[PermissionService] Error opening settings: $e');
      return false;
    }
  }
}

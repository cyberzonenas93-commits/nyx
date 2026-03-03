import 'package:flutter/material.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'theme.dart';
import '../core/services/permission_service.dart';
import '../core/services/auth_service.dart';
import '../core/services/panic_switch_service.dart';
import '../core/services/wifi_transfer_service.dart';
import '../features/onboarding/pages/onboarding_page.dart';
import '../features/unlock/pages/unlock_page.dart';
import '../features/unlock/pages/unlock_method_selection_page.dart';
import '../features/vault/pages/vault_home_page.dart';
import '../core/models/app_state.dart';

class MediaPrivacyVaultApp extends StatefulWidget {
  const MediaPrivacyVaultApp({super.key});

  @override
  State<MediaPrivacyVaultApp> createState() => _MediaPrivacyVaultAppState();
}

class _MediaPrivacyVaultAppState extends State<MediaPrivacyVaultApp> with WidgetsBindingObserver {
  bool _panicSwitchInitialized = false;
  AuthService? _authService; // Cache reference for lifecycle callbacks
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Check camera permission on launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestPermissionsOnLaunch();
      _initPanicSwitch();
      // Cache AuthService reference for lifecycle callbacks
      if (mounted) {
        _authService = Provider.of<AuthService>(context, listen: false);
      }
    });
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  
  Future<void> _initPanicSwitch() async {
    if (_panicSwitchInitialized || !mounted) return; // Only initialize once
    
    try {
      // Access provider - context is available in post-frame callback
      if (!mounted) return;
      
      final panicSwitchService = Provider.of<PanicSwitchService>(context, listen: false);
      final isEnabled = await panicSwitchService.isEnabled();
      if (isEnabled) {
        await panicSwitchService.startMonitoring();
      }
      _panicSwitchInitialized = true;
    } catch (e) {
      debugPrint('[App] Error initializing panic switch: $e');
    }
  }
  
  Future<void> _stopPanicSwitch() async {
    if (!mounted) return;
    
    try {
      final panicSwitchService = Provider.of<PanicSwitchService>(context, listen: false);
      await panicSwitchService.stopMonitoring();
      _panicSwitchInitialized = false; // Allow re-initialization when app resumes
    } catch (e) {
      debugPrint('[App] Error stopping panic switch: $e');
    }
  }
  
  /// Check camera permission on app launch (don't request automatically)
  /// Permission will be requested when user actually tries to use camera feature
  Future<void> _requestPermissionsOnLaunch() async {
    try {
      // Wait a bit for the app to fully initialize
      await Future.delayed(const Duration(milliseconds: 2000));
      
      final permissionService = PermissionService();
      
      // Just check and log permission status, don't request automatically
      // iOS/Android guidelines recommend requesting permissions when the feature is used
      final cameraGranted = await permissionService.isCameraGranted();
      final cameraPermanentlyDenied = await permissionService.isPermanentlyDenied(Permission.camera);
      final cameraStatus = await Permission.camera.status;
      debugPrint('[App] Camera permission status on launch: status=$cameraStatus, granted=$cameraGranted, permanentlyDenied=$cameraPermanentlyDenied');
      
      debugPrint('[App] Permission check completed. Permissions will be requested when features are used.');
    } catch (e) {
      debugPrint('[App] Error checking permissions on launch: $e');
    }
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    // Lock vault when app goes to background (minimized or multitasking)
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _lockVaultIfUnlocked();
      _stopPanicSwitch(); // Stop monitoring to save resources when app is in background
      // Note: Background imports will continue automatically via persistent Future
    }
    
    // Re-initialize panic switch when app resumes (in case it was stopped)
    if (state == AppLifecycleState.resumed) {
      _initPanicSwitch();
      // Resume any paused background imports
      _resumeBackgroundImports();
    }
  }
  
  /// Resume background imports when app comes to foreground
  void _resumeBackgroundImports() {
    try {
      // The BackgroundImportService will automatically resume from persisted queue
      // We just need to ensure it's initialized if the vault is unlocked
      if (mounted) {
        final authService = _authService ?? Provider.of<AuthService>(context, listen: false);
        if (authService.appState == AppState.unlocked) {
          // Background import service will auto-resume when vault is accessed
          debugPrint('[App] App resumed - background imports will auto-resume if needed');
        }
      }
    } catch (e) {
      debugPrint('[App] Error resuming background imports: $e');
    }
  }
  
  /// Lock the vault if it's currently unlocked
  void _lockVaultIfUnlocked() {
    try {
      // Don't auto-lock when WiFi Transfer server is running (user may be uploading from computer)
      if (mounted) {
        try {
          final wifiTransfer = Provider.of<WiFiTransferService>(context, listen: false);
          if (wifiTransfer.isRunning) {
            debugPrint('[App] WiFi Transfer server running - not auto-locking vault');
            return;
          }
        } catch (_) {}
      }

      // Use cached reference or get from context if available
      final authService = _authService ?? (mounted ? Provider.of<AuthService>(context, listen: false) : null);
      
      if (authService == null) {
        debugPrint('[App] Cannot lock vault - AuthService not available');
        return;
      }
      
      // Always return to the home experience when backgrounded (security).
      // Also ensure we pop any pushed vault routes (detail viewers etc) so the unlock screen is visible on resume.
      if (authService.appState == AppState.unlocked || authService.appState == AppState.locked) {
        debugPrint('[App] App went to background - locking vault and returning to unlock screen');
        unawaited(
          authService.lockVault().catchError((e) {
            debugPrint('[App] Error locking vault (async): $e');
          }).whenComplete(() {
            // Pop back to the root route so the unlock screen is visible.
            try {
              _navigatorKey.currentState?.popUntil((route) => route.isFirst);
            } catch (e) {
              debugPrint('[App] Error popping routes after lock: $e');
            }
          }),
        );
      }
    } catch (e) {
      debugPrint('[App] Error locking vault on background: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Update cached AuthService reference when context is available
    if (mounted && _authService == null) {
      try {
        _authService = Provider.of<AuthService>(context, listen: false);
      } catch (e) {
        debugPrint('[App] Error caching AuthService: $e');
      }
    }
    
    return MaterialApp(
      title: 'Nyx',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      navigatorKey: _navigatorKey,
      home: Consumer<AuthService>(
        builder: (context, authService, _) {
          // Show loading while checking auth state
          if (authService.isInitializing) {
            return const Scaffold(
              backgroundColor: AppTheme.primary,
              body: Center(
                child: CircularProgressIndicator(
                  color: AppTheme.accent,
                ),
              ),
            );
          }
          
          // Route based on auth state (no calculator decoy - compliant with App Store guideline 2.5.1)
          switch (authService.appState) {
            case AppState.onboarding:
              return const OnboardingPage();
            case AppState.pinSetup:
              return const UnlockMethodSelectionPage();
            case AppState.disguised:
            case AppState.locked:
              return const UnlockPage();
            case AppState.unlocked:
              return VaultHomePage(
                vaultId: authService.currentVaultId,
                onLockRequested: () async {
                  await authService.lockVault();
                  _navigatorKey.currentState?.popUntil((route) => route.isFirst);
                },
              );
          }
        },
      ),
    );
  }
}

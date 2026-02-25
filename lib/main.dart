import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'app/app.dart';
import 'core/services/auth_service.dart';
import 'core/services/encryption_service.dart';
import 'core/services/subscription_service.dart';
import 'core/services/panic_switch_service.dart';
import 'core/services/advanced_cryptography_service.dart';
import 'core/services/tamper_detection_service.dart';
import 'core/services/vault_service.dart';
import 'core/services/download_manager_service.dart';
import 'core/services/media_extraction_engine.dart';
import 'core/services/browser_session_service.dart';
import 'core/services/media_playback_manager.dart';
import 'core/services/video_poster_background_service.dart';
import 'core/services/wifi_transfer_service.dart';
import 'core/services/tutorial_service.dart';
import 'core/services/multi_vault_service.dart';
import 'package:flutter/foundation.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Allow all orientations - individual pages can restrict as needed
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  
  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  
  // Initialize services
  final encryptionService = EncryptionService();
  final advancedCryptoService = AdvancedCryptographyService();
  final authService = AuthService(encryptionService);
  final vaultService = VaultService(encryptionService);
  final extractionEngine = MediaExtractionEngine(null);
  final downloadManager = DownloadManagerService(
    vaultService,
    extractionEngine: extractionEngine,
  );
  // Set download manager reference in extraction engine (circular dependency resolution)
  extractionEngine.setDownloadManager(downloadManager);
  
  // Verify extraction engine is ready
  if (!extractionEngine.isReady) {
    debugPrint('[Main] ⚠️ WARNING: MediaExtractionEngine is not ready after initialization!');
  } else {
    debugPrint('[Main] ✅ MediaExtractionEngine initialized and ready');
  }
  final subscriptionService = SubscriptionService();
  final panicSwitchService = PanicSwitchService();
  final tamperDetectionService = TamperDetectionService(authService);
  final browserSessionService = BrowserSessionService();
  final mediaPlaybackManager = MediaPlaybackManager();
  final videoPosterBackgroundService = VideoPosterBackgroundService(vaultService, mediaPlaybackManager);
  final wifiTransferService = WiFiTransferService(vaultService, authService);
  final tutorialService = TutorialService();
  final multiVaultService = MultiVaultService();
  
  await tamperDetectionService.loadFailedAttempts();
  await downloadManager.initialize();
  
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authService),
        ChangeNotifierProvider.value(value: vaultService),
        ChangeNotifierProvider.value(value: downloadManager),
        ChangeNotifierProvider.value(value: subscriptionService),
        ChangeNotifierProvider.value(value: browserSessionService),
        ChangeNotifierProvider.value(value: mediaPlaybackManager),
        ChangeNotifierProvider.value(value: videoPosterBackgroundService),
        ChangeNotifierProvider.value(value: wifiTransferService),
        ChangeNotifierProvider.value(value: tutorialService),
        ChangeNotifierProvider.value(value: multiVaultService),
        Provider.value(value: panicSwitchService),
        Provider.value(value: advancedCryptoService),
        Provider.value(value: tamperDetectionService),
      ],
      child: const MediaPrivacyVaultApp(),
    ),
  );
}

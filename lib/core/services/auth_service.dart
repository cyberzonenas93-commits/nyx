import 'package:flutter/foundation.dart';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import 'encryption_service.dart';

/// Authentication service with PIN support
class AuthService extends ChangeNotifier {
  final EncryptionService _encryptionService;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  
  AppState _appState = AppState.locked;
  bool _isInitializing = true;
  Uint8List? _masterKey;
  String? _currentVaultId; // ID of currently unlocked vault (null = primary)
  
  AppState get appState => _appState;
  bool get isInitializing => _isInitializing;
  bool get isLocked => _appState == AppState.locked;
  bool get isUnlocked => _appState == AppState.unlocked;
  bool get isDisguised => _appState == AppState.disguised;
  
  AuthService(this._encryptionService) {
    _initialize();
  }
  
  Future<void> _initialize() async {
    // iOS Keychain persists after app deletion, but SharedPreferences don't
    // Use SharedPreferences to detect fresh install and clear Keychain if needed
    final prefs = await SharedPreferences.getInstance();
    final hasLaunchedBefore = prefs.getBool('has_launched_before') ?? false;
    
    if (!hasLaunchedBefore) {
      // Fresh install detected - clear all secure storage keys
      // This ensures onboarding/PIN setup runs even if Keychain has old data
      try {
        await _secureStorage.delete(key: 'onboarding_complete');
        await _secureStorage.delete(key: 'vault_initialized');
        await _secureStorage.delete(key: 'pin_salt');
        await _secureStorage.delete(key: 'pin_hash');
        await _secureStorage.delete(key: 'unlock_trigger_code');
        await _secureStorage.delete(key: 'unlock_method');
        await _secureStorage.delete(key: 'was_unlocked');
        debugPrint('Fresh install detected - cleared secure storage');
      } catch (e) {
        debugPrint('Error clearing secure storage on fresh install: $e');
      }
      
      // Mark that app has launched
      await prefs.setBool('has_launched_before', true);
    }
    
    // Check if onboarding is complete
    final onboardingComplete = await _secureStorage.read(key: 'onboarding_complete');
    
    if (onboardingComplete != 'true') {
      // First launch - show onboarding
      _appState = AppState.onboarding;
    } else {
      // Check if PIN is actually set up (not just vault_initialized flag)
      final pinSalt = await _secureStorage.read(key: 'pin_salt');
      final pinHash = await _secureStorage.read(key: 'pin_hash');
      final hasPIN = pinSalt != null && pinHash != null;
      
      if (!hasPIN) {
        // Onboarding complete but PIN not set up - redirect to PIN setup
        // This handles the case where user was interrupted during PIN setup
        debugPrint('[AuthService] PIN not set up - redirecting to PIN setup');
        _appState = AppState.pinSetup;
      } else {
        // PIN exists - show unlock screen (no decoy; compliant with App Store guideline 2.5.1)
        _appState = AppState.locked;
      }
    }
    
    _isInitializing = false;
    notifyListeners();
  }
  
  /// Complete onboarding and proceed to PIN setup (if not already set up)
  Future<void> completeOnboarding() async {
    await _secureStorage.write(key: 'onboarding_complete', value: 'true');
    
    // Check if PIN is actually set up
    final pinSalt = await _secureStorage.read(key: 'pin_salt');
    final pinHash = await _secureStorage.read(key: 'pin_hash');
    final hasPIN = pinSalt != null && pinHash != null;
    
    if (!hasPIN) {
      // PIN not set up - go to PIN setup
      _appState = AppState.pinSetup;
    } else {
      _appState = AppState.locked;
    }
    
    notifyListeners();
  }
  
  /// Verify PIN and unlock vault
  Future<AuthResult> verifyPIN(String pin) async {
    final saltHex = await _secureStorage.read(key: 'pin_salt');
    final hashedPIN = await _secureStorage.read(key: 'pin_hash');
    
    if (saltHex == null || hashedPIN == null) {
      // Vault not set up - treat as setup
      return AuthResult.notInitialized;
    }
    
    // Check PIN
    final salt = _hexToBytes(saltHex);
    final masterKey = await _encryptionService.deriveMasterKey(pin, salt);
    
    if (await _encryptionService.verifyPassword(pin, hashedPIN)) {
      // Real vault (primary)
      _masterKey = masterKey;
      _currentVaultId = null; // null = primary vault
      await _unlockVault();
      return AuthResult.unlocked;
    }
    
    return AuthResult.failed;
  }
  
  /// Verify PIN for a secondary vault
  /// Uses the same logic as verifyPIN - reads from secure storage directly
  Future<bool> verifySecondaryVaultPIN(String vaultId, String pin) async {
    final hashKey = 'pin_hash_$vaultId';
    final saltKey = 'pin_salt_$vaultId';
    final saltHex = await _secureStorage.read(key: saltKey);
    final hashedPIN = await _secureStorage.read(key: hashKey);
    
    if (saltHex == null || hashedPIN == null) {
      debugPrint('[AuthService] Secondary vault PIN not found for vaultId: $vaultId (keys: $hashKey, $saltKey; saltHex null: ${saltHex == null}, hashedPIN null: ${hashedPIN == null})');
      return false;
    }
    
    // Check PIN (same logic as primary vault: verifyPassword uses salt embedded in hashedPIN)
    final salt = _hexToBytes(saltHex);
    final masterKey = await _encryptionService.deriveMasterKey(pin, salt);
    
    final verified = await _encryptionService.verifyPassword(pin, hashedPIN);
    if (verified) {
      _masterKey = masterKey;
      _currentVaultId = vaultId;
      await _unlockVault();
      debugPrint('[AuthService] Secondary vault unlocked: $vaultId');
      return true;
    }
    debugPrint('[AuthService] Secondary vault PIN verification failed for vaultId: $vaultId');
    return false;
  }
  
  String? get currentVaultId => _currentVaultId;
  
  /// Set up PIN (initial setup or PIN change)
  Future<bool> setupPIN(String pin, {String? unlockTriggerCode}) async {
    try {
      // Validate PIN doesn't start with 0
      if (pin.startsWith('0')) {
        debugPrint('[AuthService] PIN cannot start with 0');
        return false; // PIN cannot start with 0
      }
      
      debugPrint('[AuthService] Setting up PIN...');
      
      // Real vault setup
      final salt = _encryptionService.generateSalt();
      final hashedPIN = await _encryptionService.hashPassword(pin, salt);
      
      debugPrint('[AuthService] Writing pin_salt to secure storage...');
      await _secureStorage.write(key: 'pin_salt', value: _bytesToHex(salt));
      
      debugPrint('[AuthService] Writing pin_hash to secure storage...');
      await _secureStorage.write(key: 'pin_hash', value: hashedPIN);
      
      debugPrint('[AuthService] Writing vault_initialized to secure storage...');
      await _secureStorage.write(key: 'vault_initialized', value: 'true');
      
      debugPrint('[AuthService] Writing unlock_method to secure storage...');
      await _secureStorage.write(key: 'unlock_method', value: 'pin'); // Store unlock method
      
      // Store legacy unlock trigger code (no longer used in UI)
      final triggerCode = unlockTriggerCode ?? pin;
      debugPrint('[AuthService] Writing unlock_trigger_code to secure storage...');
      await _secureStorage.write(key: 'unlock_trigger_code', value: triggerCode);
      
      debugPrint('[AuthService] PIN setup completed successfully');
      
      // After PIN setup, show unlock screen (no decoy; compliant with App Store guideline 2.5.1)
      _appState = AppState.locked;
      _masterKey = null; // User must enter PIN on unlock screen to open vault
      notifyListeners();
      return true;
    } catch (e, stackTrace) {
      debugPrint('[AuthService] Error setting up PIN: $e');
      debugPrint('[AuthService] Stack trace: $stackTrace');
      return false;
    }
  }
  
  /// Get the current unlock method (always 'pin' now)
  Future<String?> getUnlockMethod() async {
    return 'pin'; // Pattern unlock removed - always PIN
  }
  
  /// Unlock vault (internal)
  Future<void> _unlockVault() async {
    _currentVaultId = null; // null = primary vault
    _appState = AppState.unlocked;
    await _secureStorage.write(key: 'was_unlocked', value: 'true');
    notifyListeners();
  }
  
  /// Lock vault and return to unlock screen
  Future<void> lockVault() async {
    _masterKey = null;
    _currentVaultId = null;
    _appState = AppState.locked;
    await _secureStorage.write(key: 'was_unlocked', value: 'false');
    notifyListeners();
  }
  
  /// Switch to home state
  void switchToDisguised() {
    _masterKey = null;
    _appState = AppState.locked;
    notifyListeners();
  }
  
  /// Request unlock (show unlock screen or PIN setup if first time)
  Future<void> requestUnlock() async {
    // Check if PIN is actually set up
    final pinSalt = await _secureStorage.read(key: 'pin_salt');
    final pinHash = await _secureStorage.read(key: 'pin_hash');
    final hasPIN = pinSalt != null && pinHash != null;
    
    if (!hasPIN) {
      // PIN not set up - show PIN setup
      _appState = AppState.pinSetup;
    } else {
      // PIN exists - show unlock screen
      _appState = AppState.locked;
    }
    notifyListeners();
  }
  
  /// Get current master key (for encryption operations)
  Uint8List? get masterKey => _masterKey;
  
  /// Legacy: unlock trigger code (no longer used in UI)
  Future<String?> getUnlockTriggerCode() async {
    return await _secureStorage.read(key: 'unlock_trigger_code');
  }
  
  /// Legacy: set unlock trigger code (no longer used in UI)
  Future<bool> setUnlockTriggerCode(String code) async {
    try {
      // Verify code is numeric and doesn't start with 0
      if (code.isEmpty || !RegExp(r'^\d+$').hasMatch(code)) {
        return false;
      }
      if (code.startsWith('0')) {
        return false; // Cannot start with 0
      }
      await _secureStorage.write(key: 'unlock_trigger_code', value: code);
      return true;
    } catch (e) {
      debugPrint('[AuthService] Error setting unlock trigger code: $e');
      return false;
    }
  }
  
  
  String _bytesToHex(Uint8List bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
  
  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }
  
  /// Reset app to first-launch state (for testing/debugging only)
  /// WARNING: This will delete all app data including PIN, vault, etc.
  Future<void> resetAppForTesting() async {
    try {
      // Clear all secure storage keys related to app initialization
      await _secureStorage.delete(key: 'onboarding_complete');
      await _secureStorage.delete(key: 'vault_initialized');
      await _secureStorage.delete(key: 'pin_salt');
      await _secureStorage.delete(key: 'pin_hash');
      await _secureStorage.delete(key: 'unlock_trigger_code');
        await _secureStorage.delete(key: 'unlock_method');
        await _secureStorage.delete(key: 'was_unlocked');
      
      // Reset state
      _masterKey = null;
      _appState = AppState.onboarding; // Start from onboarding
      _isInitializing = false;
      
      notifyListeners();
      debugPrint('App reset to first-launch state');
    } catch (e) {
      debugPrint('Error resetting app: $e');
    }
  }
}

/// Authentication result enum
enum AuthResult {
  unlocked,
  failed,
  notInitialized,
}

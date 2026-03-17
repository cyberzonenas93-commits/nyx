import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../models/vault_metadata.dart';

/// Service for managing multiple vaults
/// Primary vault stores metadata for all secondary vaults
class MultiVaultService extends ChangeNotifier {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final Uuid _uuid = const Uuid();

  List<VaultMetadata> _vaults = [];
  bool _isInitialized = false;

  List<VaultMetadata> get vaults => List.unmodifiable(_vaults);
  VaultMetadata? get primaryVault {
    if (_vaults.isEmpty) return null;
    try {
      return _vaults.firstWhere((v) => v.isPrimary);
    } catch (e) {
      // No primary vault found, return null
      return null;
    }
  }

  bool get isInitialized => _isInitialized;
  int get vaultCount => _vaults.length;
  int get maxVaults => 10; // Limit for unlimited tier

  MultiVaultService() {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final vaultsJson = await _secureStorage.read(key: 'vaults_metadata');
      if (vaultsJson != null && vaultsJson.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(vaultsJson) as List<dynamic>;
        _vaults = jsonList
            .map((json) => VaultMetadata.fromJson(json as Map<String, dynamic>))
            .toList();
        debugPrint(
            '[MultiVaultService] Loaded ${_vaults.length} vaults from storage');
        for (var vault in _vaults) {
          debugPrint(
              '[MultiVaultService] Loaded vault: ${vault.name} (ID: ${vault.id.substring(0, 8)}..., isPrimary: ${vault.isPrimary})');
        }
      } else {
        _vaults = [];
        debugPrint('[MultiVaultService] No vaults found in storage');
      }

      // Migration: ensure primary vault exists if user has PIN or pattern (e.g. existing user before multi-vault)
      final pinSalt = await _secureStorage.read(key: 'pin_salt');
      final patternSalt = await _secureStorage.read(key: 'pattern_salt');
      final hasPrimaryCredentials = (pinSalt != null) || (patternSalt != null);
      final hasPrimary = _vaults.any((v) => v.isPrimary);
      if (hasPrimaryCredentials && !hasPrimary) {
        final triggerCode =
            await _secureStorage.read(key: 'unlock_trigger_code') ?? 'primary';
        final primaryVault = VaultMetadata(
          id: _uuid.v4(),
          name: 'Primary Vault',
          triggerCode: triggerCode,
          createdAt: DateTime.now(),
          isPrimary: true,
        );
        _vaults.insert(0, primaryVault);
        await _saveVaults();
        debugPrint('[MultiVaultService] Migration: created primary vault');
      }

      _isInitialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[MultiVaultService] Error initializing: $e');
      _isInitialized = true;
      notifyListeners();
    }
  }

  /// Initialize primary vault (called during first PIN setup)
  Future<void> initializePrimaryVault(String triggerCode) async {
    if (_vaults.isNotEmpty) {
      throw StateError('Primary vault already exists');
    }

    final primaryVault = VaultMetadata(
      id: _uuid.v4(),
      name: 'Primary Vault',
      triggerCode: triggerCode,
      createdAt: DateTime.now(),
      isPrimary: true,
    );

    debugPrint(
        '[MultiVaultService] Initializing primary vault: ${primaryVault.name} (ID: ${primaryVault.id.substring(0, 8)}...)');
    _vaults.add(primaryVault);
    await _saveVaults();
    debugPrint(
        '[MultiVaultService] Primary vault saved. Total vaults: ${_vaults.length}');
    notifyListeners();
  }

  /// Create a new secondary vault with PIN or pattern
  Future<VaultMetadata> createSecondaryVault({
    required String name,
    required String triggerCode,
    String? pinHash,
    String? pinSalt,
    String? patternHash,
    String? patternSalt,
    FlutterSecureStorage? secureStorage,
  }) async {
    if (_vaults.length >= maxVaults) {
      throw StateError('Maximum number of vaults reached ($maxVaults)');
    }
    final usePattern = patternHash != null && patternSalt != null;
    final usePIN = pinHash != null && pinSalt != null;
    if (!usePattern && !usePIN) {
      throw StateError('Provide either PIN or pattern credentials');
    }
    if (usePattern && usePIN) {
      throw StateError('Provide either PIN or pattern, not both');
    }

    // Check if trigger code is already in use
    if (_vaults.any((v) => v.triggerCode == triggerCode)) {
      throw StateError('Trigger code already in use');
    }

    final vaultId = _uuid.v4();
    final storage = secureStorage ?? _secureStorage;

    if (usePattern) {
      final resolvedPatternHash = patternHash;
      final resolvedPatternSalt = patternSalt;
      if (resolvedPatternHash == null || resolvedPatternSalt == null) {
        throw StateError('Pattern credentials are required');
      }
      await storage.write(
          key: 'pattern_hash_$vaultId', value: resolvedPatternHash);
      await storage.write(
          key: 'pattern_salt_$vaultId', value: resolvedPatternSalt);
      debugPrint(
          '[MultiVaultService] Stored secondary vault pattern for vaultId: $vaultId');
    } else {
      final resolvedPinHash = pinHash;
      final resolvedPinSalt = pinSalt;
      if (resolvedPinHash == null || resolvedPinSalt == null) {
        throw StateError('PIN credentials are required');
      }
      await storage.write(key: 'pin_hash_$vaultId', value: resolvedPinHash);
      await storage.write(key: 'pin_salt_$vaultId', value: resolvedPinSalt);
      debugPrint(
          '[MultiVaultService] Stored secondary vault PIN for vaultId: $vaultId');
    }

    final vault = VaultMetadata(
      id: vaultId,
      name: name,
      triggerCode: triggerCode,
      createdAt: DateTime.now(),
      isPrimary: false,
    );

    debugPrint(
        '[MultiVaultService] Creating secondary vault: ${vault.name} (ID: ${vault.id})');
    debugPrint(
        '[MultiVaultService] Total vaults before add: ${_vaults.length}');

    _vaults.add(vault);
    await _saveVaults();
    notifyListeners();

    debugPrint('[MultiVaultService] Total vaults after add: ${_vaults.length}');

    return vault;
  }

  /// Update PIN for an existing secondary vault (e.g. after reset).
  Future<void> updateSecondaryVaultPIN(
      String vaultId, String pinHash, String pinSalt) async {
    final vault = getVaultById(vaultId);
    if (vault == null || vault.isPrimary) {
      throw StateError('Vault not found or cannot update primary vault PIN');
    }
    await _secureStorage.delete(key: 'pattern_hash_$vaultId');
    await _secureStorage.delete(key: 'pattern_salt_$vaultId');
    await _secureStorage.write(key: 'pin_hash_$vaultId', value: pinHash);
    await _secureStorage.write(key: 'pin_salt_$vaultId', value: pinSalt);
    debugPrint(
        '[MultiVaultService] Updated secondary vault PIN for vaultId: $vaultId');
  }

  /// Update pattern for an existing secondary vault (e.g. after reset).
  Future<void> updateSecondaryVaultPattern(
      String vaultId, String patternHash, String patternSalt) async {
    final vault = getVaultById(vaultId);
    if (vault == null || vault.isPrimary) {
      throw StateError(
          'Vault not found or cannot update primary vault pattern');
    }
    await _secureStorage.delete(key: 'pin_hash_$vaultId');
    await _secureStorage.delete(key: 'pin_salt_$vaultId');
    await _secureStorage.write(
        key: 'pattern_hash_$vaultId', value: patternHash);
    await _secureStorage.write(
        key: 'pattern_salt_$vaultId', value: patternSalt);
    debugPrint(
        '[MultiVaultService] Updated secondary vault pattern for vaultId: $vaultId');
  }

  /// Get vault by trigger code
  VaultMetadata? getVaultByTriggerCode(String triggerCode) {
    try {
      return _vaults.firstWhere((v) => v.triggerCode == triggerCode);
    } catch (e) {
      return null;
    }
  }

  /// Get vault by ID
  VaultMetadata? getVaultById(String id) {
    try {
      return _vaults.firstWhere((v) => v.id == id);
    } catch (e) {
      return null;
    }
  }

  /// True if this vault is unlocked with a pattern (vs PIN).
  Future<bool> vaultUsesPattern(String vaultId) async {
    return await _secureStorage.read(key: 'pattern_salt_$vaultId') != null;
  }

  /// Update vault metadata (for recovery codes, etc.)
  Future<void> updateVault(VaultMetadata vault) async {
    final index = _vaults.indexWhere((v) => v.id == vault.id);
    if (index == -1) {
      throw StateError('Vault not found');
    }

    _vaults[index] = vault;
    await _saveVaults();
    notifyListeners();
  }

  /// Delete a secondary vault (cannot delete primary)
  /// Also removes PIN hash/salt from secure storage
  Future<void> deleteVault(String id,
      {FlutterSecureStorage? secureStorage}) async {
    final vault = getVaultById(id);
    if (vault == null) {
      throw StateError('Vault not found');
    }

    if (vault.isPrimary) {
      throw StateError('Cannot delete primary vault');
    }

    final storage = secureStorage ?? _secureStorage;
    await storage.delete(key: 'pin_hash_$id');
    await storage.delete(key: 'pin_salt_$id');
    await storage.delete(key: 'pattern_hash_$id');
    await storage.delete(key: 'pattern_salt_$id');

    _vaults.removeWhere((v) => v.id == id);
    await _saveVaults();
    notifyListeners();
  }

  /// Save vaults metadata to secure storage
  Future<void> _saveVaults() async {
    final jsonList = _vaults.map((v) => v.toJson()).toList();
    final jsonString = jsonEncode(jsonList);
    await _secureStorage.write(key: 'vaults_metadata', value: jsonString);
  }

  /// Get recovery information for a vault (PIN hash/salt from secure storage)
  /// This should only be accessible from the primary vault
  Future<Map<String, String?>> getRecoveryInfo(String vaultId,
      {FlutterSecureStorage? secureStorage}) async {
    final vault = getVaultById(vaultId);
    if (vault == null) {
      throw StateError('Vault not found');
    }

    // Read PIN hash and salt from secure storage
    final storage = secureStorage ?? _secureStorage;
    final pinHash = await storage.read(key: 'pin_hash_$vaultId');
    final pinSalt = await storage.read(key: 'pin_salt_$vaultId');

    return {
      'triggerCode': vault.triggerCode,
      'pinHash': pinHash,
      'pinSalt': pinSalt,
    };
  }
}

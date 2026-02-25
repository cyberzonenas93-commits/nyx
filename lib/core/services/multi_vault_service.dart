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
      if (vaultsJson != null) {
        final List<dynamic> jsonList = jsonDecode(vaultsJson) as List<dynamic>;
        _vaults = jsonList.map((json) => VaultMetadata.fromJson(json as Map<String, dynamic>)).toList();
        
        debugPrint('[MultiVaultService] Loaded ${_vaults.length} vaults from storage');
        for (var vault in _vaults) {
          debugPrint('[MultiVaultService] Loaded vault: ${vault.name} (ID: ${vault.id.substring(0, 8)}..., isPrimary: ${vault.isPrimary}, trigger: ${vault.triggerCode})');
        }
        
        // Find primary vault
        // Primary vault exists
        _vaults.firstWhere(
          (v) => v.isPrimary,
          orElse: () => _vaults.isNotEmpty ? _vaults.first : throw StateError('No vaults'),
        );
      } else {
        // First time - no vaults yet, will be created during PIN setup
        _vaults = [];
        debugPrint('[MultiVaultService] No vaults found in storage - first time setup');
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
    
    debugPrint('[MultiVaultService] Initializing primary vault: ${primaryVault.name} (ID: ${primaryVault.id.substring(0, 8)}..., trigger: ${primaryVault.triggerCode})');
    _vaults.add(primaryVault);
    await _saveVaults();
    debugPrint('[MultiVaultService] Primary vault saved. Total vaults: ${_vaults.length}');
    notifyListeners();
  }
  
  /// Create a new secondary vault
  /// Stores PIN hash and salt directly in secure storage (same pattern as primary vault)
  Future<VaultMetadata> createSecondaryVault({
    required String name,
    required String triggerCode,
    required String pinHash,
    required String pinSalt,
    required FlutterSecureStorage secureStorage, // For storing PIN hash/salt directly
  }) async {
    if (_vaults.length >= maxVaults) {
      throw StateError('Maximum number of vaults reached ($maxVaults)');
    }
    
    // Check if trigger code is already in use
    if (_vaults.any((v) => v.triggerCode == triggerCode)) {
      throw StateError('Trigger code already in use');
    }
    
    final vaultId = _uuid.v4();
    
    // Store PIN hash and salt directly in secure storage (same as primary vault)
    await secureStorage.write(key: 'pin_hash_$vaultId', value: pinHash);
    await secureStorage.write(key: 'pin_salt_$vaultId', value: pinSalt);
    
    debugPrint('[MultiVaultService] Stored secondary vault PIN info in secure storage for vault: $vaultId');
    
    final vault = VaultMetadata(
      id: vaultId,
      name: name,
      triggerCode: triggerCode,
      createdAt: DateTime.now(),
      isPrimary: false,
    );
    
    debugPrint('[MultiVaultService] Creating secondary vault: ${vault.name} (ID: ${vault.id}, Trigger: ${vault.triggerCode})');
    debugPrint('[MultiVaultService] Total vaults before add: ${_vaults.length}');
    
    _vaults.add(vault);
    await _saveVaults();
    notifyListeners();
    
    debugPrint('[MultiVaultService] Total vaults after add: ${_vaults.length}');
    
    return vault;
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
  Future<void> deleteVault(String id, {FlutterSecureStorage? secureStorage}) async {
    final vault = getVaultById(id);
    if (vault == null) {
      throw StateError('Vault not found');
    }
    
    if (vault.isPrimary) {
      throw StateError('Cannot delete primary vault');
    }
    
    // Remove PIN hash/salt from secure storage
    final storage = secureStorage ?? _secureStorage;
    await storage.delete(key: 'pin_hash_$id');
    await storage.delete(key: 'pin_salt_$id');
    
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
  Future<Map<String, String?>> getRecoveryInfo(String vaultId, {FlutterSecureStorage? secureStorage}) async {
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

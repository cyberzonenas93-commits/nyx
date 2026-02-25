import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'encryption_service.dart';

/// Service for running heavy operations in isolates to prevent UI blocking
class PerformanceService {
  /// Encrypt data in isolate to prevent blocking main thread
  static Future<EncryptedData> encryptInIsolate(Uint8List data, Uint8List key) async {
    final params = _EncryptParams(
      data: data,
      key: key,
    );
    final result = await compute(_encryptInIsolate, params);
    return EncryptedData.fromJson(result);
  }
  
  /// Decrypt data in isolate to prevent blocking main thread
  /// Uses direct component passing for better performance
  static Future<Uint8List> decryptInIsolate(EncryptedData encrypted, Uint8List key) async {
    // Pass components directly to avoid conversion overhead
    // Only use binary format for very large files (>50MB) where memory is critical
    final ciphertextSize = encrypted.ciphertext.length;
    final useBinary = ciphertextSize > 50 * 1024 * 1024; // 50MB threshold (only for very large files)
    
    if (useBinary) {
      // Use binary format only for extremely large files
      final params = _DecryptParamsBinary(
        encryptedBinary: encrypted.toBinary(),
        key: key,
      );
      return await compute(_decryptInIsolateBinary, params);
    } else {
      // For most files, pass components directly - faster than JSON conversion
      final params = _DecryptParamsDirect(
        ciphertext: encrypted.ciphertext,
        nonce: encrypted.nonce,
        tag: encrypted.tag,
        key: key,
      );
      return await compute(_decryptInIsolateDirect, params);
    }
  }
  
  /// Encrypt helper for isolate (must be top-level or static)
  /// Returns serialized EncryptedData as Map
  static Map<String, dynamic> _encryptInIsolate(_EncryptParams params) {
    final service = EncryptionService();
    final encrypted = service.encryptFile(params.data, params.key);
    return encrypted.toJson();
  }
  
  /// Decrypt helper for isolate using direct component passing (fastest)
  static Uint8List _decryptInIsolateDirect(_DecryptParamsDirect params) {
    try {
      final service = EncryptionService();
      // Create EncryptedData directly from components - no parsing overhead
      final encrypted = EncryptedData(
        ciphertext: params.ciphertext,
        nonce: params.nonce,
        tag: params.tag,
      );
      return service.decryptFile(encrypted, params.key);
    } catch (e) {
      // Re-throw with more context
      throw Exception('Decryption failed in isolate: $e');
    }
  }
  
  /// Decrypt helper for isolate using binary format (for very large files only)
  static Uint8List _decryptInIsolateBinary(_DecryptParamsBinary params) {
    try {
      final service = EncryptionService();
      // Parse binary format directly - avoids base64/JSON overhead
      final encrypted = EncryptedData.fromBinary(params.encryptedBinary);
      return service.decryptFile(encrypted, params.key);
    } catch (e) {
      // Re-throw with more context
      throw Exception('Decryption failed in isolate (binary): $e');
    }
  }
}

/// Parameters for encryption isolate (must be serializable)
class _EncryptParams {
  final Uint8List data;
  final Uint8List key;
  
  _EncryptParams({required this.data, required this.key});
  
  // Note: Uint8List is serializable in Flutter isolates
}

/// Parameters for decryption isolate using direct component passing (fastest)
class _DecryptParamsDirect {
  final Uint8List ciphertext;
  final Uint8List nonce;
  final Uint8List tag;
  final Uint8List key;
  
  _DecryptParamsDirect({
    required this.ciphertext,
    required this.nonce,
    required this.tag,
    required this.key,
  });
}

/// Parameters for decryption isolate using binary format (for very large files only)
class _DecryptParamsBinary {
  final Uint8List encryptedBinary; // Binary format EncryptedData
  final Uint8List key;
  
  _DecryptParamsBinary({required this.encryptedBinary, required this.key});
}

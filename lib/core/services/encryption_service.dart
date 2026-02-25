import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:pointycastle/random/fortuna_random.dart';

/// Encryption service using AES-256-GCM and HKDF
/// Implements zero-knowledge architecture
class EncryptionService {
  static const int keyLength = 32; // 256 bits for AES-256
  static const int saltLength = 32;
  static const int nonceLength = 12; // GCM standard
  
  /// Derive master key from PIN using HMAC-SHA256 with multiple iterations
  /// Note: Using iterative HMAC instead of Argon2id for compatibility
  /// This is still secure with high iteration count (100,000+)
  /// Runs in isolate to prevent UI blocking
  Future<Uint8List> deriveMasterKey(String pin, Uint8List salt) async {
    return compute(_deriveMasterKeyIsolate, {'pin': pin, 'salt': salt});
  }
  
  /// Isolate function for key derivation (must be top-level or static)
  static Uint8List _deriveMasterKeyIsolate(Map<String, dynamic> params) {
    final pin = params['pin'] as String;
    final salt = params['salt'] as Uint8List;
    // Use iterative HMAC-SHA256 (similar to PBKDF2) with 100000 iterations
    var key = Uint8List.fromList(utf8.encode(pin));
    for (int i = 0; i < 100000; i++) {
      final hmac = Hmac(sha256, salt);
      key = Uint8List.fromList(hmac.convert(key).bytes);
    }
    return Uint8List.fromList(key.sublist(0, keyLength));
  }
  
  /// Derive per-file encryption key using HKDF
  Uint8List deriveFileKey(Uint8List masterKey, Uint8List fileId) {
    // Simple HKDF-like derivation: HMAC(masterKey, fileId)
    final hmac = Hmac(sha256, masterKey);
    final hash = hmac.convert(fileId);
    return Uint8List.fromList(hash.bytes.sublist(0, keyLength));
  }
  
  /// Generate random salt for password hashing
  Uint8List generateSalt() {
    final random = FortunaRandom();
    final seedSource = Random.secure();
    final seed = Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256)));
    random.seed(KeyParameter(seed));
    return random.nextBytes(saltLength);
  }
  
  /// Generate random nonce for GCM
  Uint8List generateNonce() {
    final random = FortunaRandom();
    final seedSource = Random.secure();
    final seed = Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256)));
    random.seed(KeyParameter(seed));
    return random.nextBytes(nonceLength);
  }
  
  /// Encrypt file using AES-256-GCM
  EncryptedData encryptFile(Uint8List data, Uint8List key) {
    final nonce = generateNonce();
    final cipher = GCMBlockCipher(AESEngine());
    
    final params = AEADParameters(
      KeyParameter(key),
      128, // tag length in bits
      nonce,
      Uint8List(0), // associated data (empty)
    );
    
    cipher.init(true, params);
    
    // GCM includes tag at the end
    final encrypted = cipher.process(data);
    
    // Extract tag (last 16 bytes) and ciphertext
    final tagLength = 16;
    final tag = encrypted.sublist(encrypted.length - tagLength);
    final ciphertext = encrypted.sublist(0, encrypted.length - tagLength);
    
    return EncryptedData(
      ciphertext: ciphertext,
      nonce: nonce,
      tag: tag,
    );
  }
  
  /// Decrypt file using AES-256-GCM
  Uint8List decryptFile(EncryptedData encrypted, Uint8List key) {
    final cipher = GCMBlockCipher(AESEngine());
    
    // Combine ciphertext and tag for decryption
    final ciphertextWithTag = Uint8List(encrypted.ciphertext.length + encrypted.tag.length);
    ciphertextWithTag.setRange(0, encrypted.ciphertext.length, encrypted.ciphertext);
    ciphertextWithTag.setRange(encrypted.ciphertext.length, ciphertextWithTag.length, encrypted.tag);
    
    final params = AEADParameters(
      KeyParameter(key),
      128, // tag length in bits
      encrypted.nonce,
      Uint8List(0), // associated data (empty)
    );
    
    cipher.init(false, params);
    
    return cipher.process(ciphertextWithTag);
  }
  
  /// Hash password with iterative HMAC for storage
  /// Returns base64 encoded hash with salt and parameters
  /// Runs in isolate to prevent UI blocking
  Future<String> hashPassword(String password, Uint8List salt) async {
    final hash = await compute(_hashPasswordIsolate, {'password': password, 'salt': salt});
    // Store as: iterations:salt:hash (base64 encoded)
    final encoded = base64Encode(utf8.encode('100000:${base64Encode(salt)}:${base64Encode(hash)}'));
    return encoded;
  }
  
  /// Isolate function for password hashing (must be top-level or static)
  static Uint8List _hashPasswordIsolate(Map<String, dynamic> params) {
    final password = params['password'] as String;
    final salt = params['salt'] as Uint8List;
    // Use iterative HMAC-SHA256 (100000 iterations)
    var hash = Uint8List.fromList(utf8.encode(password));
    for (int i = 0; i < 100000; i++) {
      final hmac = Hmac(sha256, salt);
      hash = Uint8List.fromList(hmac.convert(hash).bytes);
    }
    return hash;
  }
  
  /// Verify password against stored hash
  /// Runs hash computation in isolate to prevent UI blocking
  Future<bool> verifyPassword(String password, String storedHash) async {
    try {
      if (storedHash.isEmpty) {
        debugPrint('[EncryptionService] verifyPassword: storedHash is empty');
        return false;
      }
      
      final decoded = utf8.decode(base64Decode(storedHash));
      final parts = decoded.split(':');
      if (parts.length != 3) {
        debugPrint('[EncryptionService] verifyPassword: Invalid hash format, parts: ${parts.length}');
        return false;
      }
      
      final iterations = int.parse(parts[0]);
      final storedSalt = base64Decode(parts[1]);
      
      debugPrint('[EncryptionService] verifyPassword - Salt from hash: ${base64Encode(storedSalt)}');
      debugPrint('[EncryptionService] verifyPassword - Salt length: ${storedSalt.length}');
      debugPrint('[EncryptionService] verifyPassword - Password length: ${password.length}');
      debugPrint('[EncryptionService] verifyPassword - Password bytes: ${utf8.encode(password)}');
      
      // Compute hash with same iterations in isolate
      final computedHash = await compute(_verifyPasswordIsolate, {
        'password': password,
        'salt': storedSalt,
        'iterations': iterations,
      });
      
      debugPrint('[EncryptionService] verifyPassword - Computed hash (first 8 bytes): ${computedHash.sublist(0, computedHash.length > 8 ? 8 : computedHash.length)}');
      
      final storedHashBytes = base64Decode(parts[2]);
      
      debugPrint('[EncryptionService] verifyPassword - Stored hash (first 8 bytes): ${storedHashBytes.sublist(0, storedHashBytes.length > 8 ? 8 : storedHashBytes.length)}');
      
      // Compare byte by byte
      bool isValid = true;
      if (computedHash.length != storedHashBytes.length) {
        isValid = false;
        debugPrint('[EncryptionService] verifyPassword: Hash length mismatch - computed: ${computedHash.length}, stored: ${storedHashBytes.length}');
      } else {
        for (int i = 0; i < computedHash.length; i++) {
          if (computedHash[i] != storedHashBytes[i]) {
            isValid = false;
            debugPrint('[EncryptionService] verifyPassword: Hash mismatch at byte $i - computed: ${computedHash[i]}, stored: ${storedHashBytes[i]}');
            debugPrint('[EncryptionService] verifyPassword: Computed hash bytes 0-3: ${computedHash.sublist(0, 4)}');
            debugPrint('[EncryptionService] verifyPassword: Stored hash bytes 0-3: ${storedHashBytes.sublist(0, 4)}');
            // Only log first mismatch to avoid spam
            break;
          }
        }
      }
      
      if (!isValid) {
        debugPrint('[EncryptionService] verifyPassword: Hash mismatch');
        debugPrint('[EncryptionService] Computed hash length: ${computedHash.length}, Stored hash length: ${storedHashBytes.length}');
        debugPrint('[EncryptionService] Salt used for computation length: ${storedSalt.length}');
        debugPrint('[EncryptionService] Iterations: $iterations');
      }
      
      return isValid;
    } catch (e, stackTrace) {
      debugPrint('[EncryptionService] verifyPassword error: $e');
      debugPrint('[EncryptionService] Stack trace: $stackTrace');
      return false;
    }
  }
  
  /// Isolate function for password verification (must be top-level or static)
  static Uint8List _verifyPasswordIsolate(Map<String, dynamic> params) {
    final password = params['password'] as String;
    final salt = params['salt'] as Uint8List;
    final iterations = params['iterations'] as int;
    // Compute hash with same iterations
    var computedHash = Uint8List.fromList(utf8.encode(password));
    for (int i = 0; i < iterations; i++) {
      final hmac = Hmac(sha256, salt);
      computedHash = Uint8List.fromList(hmac.convert(computedHash).bytes);
    }
    return computedHash;
  }
  
  /// Encrypt a string using AES-256-GCM
  /// Returns base64-encoded encrypted data (nonce + tag + ciphertext)
  String encryptString(String plaintext, Uint8List key) {
    final data = Uint8List.fromList(utf8.encode(plaintext));
    final encrypted = encryptFile(data, key);
    
    // Serialize: nonce (12 bytes) + tag (16 bytes) + ciphertext
    final result = Uint8List(12 + 16 + encrypted.ciphertext.length);
    result.setRange(0, 12, encrypted.nonce);
    result.setRange(12, 28, encrypted.tag);
    result.setRange(28, result.length, encrypted.ciphertext);
    
    return base64Encode(result);
  }
  
  /// Decrypt a string encrypted with encryptString
  String decryptString(String encryptedBase64, Uint8List key) {
    try {
      final encryptedData = base64Decode(encryptedBase64);
      
      // Extract nonce, tag, and ciphertext
      final nonce = encryptedData.sublist(0, 12);
      final tag = encryptedData.sublist(12, 28);
      final ciphertext = encryptedData.sublist(28);
      
      final encrypted = EncryptedData(
        ciphertext: ciphertext,
        nonce: nonce,
        tag: tag,
      );
      
      final decrypted = decryptFile(encrypted, key);
      return utf8.decode(decrypted);
    } catch (e) {
      throw Exception('Failed to decrypt string: $e');
    }
  }
}

/// Container for encrypted file data
class EncryptedData {
  final Uint8List ciphertext;
  final Uint8List nonce;
  final Uint8List tag;
  
  EncryptedData({
    required this.ciphertext,
    required this.nonce,
    required this.tag,
  });
  
  /// Serialize to JSON-safe format
  Map<String, dynamic> toJson() {
    return {
      'ciphertext': base64Encode(ciphertext),
      'nonce': base64Encode(nonce),
      'tag': base64Encode(tag),
    };
  }
  
  /// Deserialize from JSON
  factory EncryptedData.fromJson(Map<String, dynamic> json) {
    return EncryptedData(
      ciphertext: base64Decode(json['ciphertext'] as String),
      nonce: base64Decode(json['nonce'] as String),
      tag: base64Decode(json['tag'] as String),
    );
  }
  
  /// Serialize to binary format (much faster than JSON for large files)
  /// Format: [4 bytes: nonce length][nonce][4 bytes: tag length][tag][4 bytes: ciphertext length][ciphertext]
  Uint8List toBinary() {
    final nonceLen = nonce.length;
    final tagLen = tag.length;
    final ciphertextLen = ciphertext.length;
    
    final totalLen = 4 + nonceLen + 4 + tagLen + 4 + ciphertextLen;
    final buffer = Uint8List(totalLen);
    int offset = 0;
    
    // Write nonce length and nonce
    buffer[offset] = (nonceLen >> 24) & 0xFF;
    buffer[offset + 1] = (nonceLen >> 16) & 0xFF;
    buffer[offset + 2] = (nonceLen >> 8) & 0xFF;
    buffer[offset + 3] = nonceLen & 0xFF;
    offset += 4;
    buffer.setRange(offset, offset + nonceLen, nonce);
    offset += nonceLen;
    
    // Write tag length and tag
    buffer[offset] = (tagLen >> 24) & 0xFF;
    buffer[offset + 1] = (tagLen >> 16) & 0xFF;
    buffer[offset + 2] = (tagLen >> 8) & 0xFF;
    buffer[offset + 3] = tagLen & 0xFF;
    offset += 4;
    buffer.setRange(offset, offset + tagLen, tag);
    offset += tagLen;
    
    // Write ciphertext length and ciphertext
    buffer[offset] = (ciphertextLen >> 24) & 0xFF;
    buffer[offset + 1] = (ciphertextLen >> 16) & 0xFF;
    buffer[offset + 2] = (ciphertextLen >> 8) & 0xFF;
    buffer[offset + 3] = ciphertextLen & 0xFF;
    offset += 4;
    buffer.setRange(offset, offset + ciphertextLen, ciphertext);
    
    return buffer;
  }
  
  /// Deserialize from binary format
  factory EncryptedData.fromBinary(Uint8List data) {
    int offset = 0;
    
    // Read nonce
    final nonceLen = (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
    offset += 4;
    final nonce = data.sublist(offset, offset + nonceLen);
    offset += nonceLen;
    
    // Read tag
    final tagLen = (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
    offset += 4;
    final tag = data.sublist(offset, offset + tagLen);
    offset += tagLen;
    
    // Read ciphertext
    final ciphertextLen = (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
    offset += 4;
    final ciphertext = data.sublist(offset, offset + ciphertextLen);
    
    return EncryptedData(
      ciphertext: ciphertext,
      nonce: nonce,
      tag: tag,
    );
  }
}

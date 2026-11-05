import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vault_cipher.dart';

/// Hardware AES-GCM for vault files (CryptoKit on iOS).
///
/// Writes and reads exactly the [VaultCipher] format, so files written here
/// decrypt in Dart and the reverse. Pure-Dart AES-GCM runs at about 18 MiB/s
/// on a phone, which made a large video import take tens of seconds and made
/// playback wait for a full decrypt; CryptoKit is disk-bound instead.
///
/// Every method returns null when the native side is not there (Android,
/// tests, an older binary), and callers then use the Dart cipher. Key
/// derivation stays in Dart: native code receives the derived 32-byte file key
/// and the 8-byte AAD prefix, never the master key.
///
/// Method channels only work on the root isolate, so call these from the main
/// isolate; the work itself runs on a native background queue.
class NativeVaultCrypto {
  static const MethodChannel _channel =
      MethodChannel('com.angelonartey.nyx/vault_crypto');

  static bool _unavailable = !kIsWeb && !Platform.isIOS;

  /// For tests: force the Dart fallback.
  @visibleForTesting
  static set disabledForTesting(bool value) => _unavailable = value;

  static bool get mayBeAvailable => !_unavailable;

  /// Encrypts [sourcePath] into [destPath] (truncating it). Returns the
  /// plaintext byte count and, when [computeSha256], the lowercase hex digest.
  static Future<({int bytes, String sha256})?> encryptFile({
    required String sourcePath,
    required String destPath,
    required Uint8List fileKey,
    required String fileId,
    bool computeSha256 = false,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>('encryptFile', {
      'src': sourcePath,
      'dst': destPath,
      'key': fileKey,
      'aadPrefix': VaultCipher.fileIdHashFor(fileId),
      'computeSha256': computeSha256,
    });
    if (result == null) return null;
    return (
      bytes: (result['bytes'] as num).toInt(),
      sha256: (result['sha256'] as String?) ?? '',
    );
  }

  /// Decrypts the whole of [sourcePath] into [destPath]. Returns the
  /// plaintext byte count.
  static Future<int?> decryptFile({
    required String sourcePath,
    required String destPath,
    required Uint8List fileKey,
    required String fileId,
  }) async {
    final result = await _invoke<num>('decryptFile', {
      'src': sourcePath,
      'dst': destPath,
      'key': fileKey,
      'aadPrefix': VaultCipher.fileIdHashFor(fileId),
    });
    return result?.toInt();
  }

  /// Decrypts [count] chunks starting at [firstChunk]; stops at end of file.
  static Future<Uint8List?> decryptChunks({
    required String sourcePath,
    required Uint8List fileKey,
    required String fileId,
    required int firstChunk,
    required int count,
  }) {
    return _invoke<Uint8List>('decryptChunks', {
      'src': sourcePath,
      'key': fileKey,
      'aadPrefix': VaultCipher.fileIdHashFor(fileId),
      'first': firstChunk,
      'count': count,
    });
  }

  static Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    if (_unavailable) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      _unavailable = true;
      return null;
    } on PlatformException catch (e) {
      if (e.code == 'AUTH_FAILED' || e.code == 'FORMAT') {
        throw VaultCipherException(e.message ?? e.code);
      }
      rethrow;
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'encryption_service.dart';

/// On-disk encryption for vault files, thumbnails, and the index.
///
/// Format (version 0x01):
///
///   [1 byte version = 0x01]
///   [chunk]+
///
/// Each chunk: `[12 byte nonce][ciphertext][16 byte GCM tag]`.
///
/// Plaintext chunk size is fixed at 1 MiB. The last chunk may be shorter
/// (and may be empty for a zero-length file). AAD per chunk is
/// `sha256(fileId)[0:8] || chunk_index_be4` so chunks are bound to a file
/// identity and order — a swapped or reordered chunk fails authentication.
class VaultCipher {
  static const int versionByte = 0x01;
  static const int chunkPlaintextSize = 1024 * 1024; // 1 MiB
  static const int nonceLength = 12;
  static const int tagLength = 16;

  final EncryptionService _encryption;

  VaultCipher(this._encryption);

  /// HKDF-SHA256(masterKey, salt=zeros, info=fileId) → 32-byte key.
  /// Replaces the legacy single-step HMAC derivation in EncryptionService.
  Uint8List deriveFileKey(Uint8List masterKey, String fileId) {
    // RFC 5869 HKDF, single-block expand (32 bytes is one HMAC-SHA256 block).
    final salt = Uint8List(32); // empty salt
    final prk = Hmac(sha256, salt).convert(masterKey).bytes; // extract
    final info = utf8.encode(fileId);
    final expandInput = Uint8List(info.length + 1)
      ..setRange(0, info.length, info)
      ..[info.length] = 0x01;
    final okm = Hmac(sha256, prk).convert(expandInput).bytes;
    return Uint8List.fromList(okm.sublist(0, 32));
  }

  /// Encrypt a small in-memory blob. OK for files up to a few MB.
  /// For larger files use [encryptStreamToFile].
  Uint8List encryptBytes({
    required Uint8List masterKey,
    required String fileId,
    required Uint8List plaintext,
  }) {
    final fileKey = deriveFileKey(masterKey, fileId);
    final fileIdHash = _fileIdHash(fileId);
    final out = BytesBuilder();
    out.addByte(versionByte);

    if (plaintext.isEmpty) {
      _writeChunk(out, fileKey, Uint8List(0), fileIdHash, 0);
      return out.toBytes();
    }

    final chunkCount = (plaintext.length / chunkPlaintextSize).ceil();
    for (var i = 0; i < chunkCount; i++) {
      final start = i * chunkPlaintextSize;
      final end = start + chunkPlaintextSize > plaintext.length
          ? plaintext.length
          : start + chunkPlaintextSize;
      final chunk = Uint8List.sublistView(plaintext, start, end);
      _writeChunk(out, fileKey, chunk, fileIdHash, i);
    }
    return out.toBytes();
  }

  /// Decrypt a small in-memory blob produced by [encryptBytes].
  /// Throws [VaultCipherException] on tampering or truncation.
  Uint8List decryptBytes({
    required Uint8List masterKey,
    required String fileId,
    required Uint8List onDisk,
  }) {
    if (onDisk.isEmpty) {
      throw VaultCipherException('Empty input');
    }
    if (onDisk[0] != versionByte) {
      throw VaultCipherException(
          'Unsupported version byte 0x${onDisk[0].toRadixString(16)}');
    }

    final fileKey = deriveFileKey(masterKey, fileId);
    final fileIdHash = _fileIdHash(fileId);
    final out = BytesBuilder();
    var offset = 1;
    var chunkIndex = 0;
    final maxChunkOnDisk = nonceLength + chunkPlaintextSize + tagLength;

    while (offset < onDisk.length) {
      final remaining = onDisk.length - offset;
      if (remaining < nonceLength + tagLength) {
        throw VaultCipherException('Truncated chunk at offset $offset');
      }
      final chunkOnDiskLen =
          remaining > maxChunkOnDisk ? maxChunkOnDisk : remaining;

      final nonce =
          Uint8List.sublistView(onDisk, offset, offset + nonceLength);
      final ctWithTag = Uint8List.sublistView(
          onDisk, offset + nonceLength, offset + chunkOnDiskLen);

      final plaintext =
          _gcmProcess(false, fileKey, nonce, ctWithTag, fileIdHash, chunkIndex);
      out.add(plaintext);
      offset += chunkOnDiskLen;
      chunkIndex++;
    }
    return out.toBytes();
  }

  /// Streaming encrypt from one file to another. Use for any file that may be
  /// large (videos especially). Reads in 1 MiB chunks; never loads the whole
  /// plaintext into memory.
  Future<void> encryptStreamToFile({
    required Uint8List masterKey,
    required String fileId,
    required File source,
    required File dest,
  }) async {
    final fileKey = deriveFileKey(masterKey, fileId);
    final fileIdHash = _fileIdHash(fileId);

    final sink = dest.openWrite();
    try {
      sink.add(<int>[versionByte]);
      var chunkIndex = 0;
      final buffer = BytesBuilder();

      await for (final piece in source.openRead()) {
        buffer.add(piece);
        while (buffer.length >= chunkPlaintextSize) {
          final all = buffer.takeBytes();
          final chunk = Uint8List.sublistView(all, 0, chunkPlaintextSize);
          final leftover =
              Uint8List.sublistView(all, chunkPlaintextSize, all.length);
          _writeChunkToSink(sink, fileKey, chunk, fileIdHash, chunkIndex);
          chunkIndex++;
          if (leftover.isNotEmpty) buffer.add(leftover);
        }
      }

      // Flush trailing partial chunk. Always emit at least one chunk so that
      // an empty file still has the version byte + one (empty) chunk and round-trips.
      final trailing = buffer.takeBytes();
      if (trailing.isNotEmpty || chunkIndex == 0) {
        _writeChunkToSink(sink, fileKey, trailing, fileIdHash, chunkIndex);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  /// Streaming decrypt from one file to another.
  Future<void> decryptStreamToFile({
    required Uint8List masterKey,
    required String fileId,
    required File source,
    required File dest,
  }) async {
    final fileKey = deriveFileKey(masterKey, fileId);
    final fileIdHash = _fileIdHash(fileId);
    final fileLen = await source.length();
    if (fileLen < 1) {
      throw VaultCipherException('Empty input');
    }
    final raf = await source.open();
    final sink = dest.openWrite();
    try {
      final versionBytes = await raf.read(1);
      if (versionBytes.isEmpty || versionBytes[0] != versionByte) {
        throw VaultCipherException('Unsupported version byte');
      }

      var offset = 1;
      var chunkIndex = 0;
      final maxChunkOnDisk = nonceLength + chunkPlaintextSize + tagLength;

      while (offset < fileLen) {
        final remaining = fileLen - offset;
        if (remaining < nonceLength + tagLength) {
          throw VaultCipherException('Truncated chunk at offset $offset');
        }
        final chunkOnDiskLen =
            remaining > maxChunkOnDisk ? maxChunkOnDisk : remaining;
        await raf.setPosition(offset);
        final chunkBytes = await raf.read(chunkOnDiskLen);
        final nonce = Uint8List.sublistView(chunkBytes, 0, nonceLength);
        final ctWithTag =
            Uint8List.sublistView(chunkBytes, nonceLength, chunkOnDiskLen);
        final plaintext = _gcmProcess(
            false, fileKey, nonce, ctWithTag, fileIdHash, chunkIndex);
        sink.add(plaintext);
        offset += chunkOnDiskLen;
        chunkIndex++;
      }
    } finally {
      await raf.close();
      await sink.flush();
      await sink.close();
    }
  }

  /// Begin a streaming encryption session that writes ciphertext to [dest].
  /// Caller calls [StreamingEncrypter.add] with plaintext chunks of any size,
  /// then [StreamingEncrypter.finalize] when done. Useful when the source is
  /// already a stream the caller is consuming for other reasons (e.g. hashing
  /// for deduplication).
  StreamingEncrypter beginEncrypt({
    required Uint8List masterKey,
    required String fileId,
    required IOSink dest,
  }) {
    return StreamingEncrypter._(
      cipher: this,
      fileKey: deriveFileKey(masterKey, fileId),
      fileIdHash: _fileIdHash(fileId),
      dest: dest,
    );
  }

  /// Cheap heuristic to detect "this might be one of our ciphertext files".
  /// Authoritative source for whether a file is encrypted is the
  /// `metadata.encryption` flag on the [VaultItem] — this is just a guard for
  /// migration to avoid double-encrypting.
  static Future<bool> looksEncrypted(File file) async {
    if (!await file.exists()) return false;
    final len = await file.length();
    if (len < 1 + nonceLength + tagLength) return false;
    final raf = await file.open();
    try {
      final firstByte = await raf.read(1);
      return firstByte.isNotEmpty && firstByte[0] == versionByte;
    } finally {
      await raf.close();
    }
  }

  // ---------------- internals ----------------

  Uint8List _fileIdHash(String fileId) {
    final digest = sha256.convert(utf8.encode(fileId)).bytes;
    return Uint8List.fromList(digest.sublist(0, 8));
  }

  Uint8List _aadFor(Uint8List fileIdHash, int chunkIndex) {
    final aad = Uint8List(12);
    aad.setRange(0, 8, fileIdHash);
    aad[8] = (chunkIndex >> 24) & 0xFF;
    aad[9] = (chunkIndex >> 16) & 0xFF;
    aad[10] = (chunkIndex >> 8) & 0xFF;
    aad[11] = chunkIndex & 0xFF;
    return aad;
  }

  Uint8List _gcmProcess(bool encrypt, Uint8List key, Uint8List nonce,
      Uint8List input, Uint8List fileIdHash, int chunkIndex) {
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      encrypt,
      AEADParameters(
        KeyParameter(key),
        tagLength * 8,
        nonce,
        _aadFor(fileIdHash, chunkIndex),
      ),
    );
    return cipher.process(input);
  }

  void _writeChunk(BytesBuilder out, Uint8List fileKey, Uint8List chunk,
      Uint8List fileIdHash, int chunkIndex) {
    final nonce = _encryption.generateNonce();
    final ctWithTag =
        _gcmProcess(true, fileKey, nonce, chunk, fileIdHash, chunkIndex);
    out.add(nonce);
    out.add(ctWithTag);
  }

  void _writeChunkToSink(IOSink sink, Uint8List fileKey, Uint8List chunk,
      Uint8List fileIdHash, int chunkIndex) {
    final nonce = _encryption.generateNonce();
    final ctWithTag =
        _gcmProcess(true, fileKey, nonce, chunk, fileIdHash, chunkIndex);
    sink.add(nonce);
    sink.add(ctWithTag);
  }
}

/// Stateful chunked encrypter. Created via [VaultCipher.beginEncrypt].
class StreamingEncrypter {
  final VaultCipher _cipher;
  final Uint8List _fileKey;
  final Uint8List _fileIdHash;
  final IOSink _dest;
  final BytesBuilder _buffer = BytesBuilder();
  int _chunkIndex = 0;
  bool _versionWritten = false;
  bool _finalized = false;

  StreamingEncrypter._({
    required VaultCipher cipher,
    required Uint8List fileKey,
    required Uint8List fileIdHash,
    required IOSink dest,
  })  : _cipher = cipher,
        _fileKey = fileKey,
        _fileIdHash = fileIdHash,
        _dest = dest;

  void add(List<int> plaintext) {
    if (_finalized) {
      throw StateError('StreamingEncrypter already finalized');
    }
    _ensureVersion();
    _buffer.add(plaintext);
    while (_buffer.length >= VaultCipher.chunkPlaintextSize) {
      final all = _buffer.takeBytes();
      final chunk =
          Uint8List.sublistView(all, 0, VaultCipher.chunkPlaintextSize);
      final leftover =
          Uint8List.sublistView(all, VaultCipher.chunkPlaintextSize, all.length);
      _emitChunk(chunk);
      if (leftover.isNotEmpty) _buffer.add(leftover);
    }
  }

  void finalize() {
    if (_finalized) return;
    _ensureVersion();
    final trailing = _buffer.takeBytes();
    if (trailing.isNotEmpty || _chunkIndex == 0) {
      _emitChunk(trailing);
    }
    _finalized = true;
  }

  void _ensureVersion() {
    if (_versionWritten) return;
    _dest.add(<int>[VaultCipher.versionByte]);
    _versionWritten = true;
  }

  void _emitChunk(Uint8List plaintextChunk) {
    final nonce = _cipher._encryption.generateNonce();
    final ctWithTag = _cipher._gcmProcess(
        true, _fileKey, nonce, plaintextChunk, _fileIdHash, _chunkIndex);
    _dest.add(nonce);
    _dest.add(ctWithTag);
    _chunkIndex++;
  }
}

class VaultCipherException implements Exception {
  final String message;
  VaultCipherException(this.message);
  @override
  String toString() => 'VaultCipherException: $message';
}

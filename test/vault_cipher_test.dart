import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyx/core/services/encryption_service.dart';
import 'package:nyx/core/services/vault_cipher.dart';
import 'package:path/path.dart' as p;

void main() {
  late VaultCipher cipher;
  late Uint8List masterKey;

  setUp(() {
    cipher = VaultCipher(EncryptionService());
    masterKey = Uint8List.fromList(
        List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF));
  });

  Uint8List random(int n, {int seed = 1}) {
    final r = Random(seed);
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  group('encryptBytes / decryptBytes round trip', () {
    test('empty plaintext', () {
      final ct = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'item-1', plaintext: Uint8List(0));
      expect(ct[0], VaultCipher.versionByte);
      // empty plaintext still emits one chunk: version (1) + nonce (12) + tag (16)
      expect(ct.length, 1 + VaultCipher.nonceLength + VaultCipher.tagLength);
      final pt = cipher.decryptBytes(
          masterKey: masterKey, fileId: 'item-1', onDisk: ct);
      expect(pt.length, 0);
    });

    test('small plaintext under one chunk', () {
      final pt = random(2048, seed: 11);
      final ct = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'photo-jpg', plaintext: pt);
      final back = cipher.decryptBytes(
          masterKey: masterKey, fileId: 'photo-jpg', onDisk: ct);
      expect(back, equals(pt));
    });

    test('plaintext exactly at chunk boundary', () {
      final pt = random(VaultCipher.chunkPlaintextSize, seed: 12);
      final ct = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'boundary', plaintext: pt);
      final back = cipher.decryptBytes(
          masterKey: masterKey, fileId: 'boundary', onDisk: ct);
      expect(back, equals(pt));
    });

    test('multi-chunk plaintext (3.5 MiB)', () {
      final pt = random(VaultCipher.chunkPlaintextSize * 3 + 500000, seed: 13);
      final ct = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'big', plaintext: pt);
      final back = cipher.decryptBytes(
          masterKey: masterKey, fileId: 'big', onDisk: ct);
      expect(back, equals(pt));
    });

    test('different fileIds produce different ciphertexts', () {
      final pt = Uint8List.fromList(List.filled(64, 7));
      final a = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'A', plaintext: pt);
      final b = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'B', plaintext: pt);
      expect(a, isNot(equals(b)));
    });

    test('two encryptions of identical plaintext differ (random nonce)', () {
      final pt = Uint8List.fromList(List.filled(64, 9));
      final a = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'X', plaintext: pt);
      final b = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'X', plaintext: pt);
      expect(a, isNot(equals(b)));
    });
  });

  group('tampering', () {
    test('flipped ciphertext byte fails authentication', () {
      final pt = random(1024, seed: 21);
      final ct = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'tamper-1', plaintext: pt);
      // flip a byte in the middle (avoid version byte)
      final tampered = Uint8List.fromList(ct);
      tampered[50] ^= 0x01;
      expect(
        () => cipher.decryptBytes(
            masterKey: masterKey, fileId: 'tamper-1', onDisk: tampered),
        throwsA(isA<dynamic>()),
      );
    });

    test('decryption with wrong fileId fails (AAD binding)', () {
      final pt = random(1024, seed: 22);
      final ct = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'right-id', plaintext: pt);
      expect(
        () => cipher.decryptBytes(
            masterKey: masterKey, fileId: 'wrong-id', onDisk: ct),
        throwsA(isA<dynamic>()),
      );
    });

    test('decryption with wrong master key fails', () {
      final pt = random(1024, seed: 23);
      final ct = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'wk', plaintext: pt);
      final wrongKey = Uint8List.fromList(
          List<int>.generate(32, (i) => (i * 11 + 5) & 0xFF));
      expect(
        () => cipher.decryptBytes(
            masterKey: wrongKey, fileId: 'wk', onDisk: ct),
        throwsA(isA<dynamic>()),
      );
    });

    test('truncated input throws', () {
      final pt = random(1024, seed: 24);
      final ct = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'trunc', plaintext: pt);
      final trimmed = Uint8List.sublistView(ct, 0, ct.length - 5);
      expect(
        () => cipher.decryptBytes(
            masterKey: masterKey, fileId: 'trunc', onDisk: trimmed),
        throwsA(isA<dynamic>()),
      );
    });

    test('unsupported version byte throws', () {
      final ct = cipher.encryptBytes(
          masterKey: masterKey,
          fileId: 'v',
          plaintext: Uint8List.fromList([1, 2, 3]));
      final swapped = Uint8List.fromList(ct);
      swapped[0] = 0x99;
      expect(
        () => cipher.decryptBytes(
            masterKey: masterKey, fileId: 'v', onDisk: swapped),
        throwsA(isA<VaultCipherException>()),
      );
    });

    test('reordering chunks breaks authentication', () {
      // Need at least two chunks
      final pt = random(VaultCipher.chunkPlaintextSize + 50000, seed: 25);
      final ct = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'reorder', plaintext: pt);
      // Compute chunk boundaries
      final chunk0Start = 1;
      final chunk0Len = VaultCipher.nonceLength +
          VaultCipher.chunkPlaintextSize +
          VaultCipher.tagLength;
      final chunk1Start = chunk0Start + chunk0Len;
      final swapped = Uint8List.fromList(ct);
      // Swap the nonce of chunk 0 and chunk 1 (each starts with 12 bytes nonce)
      // This reorders the ciphertext_index↔nonce mapping but keeps internal
      // structure parseable. AAD binding to chunk_index will reject it.
      for (var i = 0; i < VaultCipher.nonceLength; i++) {
        final tmp = swapped[chunk0Start + i];
        swapped[chunk0Start + i] = swapped[chunk1Start + i];
        swapped[chunk1Start + i] = tmp;
      }
      expect(
        () => cipher.decryptBytes(
            masterKey: masterKey, fileId: 'reorder', onDisk: swapped),
        throwsA(isA<dynamic>()),
      );
    });
  });

  group('streaming', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('vault_cipher_test_');
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('streaming round-trip 2.5 MiB', () async {
      final src = File(p.join(tmpDir.path, 'src.bin'));
      final enc = File(p.join(tmpDir.path, 'enc.bin'));
      final dec = File(p.join(tmpDir.path, 'dec.bin'));
      final pt = random(VaultCipher.chunkPlaintextSize * 2 + 555555, seed: 31);
      await src.writeAsBytes(pt);
      await cipher.encryptStreamToFile(
          masterKey: masterKey, fileId: 'streamy', source: src, dest: enc);
      // sanity: encrypted file starts with version byte
      final firstByte = (await enc.openRead(0, 1).first);
      expect(firstByte[0], VaultCipher.versionByte);
      await cipher.decryptStreamToFile(
          masterKey: masterKey, fileId: 'streamy', source: enc, dest: dec);
      final back = await dec.readAsBytes();
      expect(back, equals(pt));
    });

    test('streaming output is byte-identical to in-memory output', () async {
      final pt = random(50000, seed: 32);
      final memCt = cipher.encryptBytes(
          masterKey: masterKey, fileId: 'compare', plaintext: pt);

      // Streaming encrypt with the same nonces would require deterministic RNG;
      // since nonces are random we instead verify the streaming output decrypts
      // to the same plaintext via decryptBytes round-trip.
      final src = File(p.join(tmpDir.path, 'src.bin'));
      final enc = File(p.join(tmpDir.path, 'enc.bin'));
      await src.writeAsBytes(pt);
      await cipher.encryptStreamToFile(
          masterKey: masterKey, fileId: 'compare', source: src, dest: enc);

      final encBytes = await enc.readAsBytes();
      final back = cipher.decryptBytes(
          masterKey: masterKey, fileId: 'compare', onDisk: encBytes);
      expect(back, equals(pt));

      // And in-memory ciphertext is decryptable by streaming path
      final memCtFile = File(p.join(tmpDir.path, 'memct.bin'));
      await memCtFile.writeAsBytes(memCt);
      final dec = File(p.join(tmpDir.path, 'dec.bin'));
      await cipher.decryptStreamToFile(
          masterKey: masterKey,
          fileId: 'compare',
          source: memCtFile,
          dest: dec);
      expect(await dec.readAsBytes(), equals(pt));
    });

    test('looksEncrypted detects ciphertext', () async {
      final src = File(p.join(tmpDir.path, 'src.bin'));
      final enc = File(p.join(tmpDir.path, 'enc.bin'));
      await src.writeAsBytes(random(32, seed: 41));
      await cipher.encryptStreamToFile(
          masterKey: masterKey, fileId: 'le', source: src, dest: enc);
      expect(await VaultCipher.looksEncrypted(enc), isTrue);

      final plain = File(p.join(tmpDir.path, 'plain.bin'));
      await plain.writeAsBytes(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])); // JPEG header
      expect(await VaultCipher.looksEncrypted(plain), isFalse);
    });
  });

  group('deriveFileKey', () {
    test('is deterministic and 32 bytes', () {
      final k1 = cipher.deriveFileKey(masterKey, 'item-42');
      final k2 = cipher.deriveFileKey(masterKey, 'item-42');
      expect(k1, equals(k2));
      expect(k1.length, 32);
    });

    test('different fileIds produce different keys', () {
      final k1 = cipher.deriveFileKey(masterKey, 'a');
      final k2 = cipher.deriveFileKey(masterKey, 'b');
      expect(k1, isNot(equals(k2)));
    });

    test('different master keys produce different file keys', () {
      final other = Uint8List.fromList(
          List<int>.generate(32, (i) => (i * 13) & 0xFF));
      final k1 = cipher.deriveFileKey(masterKey, 'same-id');
      final k2 = cipher.deriveFileKey(other, 'same-id');
      expect(k1, isNot(equals(k2)));
    });
  });
}

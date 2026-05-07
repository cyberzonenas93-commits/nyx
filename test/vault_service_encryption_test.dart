import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nyx/core/models/vault_item.dart';
import 'package:nyx/core/services/encryption_service.dart';
import 'package:nyx/core/services/vault_cipher.dart';
import 'package:nyx/core/services/vault_service.dart';

// ---------------------------------------------------------------------------
// Fake PathProvider — routes both "documents" and "temp" to local temp dirs.
// ---------------------------------------------------------------------------
class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String docs;
  final String tmp;
  _FakePaths({required this.docs, required this.tmp});

  @override
  Future<String?> getApplicationDocumentsPath() async => docs;

  @override
  Future<String?> getTemporaryPath() async => tmp;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootTmp;
  late Directory decryptTmp;
  late VaultService vault;
  late Uint8List masterKey;

  setUp(() async {
    rootTmp = await Directory.systemTemp.createTemp('nyx_vault_test_');
    decryptTmp = await Directory.systemTemp.createTemp('nyx_decrypt_test_');

    PathProviderPlatform.instance =
        _FakePaths(docs: rootTmp.path, tmp: decryptTmp.path);
    SharedPreferences.setMockInitialValues({});

    // Suppress the iCloud platform channel — unavailable in unit tests.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.angelonartey.nyx/icloud'),
      (_) async => null,
    );

    masterKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    vault = VaultService(EncryptionService());
    await vault.initialize(masterKey: masterKey);
  });

  tearDown(() async {
    await vault.clearDecryptedCache();
    try {
      await rootTmp.delete(recursive: true);
    } catch (_) {}
    try {
      await decryptTmp.delete(recursive: true);
    } catch (_) {}
  });

  // ── helper ──────────────────────────────────────────────────────────────────
  File _vaultFile(VaultItem item) =>
      File('${rootTmp.path}/vault/${item.vaultRelativePath ?? item.id}');

  // ── write path ───────────────────────────────────────────────────────────────

  group('storeFile — write path', () {
    test('on-disk file starts with ciphertext version byte (0x01)', () async {
      final item = await vault.storeFile(
        data: Uint8List.fromList('hello vault'.codeUnits),
        filename: 'note.txt',
      );
      final bytes = await _vaultFile(item).readAsBytes();
      expect(bytes[0], VaultCipher.versionByte,
          reason: 'stored file must begin with 0x01 version byte');
    });

    test('on-disk bytes are not equal to plaintext', () async {
      final pt = Uint8List.fromList('hello vault'.codeUnits);
      final item = await vault.storeFile(data: pt, filename: 'note.txt');
      final ct = await _vaultFile(item).readAsBytes();
      expect(ct, isNot(equals(pt)));
    });

    test('item is marked encrypted in metadata', () async {
      final item = await vault.storeFile(
        data: Uint8List.fromList([0, 1, 2, 3]),
        filename: 'bin.bin',
      );
      expect(item.isEncrypted, isTrue);
      expect(
        item.metadata?[VaultService.kEncryptionMetadataKey],
        VaultService.kEncryptionVersion,
      );
    });

    test('two distinct files get distinct ciphertext', () async {
      final i1 = await vault.storeFile(
          data: Uint8List.fromList('file one'.codeUnits), filename: 'a.txt');
      final i2 = await vault.storeFile(
          data: Uint8List.fromList('file two'.codeUnits), filename: 'b.txt');
      final ct1 = await _vaultFile(i1).readAsBytes();
      final ct2 = await _vaultFile(i2).readAsBytes();
      expect(ct1, isNot(equals(ct2)));
    });
  });

  // ── read path ────────────────────────────────────────────────────────────────

  group('getDecryptedFilePath — read path', () {
    test('decrypted file contains original plaintext', () async {
      final pt = Uint8List.fromList(List<int>.generate(256, (i) => i & 0xFF));
      final item = await vault.storeFile(data: pt, filename: 'ramp.bin');

      final path = await vault.getDecryptedFilePath(item.id);
      expect(path, isNotNull);
      final decrypted = await File(path!).readAsBytes();
      expect(decrypted, equals(pt));
    });

    test('second call returns cached path (same string)', () async {
      final item = await vault.storeFile(
        data: Uint8List.fromList('cache me'.codeUnits),
        filename: 'c.txt',
      );
      final path1 = await vault.getDecryptedFilePath(item.id);
      final path2 = await vault.getDecryptedFilePath(item.id);
      expect(path1, equals(path2));
    });
  });

  group('getFileData — read path', () {
    test('returns original plaintext bytes', () async {
      final pt = Uint8List.fromList(List<int>.generate(100, (i) => i));
      final item = await vault.storeFile(data: pt, filename: 'hundred.bin');

      final data = await vault.getFileData(item.id);
      expect(data, equals(pt));
    });
  });

  // ── migration ─────────────────────────────────────────────────────────────────

  group('migration — pre-existing plaintext files', () {
    test('plaintext file is encrypted in-place', () async {
      const fileId = 'legacy-001';
      final vaultDir = Directory('${rootTmp.path}/vault');
      final ptData = Uint8List.fromList('old unencrypted content'.codeUnits);

      // Plant a plaintext file directly on disk.
      await File('${vaultDir.path}/$fileId').writeAsBytes(ptData);

      // Write an index that contains only the legacy unencrypted item.
      // (items.json may not exist yet if no files have been stored via storeFile.)
      final legacyEntry = {
        'id': fileId,
        'originalFilename': 'legacy.bin',
        'type': 'other',
        'sizeBytes': ptData.length,
        'dateAdded': DateTime.now().toIso8601String(),
        'source': 'unknown',
        'isEncrypted': false,
        'vaultRelativePath': fileId,
      };
      final indexFile = File('${vaultDir.path}/index/items.json');
      final List<dynamic> existingItems;
      if (await indexFile.exists()) {
        final parsed =
            jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
        existingItems = List<dynamic>.from(
            (parsed['items'] as List<dynamic>? ?? []));
      } else {
        existingItems = [];
      }
      existingItems.add(legacyEntry);
      await indexFile.writeAsString(jsonEncode({
        'version': 1,
        'lastUpdated': DateTime.now().toIso8601String(),
        'items': existingItems,
      }));

      // Reinitialize so VaultService picks up the new index, then run migration.
      await vault.initialize(masterKey: masterKey, forceReinit: true);
      await vault.runEncryptionMigration();

      // On-disk file must now be ciphertext.
      final onDisk = await File('${vaultDir.path}/$fileId').readAsBytes();
      expect(onDisk[0], VaultCipher.versionByte,
          reason: 'migrated file must start with 0x01');
      expect(onDisk, isNot(equals(ptData)));

      // Reading back through the vault must return the original plaintext.
      final readBack = await vault.getFileData(fileId);
      expect(readBack, equals(ptData));
    });

    test('already-encrypted file survives migration unchanged', () async {
      final pt = Uint8List.fromList('already safe'.codeUnits);
      final item = await vault.storeFile(data: pt, filename: 'safe.bin');
      final ctBefore = await _vaultFile(item).readAsBytes();

      await vault.runEncryptionMigration(); // idempotent

      // File bytes must be identical after a no-op migration run.
      final ctAfter = await _vaultFile(item).readAsBytes();
      expect(ctAfter, equals(ctBefore));

      // And still decrypts correctly.
      expect(await vault.getFileData(item.id), equals(pt));
    });
  });
}

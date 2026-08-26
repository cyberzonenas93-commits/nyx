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
import 'package:nyx/core/services/simple_video_import_service.dart';
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
  late Directory iCloudTmp;
  late VaultService vault;
  late Uint8List masterKey;

  setUp(() async {
    rootTmp = await Directory.systemTemp.createTemp('nyx_vault_test_');
    decryptTmp = await Directory.systemTemp.createTemp('nyx_decrypt_test_');
    iCloudTmp = await Directory.systemTemp.createTemp('nyx_icloud_test_');

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
    try {
      await iCloudTmp.delete(recursive: true);
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

    test('concurrent callers receive one complete decrypted file', () async {
      final pt = Uint8List.fromList(
        List<int>.generate(
          VaultCipher.chunkPlaintextSize * 2 + 8192,
          (i) => (i * 31) & 0xFF,
        ),
      );
      final item = await vault.storeFile(data: pt, filename: 'large.bin');

      final paths = await Future.wait(
        List<Future<String?>>.generate(
          8,
          (_) => vault.getDecryptedFilePath(item.id),
        ),
      );

      expect(paths, everyElement(isNotNull));
      expect(paths.toSet(), hasLength(1));
      expect(await File(paths.first!).readAsBytes(), equals(pt));

      final stagingFiles = await Directory('${decryptTmp.path}/nyx_decrypted')
          .list()
          .where((entity) => entity.path.endsWith('.partial'))
          .toList();
      expect(stagingFiles, isEmpty);
    });

    test('repairs a truncated decrypted cache entry before returning it',
        () async {
      final pt = Uint8List.fromList(
        List<int>.generate(32 * 1024, (i) => (i * 17) & 0xFF),
      );
      final item = await vault.storeFile(data: pt, filename: 'cache.bin');
      final firstPath = await vault.getDecryptedFilePath(item.id);
      expect(firstPath, isNotNull);

      await File(firstPath!).writeAsBytes(<int>[1, 2, 3], flush: true);

      final repairedPath = await vault.getDecryptedFilePath(item.id);
      expect(repairedPath, firstPath);
      expect(await File(repairedPath!).readAsBytes(), equals(pt));
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

  group('simple video import', () {
    SimpleVideoImportRequest requestFor({
      required String assetId,
      required File file,
    }) {
      return SimpleVideoImportRequest(
        assetId: assetId,
        loadSource: () async => SimpleVideoImportSource(
          file: file,
          filename: '$assetId.mp4',
          mimeType: 'video/mp4',
          timestampMs: 1234,
          width: 1920,
          height: 1080,
          durationMs: 5000,
        ),
      );
    }

    test('persists and verifies the vault item before original deletion',
        () async {
      final bytes = Uint8List.fromList(
        List<int>.generate(256 * 1024, (i) => (i * 13) & 0xFF),
      );
      final source = File('${rootTmp.path}/asset-a.mp4');
      await source.writeAsBytes(bytes);
      var deletionCalled = false;

      final result = await SimpleVideoImportService(vault).importAndDelete(
        removeOriginals: true,
        requests: <SimpleVideoImportRequest>[
          requestFor(assetId: 'asset-a', file: source),
        ],
        deleteOriginals: (assetIds) async {
          deletionCalled = true;
          expect(assetIds, <String>['asset-a']);

          // A new service can reload and decrypt the item immediately. This is
          // the durability boundary required before deleting from Photos.
          final reloaded = VaultService(EncryptionService());
          await reloaded.initialize(masterKey: masterKey);
          final stored = reloaded.items.single;
          expect(stored.metadata?['sourceAssetId'], 'asset-a');
          expect(await reloaded.getFileData(stored.id), bytes);
          await reloaded.clearDecryptedCache();
          reloaded.dispose();
          return assetIds;
        },
      );

      expect(deletionCalled, isTrue);
      expect(result.storedCount, 1);
      expect(result.deletedCount, 1);
      expect(result.failedCount, 0);
    });

    test('failed stores preserve originals and mixed batches delete successes',
        () async {
      final good = File('${rootTmp.path}/good.mp4');
      await good.writeAsBytes(Uint8List.fromList(List<int>.filled(8192, 7)));
      final missing = File('${rootTmp.path}/missing.mp4');
      List<String>? deletionRequest;

      final result = await SimpleVideoImportService(vault).importAndDelete(
        removeOriginals: true,
        requests: <SimpleVideoImportRequest>[
          requestFor(assetId: 'good', file: good),
          requestFor(assetId: 'missing', file: missing),
        ],
        deleteOriginals: (assetIds) async {
          deletionRequest = List<String>.from(assetIds);
          return assetIds;
        },
      );

      expect(result.storedCount, 1);
      expect(result.failedCount, 1);
      expect(deletionRequest, <String>['good']);
      expect(result.deletedAssetIds, <String>{'good'});
    });

    test('declined Photos deletion keeps the committed vault item', () async {
      final source = File('${rootTmp.path}/retained.mp4');
      await source.writeAsBytes(Uint8List.fromList(List<int>.filled(4096, 3)));

      final result = await SimpleVideoImportService(vault).importAndDelete(
        removeOriginals: true,
        requests: <SimpleVideoImportRequest>[
          requestFor(assetId: 'retained', file: source),
        ],
        deleteOriginals: (_) async => <String>[],
      );

      expect(result.storedCount, 1);
      expect(result.deletedCount, 0);
      expect(result.retainedOriginalCount, 1);
      expect(vault.items, hasLength(1));
    });

    test(
        'index commit failure rolls back the vault copy and preserves original',
        () async {
      final source = File('${rootTmp.path}/commit-failure.mp4');
      await source.writeAsBytes(Uint8List.fromList(List<int>.filled(4096, 9)));
      await Directory('${rootTmp.path}/vault/index').delete(recursive: true);
      var deletionCalled = false;

      final result = await SimpleVideoImportService(vault).importAndDelete(
        removeOriginals: true,
        requests: <SimpleVideoImportRequest>[
          requestFor(assetId: 'commit-failure', file: source),
        ],
        deleteOriginals: (ids) async {
          deletionCalled = true;
          return ids;
        },
      );

      expect(result.storedCount, 0);
      expect(result.failedCount, 1);
      expect(deletionCalled, isFalse);
      expect(vault.items, isEmpty);
      expect(await source.exists(), isTrue);
      final orphanedPayloads = await Directory('${rootTmp.path}/vault')
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.mp4'))
          .toList();
      expect(orphanedPayloads, isEmpty);
    });

    test('auto preference backs up only after the local video batch completes',
        () async {
      await vault.setICloudBackupDirectoryForTesting(iCloudTmp);
      final source = File('${rootTmp.path}/automatic-cloud.mp4');
      await source.writeAsBytes(
        Uint8List.fromList(List<int>.generate(32 * 1024, (i) => i % 251)),
      );
      var cloudWasEmptyDuringDeletion = false;

      final result = await SimpleVideoImportService(vault).importAndDelete(
        removeOriginals: true,
        requests: <SimpleVideoImportRequest>[
          requestFor(assetId: 'automatic-cloud', file: source),
        ],
        deleteOriginals: (ids) async {
          cloudWasEmptyDuringDeletion = await iCloudTmp.list().isEmpty;
          return ids;
        },
      );

      expect(result.storedCount, 1);
      expect(result.deletedCount, 1);
      expect(cloudWasEmptyDuringDeletion, isTrue,
          reason: 'iCloud must not overlap the sequential import transaction');

      await vault.waitForICloudSyncIdle();
      final item = result.storedItems.single;
      final local = _vaultFile(item);
      final cloud = File('${iCloudTmp.path}/${item.vaultRelativePath}');
      expect(await cloud.exists(), isTrue);
      expect(await cloud.readAsBytes(), await local.readAsBytes());
      expect(await VaultCipher.looksEncrypted(cloud), isTrue);
    });

    test('local-only preference never schedules automatic video backup',
        () async {
      await vault.setStoragePreference(false);
      // Keep a stale directory installed to prove the preference is the gate.
      await vault.setICloudBackupDirectoryForTesting(iCloudTmp);
      final source = File('${rootTmp.path}/local-only.mp4');
      await source.writeAsBytes(Uint8List.fromList(List<int>.filled(4096, 4)));

      final result = await SimpleVideoImportService(vault).importAndDelete(
        removeOriginals: true,
        requests: <SimpleVideoImportRequest>[
          requestFor(assetId: 'local-only', file: source),
        ],
        deleteOriginals: (ids) async => ids,
      );
      await vault.waitForICloudSyncIdle();

      final item = result.storedItems.single;
      expect(
        await File('${iCloudTmp.path}/${item.vaultRelativePath}').exists(),
        isFalse,
      );
      expect(vault.pendingICloudBackupCount, 0);
    });

    test('late iCloud availability reconciles an already committed video',
        () async {
      final source = File('${rootTmp.path}/late-cloud.mp4');
      await source.writeAsBytes(Uint8List.fromList(List<int>.filled(4096, 8)));

      final result = await SimpleVideoImportService(vault).importAndDelete(
        removeOriginals: true,
        requests: <SimpleVideoImportRequest>[
          requestFor(assetId: 'late-cloud', file: source),
        ],
        deleteOriginals: (ids) async => ids,
      );
      final item = result.storedItems.single;

      expect(
        await File('${iCloudTmp.path}/${item.vaultRelativePath}').exists(),
        isFalse,
      );

      // Successful container initialization queues the complete current index,
      // recovering imports committed before the directory became available.
      await vault.setICloudBackupDirectoryForTesting(iCloudTmp);
      await vault.waitForICloudSyncIdle();
      expect(
        await File('${iCloudTmp.path}/${item.vaultRelativePath}').exists(),
        isTrue,
      );
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
        existingItems =
            List<dynamic>.from((parsed['items'] as List<dynamic>? ?? []));
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

  group('iCloud backfill', () {
    setUp(() async {
      // These cases exercise the explicit full-reconciliation API. Keep its
      // fixtures isolated from the automatic per-item queue tested above.
      await vault.setStoragePreference(false);
    });

    test('syncs using vaultRelativePath and writes ciphertext', () async {
      await vault.setICloudBackupDirectoryForTesting(iCloudTmp);

      final pt = Uint8List.fromList('icloud secret photo'.codeUnits);
      final item = await vault.storeFile(data: pt, filename: 'secret.jpg');
      final result = await vault.runICloudEncryptionBackfill();

      final backupFile = File('${iCloudTmp.path}/${item.vaultRelativePath}');
      expect(await backupFile.exists(), isTrue);
      final backupBytes = await backupFile.readAsBytes();
      expect(backupBytes[0], VaultCipher.versionByte);
      expect(backupBytes, isNot(equals(pt)));
      expect(await File('${iCloudTmp.path}/${item.id}').exists(), isFalse);
      expect(result.cloudFilesWritten, greaterThanOrEqualTo(1));
    });

    test('path-imported videos are ciphertext locally and in iCloud', () async {
      await vault.setICloudBackupDirectoryForTesting(iCloudTmp);

      final source = File('${rootTmp.path}/source-video.mp4');
      final pt = Uint8List.fromList(<int>[
        0x00,
        0x00,
        0x00,
        0x18,
        0x66,
        0x74,
        0x79,
        0x70,
        ...List<int>.generate(4096, (i) => i % 251),
      ]);
      await source.writeAsBytes(pt);

      final item = await vault.storeFileFromPath(
        sourceFilePath: source.path,
        filename: 'source-video.mp4',
        mimeType: 'video/mp4',
        queueThumbnailGeneration: false,
      );
      final localBytes = await _vaultFile(item).readAsBytes();
      expect(localBytes[0], VaultCipher.versionByte);
      expect(localBytes, isNot(equals(pt)));

      await vault.runICloudEncryptionBackfill();

      final backupFile = File('${iCloudTmp.path}/${item.vaultRelativePath}');
      expect(await backupFile.exists(), isTrue);
      final backupBytes = await backupFile.readAsBytes();
      expect(backupBytes[0], VaultCipher.versionByte);
      expect(backupBytes, isNot(equals(pt)));
      expect(
        await File('${iCloudTmp.path}/source-video.mp4').exists(),
        isFalse,
      );
    });

    test('encrypts cloud-only legacy plaintext video backup', () async {
      await vault.setICloudBackupDirectoryForTesting(iCloudTmp);

      final source = File('${rootTmp.path}/legacy-video.mp4');
      final pt = Uint8List.fromList(<int>[
        0x00,
        0x00,
        0x00,
        0x18,
        0x66,
        0x74,
        0x79,
        0x70,
        ...List<int>.generate(8192, (i) => (i * 7) % 251),
      ]);
      await source.writeAsBytes(pt);

      final item = await vault.storeFileFromPath(
        sourceFilePath: source.path,
        filename: 'legacy-video.mp4',
        mimeType: 'video/mp4',
        queueThumbnailGeneration: false,
      );
      final localVaultFile = _vaultFile(item);
      expect(await localVaultFile.exists(), isTrue);
      await localVaultFile.delete();

      final cloudPlaintext =
          File('${iCloudTmp.path}/${item.vaultRelativePath}');
      await cloudPlaintext.writeAsBytes(pt);

      final result = await vault.runICloudEncryptionBackfill();

      expect(result.skippedMissingLocalFiles, 0);
      expect(await localVaultFile.exists(), isTrue);
      final restoredLocalBytes = await localVaultFile.readAsBytes();
      expect(restoredLocalBytes[0], VaultCipher.versionByte);
      expect(restoredLocalBytes, isNot(equals(pt)));

      expect(await cloudPlaintext.exists(), isTrue);
      final cloudBytes = await cloudPlaintext.readAsBytes();
      expect(cloudBytes[0], VaultCipher.versionByte);
      expect(cloudBytes, isNot(equals(pt)));
    });

    test('reports one-file-at-a-time progress', () async {
      await vault.setICloudBackupDirectoryForTesting(iCloudTmp);

      await vault.storeFile(
        data: Uint8List.fromList('first'.codeUnits),
        filename: 'first.txt',
      );
      await vault.storeFile(
        data: Uint8List.fromList('second'.codeUnits),
        filename: 'second.txt',
      );

      final progress = <ICloudBackfillProgress>[];
      await vault.runICloudEncryptionBackfill(
        interFileDelay: Duration.zero,
        onProgress: progress.add,
      );

      final syncingSteps =
          progress.where((step) => step.phase == 'Syncing').toList();
      final completedSteps =
          progress.where((step) => step.phase == 'Backfilled').toList();

      expect(syncingSteps.map((step) => step.current), [1, 2]);
      expect(completedSteps.map((step) => step.current), [1, 2]);
      expect(progress.last.phase, 'Cleaning iCloud backup');
    });

    test('overwrites newer plaintext backup and deletes legacy id copy',
        () async {
      await vault.setICloudBackupDirectoryForTesting(iCloudTmp);

      final pt = Uint8List.fromList('legacy cloud plaintext'.codeUnits);
      final item = await vault.storeFile(data: pt, filename: 'legacy.pdf');
      final canonicalBackup =
          File('${iCloudTmp.path}/${item.vaultRelativePath}');
      final legacyBackup = File('${iCloudTmp.path}/${item.id}');

      await canonicalBackup.writeAsBytes(pt);
      await canonicalBackup
          .setLastModified(DateTime.now().add(const Duration(days: 1)));
      await legacyBackup.writeAsBytes(pt);

      await vault.runICloudEncryptionBackfill();

      final backupBytes = await canonicalBackup.readAsBytes();
      expect(backupBytes[0], VaultCipher.versionByte);
      expect(backupBytes, isNot(equals(pt)));
      expect(await legacyBackup.exists(), isFalse);
    });

    test('deletes unknown plaintext files but keeps encrypted orphans',
        () async {
      await vault.setICloudBackupDirectoryForTesting(iCloudTmp);

      final known = await vault.storeFile(
        data: Uint8List.fromList('known'.codeUnits),
        filename: 'known.bin',
      );
      final unknownPlaintext = File('${iCloudTmp.path}/loose.jpg');
      await unknownPlaintext.writeAsBytes(
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
      );

      final encryptedOrphan = File('${iCloudTmp.path}/orphan.nyx');
      final orphanBytes = VaultCipher(EncryptionService()).encryptBytes(
        masterKey: masterKey,
        fileId: 'orphan',
        plaintext: Uint8List.fromList('orphan'.codeUnits),
      );
      await encryptedOrphan.writeAsBytes(orphanBytes);

      final result = await vault.runICloudEncryptionBackfill();

      expect(
          await File('${iCloudTmp.path}/${known.vaultRelativePath}').exists(),
          isTrue);
      expect(await unknownPlaintext.exists(), isFalse);
      expect(await encryptedOrphan.exists(), isTrue);
      expect(result.deletedPlaintextCloudFiles, 1);
    });
  });

  group('import safety defaults', () {
    SimpleVideoImportRequest requestFor({
      required String assetId,
      required File file,
    }) {
      return SimpleVideoImportRequest(
        assetId: assetId,
        loadSource: () async => SimpleVideoImportSource(
          file: file,
          filename: '$assetId.mp4',
          mimeType: 'video/mp4',
          timestampMs: 1234,
          width: 1920,
          height: 1080,
          durationMs: 5000,
        ),
      );
    }

    test('originals are NOT deleted unless explicitly opted in', () async {
      final source = File('${rootTmp.path}/keep_original.mp4');
      await source.writeAsBytes(Uint8List.fromList(List<int>.filled(4096, 9)));
      var deletionCalled = false;

      final result = await SimpleVideoImportService(vault).importAndDelete(
        requests: <SimpleVideoImportRequest>[
          requestFor(assetId: 'keep-me', file: source),
        ],
        deleteOriginals: (assetIds) async {
          deletionCalled = true;
          return assetIds;
        },
        // removeOriginals intentionally omitted — the default must be safe.
      );

      expect(result.storedCount, 1, reason: 'the video must still import');
      expect(deletionCalled, isFalse,
          reason: 'deleting the user\'s originals must be opt-in');
      expect(result.deletedCount, 0);
    });

    test('cancellation stops the batch but keeps committed items', () async {
      final files = <File>[];
      for (var i = 0; i < 4; i++) {
        final f = File('${rootTmp.path}/cancel_$i.mp4');
        await f.writeAsBytes(Uint8List.fromList(List<int>.filled(2048, i)));
        files.add(f);
      }

      final token = ImportCancellationToken();
      // Cancel as soon as the first item reports progress.
      final result = await SimpleVideoImportService(vault).importAndDelete(
        requests: <SimpleVideoImportRequest>[
          for (var i = 0; i < files.length; i++)
            requestFor(assetId: 'cancel-$i', file: files[i]),
        ],
        deleteOriginals: (assetIds) async => assetIds,
        cancellationToken: token,
        onProgress: (current, total, status) => token.cancel(),
      );

      expect(result.wasCancelled, isTrue,
          reason: 'batch must report cancelled');
      expect(result.storedCount, 1,
          reason: 'the in-flight item completes; the rest are skipped');
      expect(result.skippedCount, files.length - 1);

      // The committed item must be durable, not rolled back.
      final reopened = VaultService(EncryptionService());
      await reopened.initialize(masterKey: masterKey);
      expect(reopened.items, hasLength(1),
          reason: 'a cancelled batch must not discard committed work');
      await reopened.clearDecryptedCache();
      reopened.dispose();
    });
  });
}

// Guards against the "vault empties itself" failure mode.
//
// _loadIndex used to call _items.clear() in its catch block. Any transient
// decrypt/parse failure therefore produced an empty in-memory vault, and the
// next debounced save wrote that empty list over items.json — converting a
// recoverable read error into permanent loss of every item, imported videos
// included. The index must survive a failed load.
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
import 'package:nyx/core/services/vault_service.dart';

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
  late Uint8List masterKey;

  setUp(() async {
    rootTmp = await Directory.systemTemp.createTemp('nyx_idxguard_docs_');
    decryptTmp = await Directory.systemTemp.createTemp('nyx_idxguard_tmp_');
    PathProviderPlatform.instance =
        _FakePaths(docs: rootTmp.path, tmp: decryptTmp.path);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.angelonartey.nyx/icloud'),
      (_) async => null,
    );
    masterKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 5));
  });

  tearDown(() async {
    for (final d in [rootTmp, decryptTmp]) {
      try {
        await d.delete(recursive: true);
      } catch (_) {}
    }
  });

  File indexFile() => File('${rootTmp.path}/vault/index/items.json');

  test('a corrupt index is never overwritten with an empty one', () async {
    // 1. Create a vault with a real item.
    final vault = VaultService(EncryptionService());
    await vault.initialize(masterKey: masterKey);

    final source = File('${decryptTmp.path}/photo.bin');
    await source.writeAsBytes(Uint8List.fromList(List<int>.filled(2048, 7)));
    await vault.storeFileFromPath(
      sourceFilePath: source.path,
      filename: 'photo.bin',
      mimeType: 'application/octet-stream',
      source: VaultItemSource.import,
      persistImmediately: true,
      queueICloudBackup: false,
    );
    expect(vault.items, hasLength(1));

    final index = indexFile();
    expect(await index.exists(), isTrue);
    final goodBytes = await index.readAsBytes();
    expect(goodBytes, isNotEmpty);

    // 2. Corrupt it in a way that survives the version sniff but fails to
    //    authenticate — exactly what a partial write or bad key looks like.
    final corrupt = Uint8List.fromList(goodBytes);
    corrupt[corrupt.length - 5] ^= 0xFF;
    await index.writeAsBytes(corrupt);

    // 3. Reopen. The load fails.
    final reopened = VaultService(EncryptionService());
    await reopened.initialize(masterKey: masterKey);

    // 4. Force save attempts, which is what the debounced timer would do.
    await reopened.saveIndex(immediate: true);

    // 5. The on-disk index must be untouched — not replaced by an empty one.
    final afterBytes = await index.readAsBytes();
    expect(afterBytes, equals(corrupt),
        reason: 'a failed load must not let a save overwrite the index');

    // And the file must still not be a valid-but-empty index.
    final looksEmptied = () {
      try {
        final decoded =
            jsonDecode(utf8.decode(afterBytes)) as Map<String, dynamic>;
        return (decoded['items'] as List<dynamic>).isEmpty;
      } catch (_) {
        return false;
      }
    }();
    expect(looksEmptied, isFalse,
        reason: 'index must not have been rewritten as an empty item list');
  });

  test('a healthy index still saves normally', () async {
    final vault = VaultService(EncryptionService());
    await vault.initialize(masterKey: masterKey);

    final source = File('${decryptTmp.path}/ok.bin');
    await source.writeAsBytes(Uint8List.fromList(List<int>.filled(512, 3)));
    await vault.storeFileFromPath(
      sourceFilePath: source.path,
      filename: 'ok.bin',
      source: VaultItemSource.import,
      persistImmediately: true,
      queueICloudBackup: false,
    );

    final reopened = VaultService(EncryptionService());
    await reopened.initialize(masterKey: masterKey);
    expect(reopened.items, hasLength(1),
        reason: 'a healthy index must load normally');

    await reopened.saveIndex(immediate: true);

    final again = VaultService(EncryptionService());
    await again.initialize(masterKey: masterKey);
    expect(again.items, hasLength(1),
        reason: 'saving after a healthy load must preserve items');
  });

  test('concurrent index saves never lose items or leave temp debris',
      () async {
    final vault = VaultService(EncryptionService());
    await vault.initialize(masterKey: masterKey);

    // Interleave immediate (throwOnError) saves with debounced ones, which is
    // exactly the shape that used to race: the video import path forces an
    // immediate save while a debounced timer save is already in flight.
    const itemCount = 12;
    for (var i = 0; i < itemCount; i++) {
      final source = File('${decryptTmp.path}/concurrent_$i.bin');
      await source
          .writeAsBytes(Uint8List.fromList(List<int>.filled(256, i & 0xFF)));

      final stores = <Future<void>>[
        vault.storeFileFromPath(
          sourceFilePath: source.path,
          filename: 'concurrent_$i.bin',
          source: VaultItemSource.import,
          persistImmediately: true,
          deduplicate: false,
          queueICloudBackup: false,
        ),
        // Pile on extra saves racing the store above.
        vault.saveIndex(immediate: true),
        vault.saveIndex(immediate: true),
      ];
      await Future.wait(stores);
    }

    expect(vault.items, hasLength(itemCount),
        reason: 'every item must be in memory');

    // Everything must survive a reload from disk.
    final reopened = VaultService(EncryptionService());
    await reopened.initialize(masterKey: masterKey);
    expect(reopened.items, hasLength(itemCount),
        reason:
            'concurrent saves must not drop items from the persisted index');

    // Every payload the index references must still exist — the race used to
    // roll back and delete a just-written payload.
    for (final item in reopened.items) {
      final payload =
          File('${rootTmp.path}/vault/${item.vaultRelativePath ?? item.id}');
      expect(await payload.exists(), isTrue,
          reason: 'payload for ${item.originalFilename} must not be deleted');
    }

    // No orphaned temp files left behind.
    final indexDir = Directory('${rootTmp.path}/vault/index');
    final debris = indexDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp'))
        .toList();
    expect(debris, isEmpty,
        reason: 'no .tmp debris: ${debris.map((f) => f.path)}');
  });

  test('a failed import leaves no payload and no .partial debris', () async {
    final vault = VaultService(EncryptionService());
    await vault.initialize(masterKey: masterKey);

    // A source that disappears mid-import: create it, then delete it so the
    // encrypt step fails partway. storeFileFromPath must leave the vault clean.
    final ghost = File('${decryptTmp.path}/ghost.mp4');
    await ghost.writeAsBytes(Uint8List.fromList(List<int>.filled(4096, 1)));

    // Sanity: a good import works.
    await vault.storeFileFromPath(
      sourceFilePath: ghost.path,
      filename: 'good.mp4',
      mimeType: 'video/mp4',
      source: VaultItemSource.import,
      persistImmediately: true,
      deduplicate: false,
      queueICloudBackup: false,
    );
    expect(vault.items, hasLength(1));

    // Now a genuinely failing import.
    final missing = File('${decryptTmp.path}/does_not_exist.mp4');
    await expectLater(
      vault.storeFileFromPath(
        sourceFilePath: missing.path,
        filename: 'missing.mp4',
        mimeType: 'video/mp4',
        source: VaultItemSource.import,
        persistImmediately: true,
        deduplicate: false,
        queueICloudBackup: false,
      ),
      throwsA(anything),
    );

    expect(vault.items, hasLength(1),
        reason: 'a failed import must not add an item');

    // No .partial staging files anywhere in the vault directory.
    final vaultDir = Directory('${rootTmp.path}/vault');
    final debris = vaultDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.partial'))
        .toList();
    expect(debris, isEmpty,
        reason: 'no .partial debris: ${debris.map((f) => f.path)}');
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nyx/core/models/vault_item.dart';
import 'package:nyx/core/services/encryption_service.dart';
import 'package:nyx/core/services/vault_cipher.dart';
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

/// Duplicate finder on encrypted items, through the Dart cipher (the native
/// CryptoKit path is covered by integration_test/native_crypto_stream_test).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory tmp;
  late VaultService vault;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nyx_dup_test_');
    tmp = await Directory.systemTemp.createTemp('nyx_dup_tmp_');
    PathProviderPlatform.instance = _FakePaths(docs: root.path, tmp: tmp.path);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.angelonartey.nyx/icloud'),
      (_) async => null,
    );
    vault = VaultService(EncryptionService());
    await vault.initialize(
        masterKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 7)));
  });

  tearDown(() async {
    await vault.clearDecryptedCache();
    for (final d in [root, tmp]) {
      try {
        await d.delete(recursive: true);
      } catch (_) {}
    }
  });

  Future<VaultItem> add(String name, List<int> bytes) async {
    final src = File('${tmp.path}/src_$name');
    await src.writeAsBytes(bytes);
    // Imports never dedup videos and older encrypted items carry no digest;
    // deduplicate: false reproduces both.
    final item = await vault.storeFileFromPath(
      sourceFilePath: src.path,
      filename: name,
      mimeType: 'video/mp4',
      queueThumbnailGeneration: false,
      deduplicate: false,
      queueICloudBackup: false,
      persistImmediately: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return item;
  }

  test('finds identical encrypted files, keeps the oldest, ignores look-alikes',
      () async {
    // Spans two cipher chunks so the chunked hash is exercised.
    final a = List<int>.generate(VaultCipher.chunkPlaintextSize + 777, (i) => i % 251);
    final sameSizeOther = List<int>.from(a)..[a.length - 1] ^= 1;
    final first = await add('a1.mp4', a);
    final second = await add('a2.mp4', a);
    final lookAlike = await add('other.mp4', sameSizeOther);
    final third = await add('a3.mp4', a);
    await add('unique.mp4', List<int>.filled(10, 3));
    expect(first.isEncrypted, isTrue);
    expect(first.metadata?['sha256'], isNull,
        reason: 'fixture must start without a cached digest');

    var lastProgress = (-1, -1);
    final groups = await vault.findDuplicateGroups(
        onProgress: (d, t) => lastProgress = (d, t));

    expect(groups, hasLength(1));
    expect(groups.single.items.map((i) => i.id),
        [first.id, second.id, third.id]);
    expect(groups.single.sha256Digest, sha256.convert(a).toString());
    expect(groups.single.wastedBytes, 2 * a.length);
    expect(lastProgress, (4, 4), reason: 'only same-size files are hashed');
    expect(
        vault.items.firstWhere((i) => i.id == lookAlike.id).metadata?['sha256'],
        sha256.convert(sameSizeOther).toString(),
        reason: 'digests are cached for the next scan');

    // A copy's folder and album move to the kept file when the copy goes.
    final folder = await vault.createFolder('Trips');
    final album = await vault.createAlbum('Best');
    await vault.addItemToFolder(third.id, folder.id);
    await vault.addItemToAlbum(second.id, album.id);
    for (final extra in groups.single.items.skip(1)) {
      expect(await vault.deleteDuplicateCopy(extra.id, keptId: first.id),
          isTrue);
    }
    expect(vault.folders.firstWhere((f) => f.id == folder.id).itemIds,
        [first.id]);
    expect(vault.albums.firstWhere((a) => a.id == album.id).itemIds,
        [first.id]);
    expect(await vault.deleteDuplicateCopy(first.id, keptId: first.id),
        isFalse,
        reason: 'the kept file is never deleted as its own copy');
    expect(await vault.findDuplicateGroups(), isEmpty);
    expect(vault.items.any((i) => i.id == first.id), isTrue);
  });

  test('a damaged file is skipped, not matched and not fatal', () async {
    final bytes = List<int>.generate(4000, (i) => i % 7);
    final good1 = await add('g1.bin', bytes);
    final good2 = await add('g2.bin', bytes);
    final bad = await add('bad.bin', bytes);
    final path = '${root.path}/vault/${bad.vaultRelativePath ?? bad.id}';
    final raw = await File(path).readAsBytes();
    raw[20] ^= 0xff;
    await File(path).writeAsBytes(raw);

    final groups = await vault.findDuplicateGroups();
    expect(groups, hasLength(1));
    expect(groups.single.items.map((i) => i.id), [good1.id, good2.id]);
  });
}

// Real-video end-to-end import test.
//
// Drives an actual 28 MB h264/aac 1080x1920 clip through the SAME call the
// production video-import path makes (SimpleVideoImportService ->
// VaultService.storeFileFromPath with queueThumbnailGeneration: false), then
// asserts the item is stored, encrypted at rest, byte-exact on decrypt, and
// — the point of the test — that it ends up with a poster thumbnail.
//
// Set NYX_TEST_VIDEO to point at a different clip.
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

  // A real ~28 MB h264/aac clip. Kept out of git (see .gitignore); regenerate
  // with:
  //   ffmpeg -y -f lavfi -i "color=c=gray:s=1080x1920:d=20:r=30" \
  //     -f lavfi -i "sine=frequency=440:duration=20" \
  //     -vf "noise=alls=80:allf=t+u" -c:v libx264 -preset ultrafast \
  //     -b:v 11500k -maxrate 12M -bufsize 24M -pix_fmt yuv420p -c:a aac \
  //     -shortest .test_media/sample_video.mp4
  // Noise is deliberate: a compressible source would not exercise the cipher
  // with a realistic byte count.
  final videoPath =
      Platform.environment['NYX_TEST_VIDEO'] ?? '.test_media/sample_video.mp4';
  final hasFixture = File(videoPath).existsSync();
  final skipReason = hasFixture
      ? null
      : 'missing test video at $videoPath — see the comment above to generate it';

  late Directory rootTmp;
  late Directory decryptTmp;
  late VaultService vault;
  late Uint8List masterKey;
  String? posterRequestedFor;

  setUp(() async {
    rootTmp = await Directory.systemTemp.createTemp('nyx_realvid_docs_');
    decryptTmp = await Directory.systemTemp.createTemp('nyx_realvid_tmp_');

    PathProviderPlatform.instance =
        _FakePaths(docs: rootTmp.path, tmp: decryptTmp.path);
    SharedPreferences.setMockInitialValues({});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.angelonartey.nyx/icloud'),
      (_) async => null,
    );

    // video_thumbnail is a platform plugin with no headless implementation.
    // Stand in for the native extractor so the *wiring* can be verified: which
    // path the poster is generated from, and whether it reaches the item.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.justsoft.xyz/video_thumbnail'),
      (call) async {
        posterRequestedFor = call.arguments['video'] as String?;
        // Minimal valid JPEG header + payload.
        return Uint8List.fromList(
            <int>[0xFF, 0xD8, 0xFF, 0xE0, ...List<int>.filled(64, 0x20)]);
      },
    );

    masterKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    vault = VaultService(EncryptionService());
    await vault.initialize(masterKey: masterKey);
  });

  tearDown(() async {
    await vault.clearDecryptedCache();
    for (final d in [rootTmp, decryptTmp]) {
      try {
        await d.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('real video imports, encrypts at rest, and decrypts byte-exact',
      () async {
    final sw = Stopwatch()..start();
    final src = File(videoPath);
    expect(await src.exists(), isTrue,
        reason: 'test video missing at $videoPath');

    final original = await src.readAsBytes();
    final staged = File('${decryptTmp.path}/import_source.mp4');
    await staged.writeAsBytes(original);

    // Exactly what SimpleVideoImportService.importAndDelete() calls.
    final item = await vault.storeFileFromPath(
      sourceFilePath: staged.path,
      filename: 'Night-Crawlers-All-White-30s.mp4',
      mimeType: 'video/mp4',
      source: VaultItemSource.import,
      metadata: const {'durationMs': 30000, 'width': 1080, 'height': 1920},
      queueThumbnailGeneration: false,
      deduplicate: false,
      queueICloudBackup: false,
      persistImmediately: true,
    );

    final encryptMs = sw.elapsedMilliseconds;
    final mib = original.length / (1024 * 1024);
    // ignore: avoid_print
    print('>>> ENCRYPT+STORE: ${mib.toStringAsFixed(1)} MiB in ${encryptMs}ms '
        '=> ${(mib / (encryptMs / 1000)).toStringAsFixed(2)} MiB/s');

    // Regression guard: the encrypt-at-rest change routes every imported byte
    // through pure-Dart PointyCastle AES-GCM, measured at <1 MiB/s. This
    // assertion is intentionally RED until the cipher is backed by platform
    // AES (CryptoKit / javax.crypto). 5 MiB/s is still conservative.
    final throughput = mib / (encryptMs / 1000);
    expect(throughput, greaterThan(5.0),
        reason: 'video import throughput is ${throughput.toStringAsFixed(2)} '
            'MiB/s; a 500 MB phone video would take '
            '${(500 / throughput / 60).toStringAsFixed(1)} minutes');

    // 1. Classified as video.
    expect(item.type, VaultItemType.video, reason: 'must classify as video');

    // 2. Encrypted at rest.
    final onDisk =
        File('${rootTmp.path}/vault/${item.vaultRelativePath ?? item.id}');
    expect(await onDisk.exists(), isTrue, reason: 'vault file must exist');
    expect(await VaultCipher.looksEncrypted(onDisk), isTrue,
        reason: 'video must be encrypted at rest');

    // 3. Round-trips byte-exact through the playback path.
    final playbackPath = await vault.getDecryptedFilePath(item.id);
    expect(playbackPath, isNotNull, reason: 'playback decrypt must succeed');
    final decrypted = await File(playbackPath!).readAsBytes();
    expect(decrypted.length, original.length, reason: 'size must match');
    expect(decrypted, equals(original), reason: 'bytes must match exactly');

    // 4. Survives a reload from the persisted index.
    final reloaded = VaultService(EncryptionService());
    await reloaded.initialize(masterKey: masterKey);
    expect(reloaded.items.any((i) => i.id == item.id), isTrue,
        reason: 'video must survive index reload');
  }, timeout: const Timeout(Duration(minutes: 10)), skip: skipReason);

  test('imported video gets a poster, extracted from the plaintext source',
      () async {
    final src = File(videoPath);
    expect(await src.exists(), isTrue);

    final staged = File('${decryptTmp.path}/poster_source.mp4');
    await staged.writeAsBytes(await src.readAsBytes());

    // Same flags the production video path uses, including the
    // queueThumbnailGeneration: false that used to leave videos poster-less.
    final item = await vault.storeFileFromPath(
      sourceFilePath: staged.path,
      filename: 'poster-check.mp4',
      mimeType: 'video/mp4',
      source: VaultItemSource.import,
      queueThumbnailGeneration: false,
      deduplicate: false,
      queueICloudBackup: false,
      persistImmediately: true,
    );

    final stored = vault.items.firstWhere((i) => i.id == item.id);
    expect(stored.effectiveThumbnailPath, isNotNull,
        reason: 'imported video must have a poster');

    // Resolve exactly the way the grid does (stored path is vault-relative).
    final resolved = vault.getThumbnailPathForItem(stored);
    expect(resolved, isNotNull, reason: 'grid must resolve a poster path');
    expect(await File(resolved!).exists(), isTrue,
        reason: 'poster file must be on disk');

    // The poster must come from the plaintext source, not from a full decrypt
    // of the just-written ciphertext.
    expect(posterRequestedFor, staged.path,
        reason: 'poster must be extracted from the plaintext source file');
  }, timeout: const Timeout(Duration(minutes: 5)), skip: skipReason);

  test('imported photo also gets a thumbnail from the plaintext source',
      () async {
    // Photos go through the same import flow as videos and therefore also pass
    // queueThumbnailGeneration: false. They must still end up with a thumbnail,
    // otherwise the grid shows a blank placeholder that reads as a failure.
    final png = Uint8List.fromList(<int>[
      // 1x1 red PNG
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
      0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
      0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
      0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
      0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
      0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);
    final staged = File('${decryptTmp.path}/photo_source.png');
    await staged.writeAsBytes(png);

    final item = await vault.storeFileFromPath(
      sourceFilePath: staged.path,
      filename: 'photo_source.png',
      mimeType: 'image/png',
      source: VaultItemSource.import,
      queueThumbnailGeneration: false,
      deduplicate: false,
      queueICloudBackup: false,
      persistImmediately: true,
    );

    expect(item.type, VaultItemType.photo, reason: 'must classify as photo');

    final stored = vault.items.firstWhere((i) => i.id == item.id);
    expect(stored.effectiveThumbnailPath, isNotNull,
        reason: 'imported photo must have a thumbnail');
    final resolved = vault.getThumbnailPathForItem(stored);
    expect(resolved, isNotNull);
    expect(await File(resolved!).exists(), isTrue,
        reason: 'photo thumbnail file must be on disk');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

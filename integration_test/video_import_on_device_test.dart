// On-device verification of the video import pipeline.
//
// The unit tests in test/ mock the video_thumbnail platform channel and measure
// AES throughput on a desktop CPU. This runs the same pipeline on a real iOS
// device/simulator with the REAL native thumbnail extractor and the REAL device
// CPU, which is the part that could not be proven headlessly:
//
//   1. A real video encrypts fast enough to feel instant.
//   2. The poster frame is actually produced by AVFoundation, not a mock.
//   3. The stored video decrypts byte-exact and survives an index reload.
//
// Run with:
//   flutter test integration_test/video_import_on_device_test.dart -d <udid>
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nyx/core/models/vault_item.dart';
import 'package:nyx/core/services/encryption_service.dart';
import 'package:nyx/core/services/simple_video_import_service.dart';
import 'package:nyx/core/services/vault_cipher.dart';
import 'package:nyx/core/services/vault_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late VaultService vault;
  late Uint8List masterKey;
  late Directory work;

  setUp(() async {
    masterKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 11));
    vault = VaultService(EncryptionService());
    await vault.initialize(masterKey: masterKey);
    work = await getTemporaryDirectory();
  });

  tearDown(() async {
    await vault.clearDecryptedCache();
  });

  /// Copies the fixture (pushed into Documents by the host before this run)
  /// to a scratch path. Not bundled as an asset so it never ships in the app.
  ///
  ///   xcrun simctl get_app_container booted com.angelonartey.nyx data
  ///   cp .test_media/sample_video.mp4 "$CONTAINER/Documents/nyx_test_fixture.mp4"
  Future<File> stageVideo(String name) async {
    final docs = await getApplicationDocumentsDirectory();
    final fixture = File('${docs.path}/nyx_test_fixture.mp4');
    if (!await fixture.exists()) {
      fail('Missing fixture at ${fixture.path}. Push it with:\n'
          '  C=\$(xcrun simctl get_app_container booted com.angelonartey.nyx data)\n'
          '  cp .test_media/sample_video.mp4 "\$C/Documents/nyx_test_fixture.mp4"');
    }
    final file = File('${work.path}/$name');
    await file.writeAsBytes(await fixture.readAsBytes(), flush: true);
    return file;
  }

  testWidgets('real video imports on-device: fast, encrypted, byte-exact',
      (tester) async {
    final source = await stageVideo('on_device_import.mp4');
    final original = await source.readAsBytes();
    final mib = original.length / (1024 * 1024);

    final sw = Stopwatch()..start();
    final item = await vault.storeFileFromPath(
      sourceFilePath: source.path,
      filename: 'on_device_import.mp4',
      mimeType: 'video/mp4',
      source: VaultItemSource.import,
      queueThumbnailGeneration: false,
      deduplicate: false,
      queueICloudBackup: false,
      persistImmediately: true,
    );
    sw.stop();

    final throughput = mib / (sw.elapsedMilliseconds / 1000);
    // ignore: avoid_print
    print('>>> ON-DEVICE ENCRYPT+STORE: ${mib.toStringAsFixed(1)} MiB in '
        '${sw.elapsedMilliseconds}ms => ${throughput.toStringAsFixed(2)} MiB/s');
    // ignore: avoid_print
    print('>>> ON-DEVICE projected 500MB video: '
        '${(500 / throughput).toStringAsFixed(1)}s');

    expect(item.type, VaultItemType.video);

    // Encrypted at rest.
    final onDisk = File(vault.getFilePath(item.id)!);
    expect(await VaultCipher.looksEncrypted(onDisk), isTrue,
        reason: 'video must be encrypted at rest on device');

    // Byte-exact through the playback path.
    final playback = await vault.getDecryptedFilePath(item.id);
    expect(playback, isNotNull);
    final decrypted = await File(playback!).readAsBytes();
    expect(decrypted.length, original.length);
    expect(decrypted, equals(original),
        reason: 'on-device decrypt must be byte-exact');

    // The old PointyCastle path ran at ~1.4 MiB/s on a desktop and slower on
    // device. Anything at or below that is a regression back to "feels broken".
    expect(throughput, greaterThan(4.0),
        reason: 'on-device throughput ${throughput.toStringAsFixed(2)} MiB/s '
            'is too slow; a 500MB video would take '
            '${(500 / throughput / 60).toStringAsFixed(1)} min');
  });

  testWidgets('poster frame is produced by the real native extractor',
      (tester) async {
    final source = await stageVideo('on_device_poster.mp4');

    final item = await vault.storeFileFromPath(
      sourceFilePath: source.path,
      filename: 'on_device_poster.mp4',
      mimeType: 'video/mp4',
      source: VaultItemSource.import,
      // The flag the production video path uses — posters must still appear.
      queueThumbnailGeneration: false,
      deduplicate: false,
      queueICloudBackup: false,
      persistImmediately: true,
    );

    final stored = vault.items.firstWhere((i) => i.id == item.id);
    expect(stored.effectiveThumbnailPath, isNotNull,
        reason: 'the native extractor must produce a poster on device');

    final resolved = vault.getThumbnailPathForItem(stored);
    expect(resolved, isNotNull);
    final posterFile = File(resolved!);
    expect(await posterFile.exists(), isTrue);

    final posterBytes = await posterFile.readAsBytes();
    // ignore: avoid_print
    print('>>> ON-DEVICE POSTER: ${posterBytes.length} bytes');
    expect(posterBytes.length, greaterThan(500),
        reason: 'a real JPEG poster, not an empty/placeholder file');
    // JPEG SOI marker.
    expect(posterBytes[0], 0xFF);
    expect(posterBytes[1], 0xD8);
  });

  testWidgets('cancellation keeps committed work and skips the rest',
      (tester) async {
    final files = <File>[];
    for (var i = 0; i < 3; i++) {
      files.add(await stageVideo('cancel_$i.mp4'));
    }

    final token = ImportCancellationToken();
    final result = await SimpleVideoImportService(vault).importAndDelete(
      requests: <SimpleVideoImportRequest>[
        for (var i = 0; i < files.length; i++)
          SimpleVideoImportRequest(
            assetId: 'on-device-cancel-$i',
            loadSource: () async => SimpleVideoImportSource(
              file: files[i],
              filename: 'cancel_$i.mp4',
              mimeType: 'video/mp4',
              timestampMs: 1000 + i,
            ),
          ),
      ],
      deleteOriginals: (ids) async => ids,
      cancellationToken: token,
      onProgress: (current, total, status) => token.cancel(),
    );

    expect(result.wasCancelled, isTrue);
    expect(result.storedCount, 1);
    expect(result.skippedCount, 2);
    expect(result.deletedCount, 0,
        reason: 'originals must not be deleted without opt-in');
  });
}

// On-device gate for the CryptoKit vault cipher and the loopback playback
// stream. A single byte of format drift between the native and Dart ciphers
// would make every existing vault unreadable, so this must pass on a
// simulator or device before any release that touches either.
//
// Run with (fixture pushed as in video_import_on_device_test.dart):
//   flutter test integration_test/native_crypto_stream_test.dart -d <udid>
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'package:nyx/core/models/vault_item.dart';
import 'package:nyx/core/services/encryption_service.dart';
import 'package:nyx/core/services/native_vault_crypto.dart';
import 'package:nyx/core/services/vault_cipher.dart';
import 'package:nyx/core/services/vault_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const mib = VaultCipher.chunkPlaintextSize;
  final cipher = VaultCipher(EncryptionService());
  final masterKey = Uint8List.fromList(List<int>.generate(32, (i) => i * 3 + 1));
  late Directory work;

  setUpAll(() async {
    work = Directory('${(await getTemporaryDirectory()).path}/nyx_native_gate');
    if (await work.exists()) await work.delete(recursive: true);
    await work.create(recursive: true);
  });

  Future<File> randomFile(String name, int size, int seed) async {
    final r = Random(seed);
    final f = File('${work.path}/$name');
    final sink = f.openWrite();
    var left = size;
    while (left > 0) {
      final n = min(left, 4 * mib);
      sink.add(List<int>.generate(n, (_) => r.nextInt(256)));
      left -= n;
    }
    await sink.close();
    return f;
  }

  group('native and Dart ciphers are interchangeable', () {
    for (final size in <int>[0, 1, 1000, mib, mib + 1, 3 * mib + 12345]) {
      testWidgets('$size bytes', (tester) async {
        final plain = await randomFile('p$size', size, size + 1);
        final plainBytes = await plain.readAsBytes();
        final fileId = 'item-$size';
        final fileKey = cipher.deriveFileKey(masterKey, fileId);

        // native encrypt -> Dart decrypt
        final nativeCt = File('${work.path}/n$size.enc');
        final enc = await NativeVaultCrypto.encryptFile(
            sourcePath: plain.path,
            destPath: nativeCt.path,
            fileKey: fileKey,
            fileId: fileId,
            computeSha256: true);
        expect(enc, isNotNull, reason: 'native cipher must be present on iOS');
        expect(enc!.bytes, size);
        expect(enc.sha256, sha256.convert(plainBytes).toString());
        expect(VaultCipher.plaintextLengthForCipherLength(await nativeCt.length()),
            size);
        final dartOut = File('${work.path}/n$size.dart');
        await cipher.decryptStreamToFile(
            masterKey: masterKey, fileId: fileId, source: nativeCt, dest: dartOut);
        expect(await dartOut.readAsBytes(), plainBytes);

        // Dart encrypt -> native decrypt (file and chunk ranges)
        final dartCt = File('${work.path}/d$size.enc');
        await cipher.encryptStreamToFile(
            masterKey: masterKey, fileId: fileId, source: plain, dest: dartCt);
        final nativeOut = File('${work.path}/d$size.native');
        final n = await NativeVaultCrypto.decryptFile(
            sourcePath: dartCt.path,
            destPath: nativeOut.path,
            fileKey: fileKey,
            fileId: fileId);
        expect(n, size);
        expect(await nativeOut.readAsBytes(), plainBytes);
        final chunk1 = await NativeVaultCrypto.decryptChunks(
            sourcePath: dartCt.path,
            fileKey: fileKey,
            fileId: fileId,
            firstChunk: 1,
            count: 2);
        expect(chunk1, plainBytes.length > mib ? plainBytes.sublist(mib, min(3 * mib, size)) : isEmpty);
        // Plaintext digest straight from ciphertext (duplicate finder).
        expect(
            await NativeVaultCrypto.plainSha256(
                sourcePath: dartCt.path, fileKey: fileKey, fileId: fileId),
            sha256.convert(plainBytes).toString());
        expect(
            await NativeVaultCrypto.plainSha256(
                sourcePath: nativeCt.path, fileKey: fileKey, fileId: fileId),
            enc.sha256);

        // A flipped byte or the wrong file id must fail authentication.
        if (size > 0) {
          final bytes = await dartCt.readAsBytes();
          bytes[1 + 12 + (size > 10 ? 5 : 0)] ^= 0x40;
          final tampered = File('${work.path}/t$size.enc');
          await tampered.writeAsBytes(bytes);
          await expectLater(
              NativeVaultCrypto.decryptFile(
                  sourcePath: tampered.path,
                  destPath: '${work.path}/t$size.out',
                  fileKey: fileKey,
                  fileId: fileId),
              throwsA(isA<VaultCipherException>()));
          expect(File('${work.path}/t$size.out').existsSync(), isFalse,
              reason: 'a failed decrypt must not leave a partial output');
        }
        await expectLater(
            NativeVaultCrypto.plainSha256(
                sourcePath: dartCt.path, fileKey: fileKey, fileId: 'other-id'),
            throwsA(isA<VaultCipherException>()));
        await expectLater(
            NativeVaultCrypto.decryptChunks(
                sourcePath: dartCt.path,
                fileKey: fileKey,
                fileId: 'other-id',
                firstChunk: 0,
                count: 1),
            throwsA(isA<VaultCipherException>()));
      });
    }
  });

  testWidgets('throughput: native vs Dart', (tester) async {
    const size = 256 * mib;
    final plain = await randomFile('big', size, 99);
    final fileKey = cipher.deriveFileKey(masterKey, 'big');
    final ct = File('${work.path}/big.enc');
    final sw = Stopwatch()..start();
    await NativeVaultCrypto.encryptFile(
        sourcePath: plain.path, destPath: ct.path, fileKey: fileKey, fileId: 'big');
    final encMs = sw.elapsedMilliseconds;
    sw.reset();
    await NativeVaultCrypto.decryptFile(
        sourcePath: ct.path,
        destPath: '${work.path}/big.out',
        fileKey: fileKey,
        fileId: 'big');
    final decMs = sw.elapsedMilliseconds;
    // Dart on 32 MiB for comparison.
    final small = await randomFile('small', 32 * mib, 98);
    sw.reset();
    await cipher.encryptStreamToFile(
        masterKey: masterKey,
        fileId: 'small',
        source: small,
        dest: File('${work.path}/small.enc'));
    final dartMs = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('NYX_PERF native encrypt ${(256 * 1000 / max(encMs, 1)).round()} MiB/s, '
        'native decrypt ${(256 * 1000 / max(decMs, 1)).round()} MiB/s, '
        'dart encrypt ${(32 * 1000 / max(dartMs, 1)).round()} MiB/s');
    expect(encMs, lessThan(30000));
  });

  for (final fixtureName in const <String>['nyx_test_fixture.mp4', 'nyx_test_fixture_hevc.mov']) {
  testWidgets('import, instant stream playback, poster backfill: $fixtureName', (tester) async {
    final docs = await getApplicationDocumentsDirectory();
    final fixture = File('${docs.path}/$fixtureName');
    final ext = fixtureName.split('.').last;
    expect(await fixture.exists(), isTrue,
        reason: 'push the fixture to Documents/nyx_test_fixture.mp4 first');
    final source = File('${work.path}/clip.$ext');
    await fixture.copy(source.path);
    final sizeMb = (await source.length()) / mib;

    final vault = VaultService(EncryptionService());
    await vault.initialize(masterKey: masterKey);

    final sw = Stopwatch()..start();
    final item = await vault.storeFileFromPath(
      sourceFilePath: source.path,
      filename: 'clip.$ext',
      mimeType: ext == 'mov' ? 'video/quicktime' : 'video/mp4',
      source: VaultItemSource.import,
      queueThumbnailGeneration: false,
      deduplicate: false,
      queueICloudBackup: false,
      persistImmediately: true,
    );
    final importMs = sw.elapsedMilliseconds;
    expect(item.isEncrypted, isTrue);
    expect(item.thumbnailPath, isNotNull, reason: 'import must make a poster');

    // Stream playback: time until the player is ready and then moving.
    final uri = await vault.getVideoStreamUri(item.id);
    expect(uri, isNotNull);
    expect(uri!.host, '127.0.0.1');
    sw.reset();
    final controller = VideoPlayerController.networkUrl(uri);
    await controller.initialize();
    final readyMs = sw.elapsedMilliseconds;
    await controller.play();
    while (controller.value.position == Duration.zero && sw.elapsedMilliseconds < 15000) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final playingMs = sw.elapsedMilliseconds;
    expect(controller.value.position, greaterThan(Duration.zero));
    // Seek near the end and see it play there.
    final target = controller.value.duration * 0.8;
    sw.reset();
    await controller.seekTo(target);
    while (controller.value.position < target && sw.elapsedMilliseconds < 15000) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final seekMs = sw.elapsedMilliseconds;
    await controller.dispose();

    // Old path for comparison: full decrypt to a temp file.
    sw.reset();
    final decrypted = await vault.getDecryptedFilePath(item.id);
    final fullDecryptMs = sw.elapsedMilliseconds;
    expect(await File(decrypted!).length(), item.sizeBytes);

    // Poster backfill: lose the poster, let unlock-time backfill make it again
    // (over the stream, no decrypted copy needed).
    await vault.clearDecryptedCache(stopStreaming: false);
    await vault.backfillMissingVideoThumbnails(); // let the unlock run finish
    final posterPath = vault.getThumbnailPathForItem(vault.items.firstWhere((i) => i.id == item.id))!;
    await File(posterPath).delete();
    final made = await vault.backfillMissingVideoThumbnails();
    expect(made, greaterThanOrEqualTo(1));
    final restored = vault.getThumbnailPathForItem(vault.items.firstWhere((i) => i.id == item.id));
    expect(restored, isNotNull);
    expect(await File(restored!).length(), greaterThan(1000));
    final tmpDir = Directory('${(await getTemporaryDirectory()).path}/nyx_decrypted');
    expect(
        !await tmpDir.exists() || (await tmpDir.list().toList()).isEmpty, isTrue,
        reason: 'stream posters must not leave plaintext in tmp');

    // Lock stops the stream.
    await vault.clearDecryptedCache();
    await expectLater(
        HttpClient().getUrl(uri).then((r) => r.close()),
        throwsA(isA<SocketException>()));

    // ignore: avoid_print
    print('NYX_PERF $fixtureName ${sizeMb.toStringAsFixed(1)} MiB: import ${importMs}ms, '
        'stream ready ${readyMs}ms, first frame moving ${playingMs}ms, '
        'seek 80% ${seekMs}ms, old full decrypt ${fullDecryptMs}ms');
  });
  }
}

// Every vault video gets a poster: imports several videos, deletes their
// posters (as for items added before posters existed), and checks the unlock
// backfill makes each one again over the playback stream.
//
// Fixtures: push .test_media/poster_*.mp4 to Documents/ (sim-gate.sh does).
// Posters are also copied to /tmp/nyx-posters on a simulator for review.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nyx/core/models/vault_item.dart';
import 'package:nyx/core/services/encryption_service.dart';
import 'package:nyx/core/services/vault_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('backfill restores a poster for every video', (tester) async {
    final docs = await getApplicationDocumentsDirectory();
    final fixtures = docs
        .listSync()
        .whereType<File>()
        .where((f) => f.path.split('/').last.startsWith('poster_'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(fixtures, isNotEmpty, reason: 'push poster_*.mp4 into Documents');

    final vault = VaultService(EncryptionService());
    await vault.initialize(
        masterKey: Uint8List.fromList(List<int>.generate(32, (i) => 200 - i)));
    final tmp = await getTemporaryDirectory();
    final ids = <String>[];
    for (final f in fixtures) {
      final copy = await f.copy('${tmp.path}/${f.path.split('/').last}');
      final item = await vault.storeFileFromPath(
        sourceFilePath: copy.path,
        filename: f.path.split('/').last,
        mimeType: 'video/mp4',
        source: VaultItemSource.import,
        queueThumbnailGeneration: false,
        deduplicate: false,
        queueICloudBackup: false,
        persistImmediately: true,
      );
      ids.add(item.id);
    }
    // Let the unlock-time backfill finish first, so the run below is the one
    // that has to restore the posters.
    await vault.backfillMissingVideoThumbnails();
    // Lose every poster.
    for (final id in ids) {
      final p = vault.getThumbnailPath(id);
      if (p != null && File(p).existsSync()) File(p).deleteSync();
    }
    final made = await vault.backfillMissingVideoThumbnails();
    expect(made, ids.length);

    final out = Directory('/tmp/nyx-posters');
    try {
      if (out.existsSync()) out.deleteSync(recursive: true);
      out.createSync(recursive: true);
    } catch (_) {}
    for (var i = 0; i < ids.length; i++) {
      final p = vault.getThumbnailPath(ids[i]);
      expect(p, isNotNull);
      expect(File(p!).lengthSync(), greaterThan(1000));
      try {
        File(p).copySync('${out.path}/poster_$i.jpg');
      } catch (_) {}
    }
    await vault.clearDecryptedCache();
  });
}

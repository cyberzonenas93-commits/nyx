// Duplicate deleter on a device: imports the same video and photo more than
// once (encrypted, no cached digests, as videos are imported), opens the
// Duplicates page, deletes the preselected copies and checks one of each stays.
//
// Fixtures: Documents/poster_*.mp4 (sim-gate.sh pushes them). Prints
// NYX_SHOT <name> where sim-gate.sh takes a simulator screenshot.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'package:nyx/app/theme.dart';
import 'package:nyx/core/models/vault_item.dart';
import 'package:nyx/core/services/encryption_service.dart';
import 'package:nyx/core/services/vault_service.dart';
import 'package:nyx/features/vault/pages/duplicates_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('finds copies, deletes the extras, keeps one of each',
      (tester) async {
    final docs = await getApplicationDocumentsDirectory();
    final tmp = await getTemporaryDirectory();
    final video = docs
        .listSync()
        .whereType<File>()
        .firstWhere((f) => RegExp(r'poster_\d+\.mp4$').hasMatch(f.path));
    final photo = File('${tmp.path}/dup_photo.jpg')
      ..writeAsBytesSync(img.encodeJpg(img.Image(width: 640, height: 480)
        ..clear(img.ColorRgb8(46, 230, 166))));

    final vault = VaultService(EncryptionService());
    await vault.initialize(
        masterKey: Uint8List.fromList(List<int>.generate(32, (i) => 90 + i)));

    Future<VaultItem> add(File f, String name, String mime) async {
      final copy = await f.copy('${tmp.path}/in_$name');
      final item = await vault.storeFileFromPath(
        sourceFilePath: copy.path,
        filename: name,
        mimeType: mime,
        source: VaultItemSource.import,
        queueThumbnailGeneration: false,
        deduplicate: false,
        queueICloudBackup: false,
        persistImmediately: true,
      );
      await vault.generateThumbnailForItem(item.id);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return item;
    }

    final v1 = await add(video, 'holiday.mp4', 'video/mp4');
    await add(video, 'holiday copy.mp4', 'video/mp4');
    await add(video, 'holiday copy 2.mp4', 'video/mp4');
    final p1 = await add(photo, 'IMG_0001.jpg', 'image/jpeg');
    await add(photo, 'IMG_0001 (1).jpg', 'image/jpeg');
    final before = vault.items.length;

    await tester.pumpWidget(ChangeNotifierProvider<VaultService>.value(
      value: vault,
      child: MaterialApp(theme: AppTheme.darkTheme, home: const DuplicatesPage()),
    ));
    final sw = Stopwatch()..start();
    while (find.byKey(const Key('duplicates_delete')).evaluate().isEmpty &&
        sw.elapsedMilliseconds < 30000) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final scanMs = sw.elapsedMilliseconds;
    await tester.pumpAndSettle();
    expect(find.textContaining('Delete 3 copies ('), findsOneWidget,
        reason: '2 extra videos + 1 extra photo are preselected');
    expect(find.text('Keep'), findsNWidgets(2));

    await tester.runAsync(() async {
      // ignore: avoid_print
      print('NYX_SHOT duplicates_found');
      await Future<void>.delayed(const Duration(seconds: 4));
    });

    // Tapping a kept copy while it is the last one must not select it.
    await tester.tap(find.text('Keep').first);
    await tester.pump();
    expect(find.text('Keep'), findsNWidgets(2));

    await tester.tap(find.byKey(const Key('duplicates_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    sw.reset();
    while (find.text('No duplicates found').evaluate().isEmpty &&
        sw.elapsedMilliseconds < 30000) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(find.text('No duplicates found'), findsOneWidget);
    expect(vault.items.length, before - 3);
    expect(vault.items.map((i) => i.id), containsAll([v1.id, p1.id]));

    await tester.runAsync(() async {
      // ignore: avoid_print
      print('NYX_SHOT duplicates_done');
      await Future<void>.delayed(const Duration(seconds: 4));
    });
    // ignore: avoid_print
    print('NYX_PERF duplicate scan of ${vault.items.length + 3} items: ${scanMs}ms');
  });
}

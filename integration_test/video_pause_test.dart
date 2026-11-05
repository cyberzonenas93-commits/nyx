// Regression: in 1.0.9 (18) pausing a vault video did not stick. Every pause
// rebuilt the detail page, whose build auto-played the video again.
//
// Fixture: Documents/nyx_test_fixture.mp4 (sim-gate.sh pushes it).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import 'package:nyx/app/theme.dart';
import 'package:nyx/core/models/vault_item.dart';
import 'package:nyx/core/services/encryption_service.dart';
import 'package:nyx/core/services/media_playback_manager.dart';
import 'package:nyx/core/services/subscription_service.dart';
import 'package:nyx/core/services/vault_service.dart';
import 'package:nyx/features/vault/pages/vault_item_detail_page.dart';
import 'package:nyx/features/vault/widgets/video_player_widget.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a paused vault video stays paused', (tester) async {
    final docs = await getApplicationDocumentsDirectory();
    final tmp = await getTemporaryDirectory();
    final fixture = File('${docs.path}/nyx_test_fixture.mp4');
    expect(fixture.existsSync(), isTrue, reason: 'push the fixture first');
    final source = await fixture.copy('${tmp.path}/pause_clip.mp4');

    // Fresh vault: earlier gate tests leave items under other keys.
    final vaultDir = Directory('${docs.path}/vault');
    if (vaultDir.existsSync()) vaultDir.deleteSync(recursive: true);
    final vault = VaultService(EncryptionService());
    await vault.initialize(
        masterKey: Uint8List.fromList(List<int>.generate(32, (i) => 3 * i)));
    final item = await vault.storeFileFromPath(
      sourceFilePath: source.path,
      filename: 'pause_clip.mp4',
      mimeType: 'video/mp4',
      source: VaultItemSource.import,
      queueThumbnailGeneration: false,
      deduplicate: false,
      queueICloudBackup: false,
      persistImmediately: true,
    );

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<VaultService>.value(value: vault),
        ChangeNotifierProvider<MediaPlaybackManager>(
            create: (_) => MediaPlaybackManager()),
        ChangeNotifierProvider<SubscriptionService>(
            create: (_) => SubscriptionService()),
      ],
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: VaultItemDetailPage(item: item),
      ),
    ));

    VideoPlayerController? controller;
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 20000) {
      await tester.pump(const Duration(milliseconds: 50));
      final players = find.byType(VideoPlayerWidget).evaluate();
      if (players.isEmpty) continue;
      controller = (players.first.widget as VideoPlayerWidget).controller;
      if (controller.value.isPlaying &&
          controller.value.position > Duration.zero) break;
    }
    expect(controller?.value.isPlaying, isTrue, reason: 'video must auto-play');

    // Pause the way a user does: show the controls and tap Pause.
    if (find.byTooltip('Pause').evaluate().isEmpty) {
      await tester.tapAt(tester.getCenter(find.byType(VideoPlayerWidget)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.byTooltip('Pause'), findsWidgets);
    await tester.tap(find.byTooltip('Pause').first);

    // Give any auto-play a chance to undo the pause.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final pausedAt = controller!.value.position;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(controller.value.isPlaying, isFalse, reason: 'pause must stick');
    expect(controller.value.position, pausedAt,
        reason: 'position must not move while paused');

    // Entering and leaving fullscreen keeps the pause and the fullscreen state:
    // the detail page used to swap the player's parent widget on this toggle,
    // which rebuilt the player (auto-play again, fullscreen state lost).
    Future<void> tapControl(Finder control) async {
      if (control.evaluate().isEmpty) {
        await tester.tapAt(tester.getCenter(find.byType(VideoPlayerWidget)));
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.tap(control.first);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tapControl(find.byTooltip('Enter fullscreen'));
    expect(controller.value.isPlaying, isFalse,
        reason: 'entering fullscreen must not resume a paused video');
    expect(find.byIcon(Icons.fullscreen_exit), findsWidgets,
        reason: 'the player must stay in fullscreen');
    await tapControl(find.byIcon(Icons.fullscreen_exit));
    expect(find.byTooltip('Enter fullscreen'), findsWidgets,
        reason: 'the exit button must leave fullscreen');
    expect(controller.value.isPlaying, isFalse,
        reason: 'leaving fullscreen must not resume a paused video');

    // Play resumes.
    await tester.tap(find.byTooltip('Play').first);
    sw.reset();
    while (!controller.value.isPlaying && sw.elapsedMilliseconds < 5000) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(controller.value.isPlaying, isTrue);
    await controller.pause();
    await tester.pumpWidget(const SizedBox());
    await vault.clearDecryptedCache();
  });
}

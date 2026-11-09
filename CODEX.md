# Nyx: engineering and operations memory

## Layout
- Flutter app, iOS only in practice (Android tree exists, not shipped). Source of truth: GitHub `cyberzonenas93-commits/nyx` main. PC checkout `F:/LocalAI/repos/nyx` (full clone; `F:/LocalAI/knowledge/repos/nyx` is a sparse read-only mirror).
- Vault core: `lib/core/services/vault_service.dart` (index, import, posters, playback paths), `vault_cipher.dart` (format), `native_vault_crypto.dart` (CryptoKit bridge), `vault_stream_server.dart` (loopback playback).
- Native code lives in `ios/Runner/AppDelegate.swift` (method channels; no extra Swift files, so `project.pbxproj` needs no edits).

## Vault file format (never change without a migration)
`[0x01]` then chunks `[12-byte nonce][ciphertext][16-byte GCM tag]`, 1 MiB plaintext per chunk, last shorter, empty file = one empty chunk. AAD = `sha256(fileId)[0:8] || chunkIndex (4 bytes BE)`. Per-file key = HKDF-SHA256(master, salt 0, info fileId), derived in Dart only. Chunk i starts at `1 + i * (1 MiB + 28)`, so any range decrypts without a scan.

## Speed work (1.0.9, build 18, 2026-11-05)
- `NativeVaultCrypto` (channel `com.angelonartey.nyx/vault_crypto`: `encryptFile`, `decryptFile`, `decryptChunks`) does AES-GCM and SHA-256 in CryptoKit with POSIX file I/O on a background queue. Every caller falls back to the Dart cipher when it returns null (Android, tests on the host). Simulator (M4): native encrypt about 700 MiB/s, decrypt 540 to 770 MiB/s, Dart 19 to 20 MiB/s.
- Import (`storeFileFromPath`): native encrypt; the poster is made from the plaintext source in parallel. A 278 MiB video imported in about 0.4 s on the simulator (was about 15 s).
- Playback: `getVideoStreamUri` serves encrypted videos from `VaultStreamServer` on 127.0.0.1 with a random per-session token. It handles Range, HEAD and 416, and decrypts only the chunks a request touches. The detail page plays `VideoPlayerController.networkUrl` and falls back once to the decrypted temp file. The server stops in `clearDecryptedCache()` (every lock path), and `initialize()` rotates the token. Simulator: ready 0.18 to 0.39 s and seek to 80% about 0.14 s on a 278 MiB H.264 mp4 with moov at the end; 25 ms ready and 0.1 s seek on a 96 MiB 4K HEVC mov.
- Posters: a video AVFoundation cannot decode (WebM/VP9, AV1 on most iPhones) gets a generated stand-in poster (`drawFallbackVideoPoster`, metadata `posterFallback: true`). Stand-ins on mp4/mov/m4v/3gp are retried for a real frame once per unlock.
- Backfill: `backfillMissingVideoThumbnails()` runs after every `initialize()`. It is single-flight, stops on lock, and covers videos with no poster or a missing poster file. Encrypted videos are read over the stream, so there is no full decrypt and no size cap. Plaintext copies made by the fallback are deleted after the poster is taken. The old 300 MB poster limit in the detail page is gone.

## Duplicates and pause (1.0.9, builds 19 and 20, 2026-11-05)
- `findDuplicateGroups()` hashes only items that share `sizeBytes` with another item. Encrypted items are hashed by their plaintext SHA-256 (native `plainSha256` on the CryptoKit channel, Dart `_plainSha256InWorker` fallback); digests are cached in metadata `sha256`, the same key import-time dedup uses. Import-time dedup still skips encrypted items (`decryptIfNeeded` is false there) to keep imports instant.
- `deleteDuplicateCopy(copy, keptId:)` moves the copy's folder and album memberships to the kept file, then deletes. `DuplicatesPage.open()` is the paywall gate. A set can never be fully selected.
- Pause fix: `_buildFullContent` in the detail page auto-played on every rebuild, and every pause rebuilds it via `onPlayingStateChanged`, so pausing resumed at once. It now auto-plays once per controller (`_autoPlayedController`). Build 20 fixed the second cause: the page wrapped the player in a no-op GestureDetector only outside fullscreen, so each fullscreen toggle rebuilt the player (its initState auto-played and fullscreen state was lost); the shape is now the same in both. Regression test: `integration_test/video_pause_test.dart` (pause, fullscreen in and out, play).

## Tests and gates
- Unit tests (host, Dart cipher): `flutter test test/`. 75 pass. These include `vault_stream_server_test.dart` (ranges, tokens, tamper, stop).
- Release gate (simulator, needs CryptoKit): `tool/sim-gate.sh integration_test/native_crypto_stream_test.dart integration_test/duplicates_page_test.dart integration_test/video_pause_test.dart integration_test/poster_backfill_test.dart`. The duplicates test saves its screens to `gate-shots/` (via the Mac's `/tmp`).
  - Run it on the Mac from a tree that holds `.test_media/big_moov_end.mp4` and `poster_*.mp4` (made with ffmpeg; see that script's header).
  - It makes its own simulator (`.sim-udid`).
  - `native_crypto_stream_test` is the format-drift gate: native and Dart must stay interchangeable both ways, and tampering must fail.
- Run Flutter on the Mac, not the PC. The PC's Flutter 3.38 downgrades `pubspec.lock` (characters, matcher, material_color_utilities); never commit that.

## Release (Mac mini, `angelonartey@192.168.0.145`; DHCP, was .131 on 2026-11-09, so scan port 22 if it times out)
- Tree: `git -c core.autocrlf=false archive HEAD | ssh mac 'tar -x -C ~/nyx-release'`, then `flutter pub get` and `pod install`.
- Archive: `~/nyx-release/archive.command`, opened in Terminal (keychain). It runs xcodebuild with `-allowProvisioningUpdates` and ASC key `R7BYLGVT9L`, then writes every bundle's version to `~/nyx-release/archive-bundles.txt`. It does not upload. Upload: `export.command` (ExportOptions `destination upload`).
- Store: `node asc-nyx-submit.cjs ./qwen_asc.cjs [--dry]`. It waits for the build, attaches it to the version, sets What's New, checks the age-rating `socialMedia` answer and submits. A refused submission is resubmitted, or cancelled and replaced. `asc-nyx-cancel.cjs` cancels one submission; the read-only checks are `asc-nyx-status.cjs` and `asc-nyx-verify.cjs`. Copies are in `F:/LocalAI/release-nyx`.
- Trap: build numbers repeat across version trains. Nyx has old 1.0.0 builds 18 and 19 (Xcode 16 SDK). Looking a build up by number alone attached those, and Apple refused both submissions with ITMS-90062 ("CFBundleShortVersionString [1.0.0] must be higher than 1.0.8"). Always filter `preReleaseVersion.version` too, and check the attached build with `asc-nyx-verify.cjs`. Apple's refusal reasons only come by email (cyberzonenas93@gmail.com).
- Versions: 1.0.8 (17) was live, built from Mac-only source that is now lost. The first 1.0.9 submission (build 18, from `f32b13a`) went INVALID_BINARY because of the build-number trap above. Build 19 (`851e5ca`) was submitted at 22:36 UTC and then withdrawn for the fullscreen pause fix. 1.0.9 (20), from main `2162a8c`, was submitted 2026-11-05 23:32 UTC: review submission `1e538f62-ce7f-4a20-98e2-5eaa4c9d91a9`, WAITING_FOR_REVIEW, build id `a03349b4-cc2d-413b-8515-34f7bdcae7f9`. The age rating's `socialMedia` was answered false. Xcode warns that the iOS 13.0 target is too low and must be 15.0 from April 2027.

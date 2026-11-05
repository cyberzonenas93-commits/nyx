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

## Tests and gates
- Unit tests (host, Dart cipher): `flutter test test/`. 73 pass. These include `vault_stream_server_test.dart` (ranges, tokens, tamper, stop).
- Release gate (simulator, needs CryptoKit): `tool/sim-gate.sh integration_test/native_crypto_stream_test.dart integration_test/poster_backfill_test.dart integration_test/video_import_on_device_test.dart`.
  - Run it on the Mac from a tree that holds `.test_media/big_moov_end.mp4` and `poster_*.mp4` (made with ffmpeg; see that script's header).
  - It makes its own simulator (`.sim-udid`).
  - `native_crypto_stream_test` is the format-drift gate: native and Dart must stay interchangeable both ways, and tampering must fail.
- Run Flutter on the Mac, not the PC. The PC's Flutter 3.38 downgrades `pubspec.lock` (characters, matcher, material_color_utilities); never commit that.

## Release (Mac mini, `angelonartey@192.168.0.145`)
- Tree: `git -c core.autocrlf=false archive HEAD | ssh mac 'tar -x -C ~/nyx-release'`, then `flutter pub get` and `pod install`.
- Archive, export and upload: `~/nyx-release/archive.command`, opened in Terminal (keychain). It uses xcodebuild with `-allowProvisioningUpdates` and ASC key `R7BYLGVT9L`, and ExportOptions `destination upload`.
- Store: `node asc-nyx-submit.cjs ~/medaase-build/qwen_asc.cjs`. It waits for the build, creates the version, attaches the build, sets What's New, checks the age-rating `socialMedia` answer and submits. The read-only check is `asc-nyx-status.cjs`. Copies are in `F:/LocalAI/release-nyx`.
- Versions: 1.0.8 (17) was live, built from Mac-only source that is now lost; 1.0.9 (18) is built from main.

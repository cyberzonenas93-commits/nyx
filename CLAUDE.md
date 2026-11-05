# Nyx: product and decision memory

Nyx Vault is a private photo, video and document vault that opens as a working calculator. iOS app on the App Store: ASC app id `6757953478`, bundle `com.angelonartey.nyx`, team `36TZ8UKL8W`. Files stay on the device, encrypted at rest (AES-256-GCM, chunked format in `lib/core/services/vault_cipher.dart`); optional iCloud backup copies only ciphertext.

## Owner decisions
- 2026-11-05: "The app takes too long while uploading files and videos buffer. Fix it to make uploads instant and videos play instantly. Also all videos in the vault should have thumbnails." Then: "When done, release with the Mac." Done in 1.0.9 (18): CryptoKit crypto, loopback range streaming, poster backfill. See CODEX.md.
- 2026-08-26 (1.0.7): iOS deployment target stays 13.0 for now; Apple requires 15.0 from Spring 2027, so bump it before then.
- 2026-08-26: the unreviewed code bundled into 1.0.7 (`download_manager_service`, `wifi_transfer_service`, `subscription_service`, `settings_page`, `lib/core/config/`) was shipped on his word.
- Export compliance is declared in the binary (`ITSAppUsesNonExemptEncryption = false`); never re-answer it.

## Known gaps
- 1.0.8 (build 17, live 2026-09-15, "Videos start faster...") was built on the Mac from source that never reached GitHub; the Mac tree and its PC archive are gone. 1.0.9 is built on GitHub main (1.0.7) plus the 2026-11-05 work, which replaces 1.0.8's playback changes.
- Thumbnails are plaintext JPEGs in `<Documents>/vault/thumbnails/`, excluded from backup.
- The vault locks on `AppLifecycleState.inactive`, which the asset picker can trigger mid-import.

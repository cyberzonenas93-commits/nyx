# Encrypt Vault At Rest

**Date:** 2026-05-07
**Status:** Approved by user, ready to implement

## Goal

Stop plaintext vault contents from leaving the device — to iCloud Drive (via the
app's ubiquity-container sync), to iCloud Backup (via iOS device backup of
`Documents/`), or to any other surface. Keep the existing iCloud sync feature
working, but have it sync ciphertext only.

## Threat model

- **Attacker:** anyone who gains access to the user's iCloud account
  (compromise, restored backup, lawful access). Or anyone with file-level access
  to the iOS device's `Documents/` directory (forensic, jailbreak).
- **Asset:** the bytes of vaulted media, plus filenames, tags, thumbnails,
  folder structure.
- **Defense:** all of the above is encrypted at rest with AES-256-GCM under a
  master key that is derived from the user's PIN and held only in the device
  Keychain (`flutter_secure_storage` default options — `synchronizable=false`).
- **Out-of-threat-model:** an attacker who has the device unlocked AND the PIN.
  No defense against that.

## Storage layout

Unchanged on disk:
- Local vault dir: `Documents/<vaultName>/`
- Local thumbnails: `Documents/<vaultName>/thumbnails/`
- Local index: `Documents/<vaultName>/index/items.json`, `albums.json`, `folders.json`
- iCloud mirror: ubiquity-container `<vaultName>_backup/` (set up by
  `_initializeICloudBackup` in `vault_service.dart`).

What changes is the **byte content** of every file at those paths: ciphertext
instead of plaintext.

## Encryption format

Each on-disk file is laid out as:

```
[1 byte version = 0x01] [12 byte nonce] [ciphertext] [16 byte GCM tag]
```

- Algorithm: AES-256-GCM.
- Per-file key: HKDF-SHA256(masterKey, info=fileId, salt=vaultSalt) → 32 bytes.
  (Replaces the existing HMAC-based `deriveFileKey` in `EncryptionService`.)
- Nonce: 12 random bytes per write, drawn from `Random.secure`.
- Tag: 16 bytes, GCM-authenticated.
- AAD: the file's `id` string (UTF-8) — binds ciphertext to its identity, so
  a swapped file fails authentication.

## What gets encrypted

1. **File contents.** Every vaulted media file.
2. **Thumbnails.** Encrypted with same per-file derivation, fileId =
   `thumb:<itemId>`.
3. **Index files.** `items.json`, `albums.json`, `folders.json` are encrypted
   as single blobs. Filenames and tags are sensitive.
4. **Future writes.** `storeFile`, `storeFileFromPath`, thumbnail generation,
   index save, iCloud sync.

## Read paths

- **Images / PDFs / small docs** → decrypt to `Uint8List` in memory.
- **Videos / audio** → decrypt to a file in `getTemporaryDirectory()`
  (iOS `tmp/` is not iCloud-backed). Player opens the temp file. Cleanup
  on player dispose. Adds a few-second delay before playback for large
  videos. Streaming decryption (HTTP server or AVAssetResourceLoaderDelegate)
  is out of scope here.
- **Share / export** → decrypt to temp file, share, delete on completion.
- **Index** → decrypted on `_loadIndex`, encrypted on `_saveIndex`.

## Read/write API

Add two helpers in `EncryptionService` (or a new `VaultCipher` class):

```dart
// Encrypt bytes for a given fileId; returns full on-disk format
Future<Uint8List> encryptForFile(String fileId, Uint8List plaintext);

// Decrypt; throws on tag mismatch
Future<Uint8List> decryptForFile(String fileId, Uint8List onDisk);

// Streaming variants for large files
Future<void> encryptStream(String fileId, Stream<List<int>> source, IOSink dest);
Future<void> decryptStream(String fileId, File source, IOSink dest);
```

Streaming uses chunked AES-GCM: 1 MB chunks, each a complete
`[nonce][ct][tag]` block, chunk index in AAD. Required for large videos
(>4 GB hits practical GCM limits, but mainly to keep memory bounded).

## Item metadata flag

Add to `VaultItem.metadata`:

```
"encryption": "aes-gcm-v1"
```

The read path checks this flag. If absent, the file is read as plaintext —
that is the migration trigger. Once encrypted, the flag is set and the file
will never be read as plaintext again.

## Migration

On vault init, after loading the index:

1. Walk every item.
2. If `metadata.encryption` is missing:
   - Show a one-time modal "Securing your vault…" with progress.
   - For each item: encrypt-in-place with atomic rename
     (`<id>` → `<id>.tmp.enc` → fsync → rename over `<id>`), then update
     `metadata.encryption` and persist the index.
   - Encrypt the thumbnail file the same way.
3. Encrypt `items.json`, `albums.json`, `folders.json` (rewrite as `.enc`
   files; remove plaintext `.json` after success).
4. Re-prime `_iCloudSyncQueue` with all item IDs so the next sync pass
   overwrites the iCloud plaintext with ciphertext.
5. Resumable: if app is killed mid-migration, the next launch picks up
   where it left off (metadata flag tells us which files are done).

## iCloud sync

No code changes to the sync mechanism. `_syncFileToICloud` already does a
byte-for-byte copy and triggers on `lastModified` change — re-encrypting
a local file naturally bumps its timestamp and re-uploads ciphertext over
the prior plaintext.

`_iCloudBackupDirectory`, the platform-channel `getICloudContainerPath`,
the entitlements (`CloudDocuments`, ubiquity container), and the
`vault_storage_preference` UI all stay as they are.

## Master-key handling — verify, don't change

`flutter_secure_storage` is instantiated with default options at every
call site (`auth_service.dart`, `multi_vault_service.dart`,
`panic_switch_service.dart`). Defaults are `synchronizable=false`,
`accessibility=KeychainAccessibility.unlocked` — keys do not enter
iCloud Keychain.

This means: an iCloud restore on a new device gives the attacker
ciphertext but no key. It also means a legitimate user reinstalling the
app loses access to their iCloud copy. Reinstall recovery (key escrow,
recovery codes) is **out of scope** for this fix and tracked separately.

## Crash safety

Per-file atomic write:

```
1. write to <id>.tmp.enc
2. fsync
3. rename <id>.tmp.enc -> <id>
4. update metadata.encryption flag, persist index
```

If killed between 3 and 4, the next launch sees ciphertext on disk but
metadata still says plaintext — the read path will then mis-decrypt and
fail GCM auth. To handle: read attempts that fail auth on a
"plaintext-flagged" file fall back to treating it as ciphertext and, if
that succeeds, mark it encrypted. Belt-and-braces.

If killed between 1 and 3, the `.tmp.enc` is orphaned. Cleaned up on next
launch.

## Out of scope

- Removing originals from the iOS Photos library after import (the
  `deleteOriginal: false` lines + missing `PhotoManager.editor.deleteWithIds`
  call). Independent fix, separate session.
- Streaming decrypt for video playback (no decrypt-to-tmp delay).
- Replacing placeholder Kyber / non-functional Argon2id.
- iCloud reinstall recovery flow.
- Setting `NSURLIsExcludedFromBackupKey` — not needed once ciphertext is in place.

## Testing

- Unit: `encryptForFile` / `decryptForFile` round-trip; tag-mismatch raises;
  AAD swap (different fileId) raises.
- Unit: streaming encrypt/decrypt round-trip for 100 MB synthetic file.
- Unit: chunk index in AAD prevents chunk reordering.
- Integration: store a file, kill mid-migration, restart, verify recovery.
- Integration: end-to-end import → confirm `Documents/<vault>/<id>` is
  ciphertext (not the original bytes), confirm thumbnail is ciphertext,
  confirm `items.json.enc` exists and `items.json` is gone.
- Manual: iCloud Drive → Files.app → Nyx folder shows ciphertext blobs,
  not media.

## Open questions

None. Ready to plan implementation.

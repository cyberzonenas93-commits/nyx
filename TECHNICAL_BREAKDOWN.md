# Nyx — Full Technical Breakdown

This document describes the Nyx Flutter app architecture, main flows, data model, persistence, and the major subsystems (vault, import, playback, browser/extraction, Wi‑Fi transfer, subscriptions, security).

> Notes:
> - File paths in this doc are relative to the repo root (e.g. `lib/main.dart`).
> - This document intentionally avoids describing any hidden/bypass trigger sequences (if present) beyond acknowledging they exist, because those are security-sensitive.

---

## 1) What the app is (high level)

Nyx is a Flutter app with two primary user experiences:

- **Calculator UI** (disguise surface): a full-feature calculator screen that looks like the “home” of the app.
- **Vault UI** (private storage): an on-device file manager for photos, videos, documents, and other binaries. The vault supports importing from device storage/photos, capturing from camera, downloading from an in-app browser, and transferring files over local Wi‑Fi.

Access to the vault is governed by a **state machine** (`AppState`) and a **PIN-derived master key** held only in memory while the vault is unlocked.

---

## 2) Repository layout (major directories)

- **App entry + routing**
  - `lib/main.dart`: constructs services; registers providers.
  - `lib/app/app.dart`: `MaterialApp`; chooses root screen based on `AuthService.appState`; enforces lifecycle lock.
  - `lib/app/theme.dart`: app theme.

- **Core models**
  - `lib/core/models/app_state.dart`: onboarding/pinSetup/disguised/locked/unlocked.
  - `lib/core/models/vault_item.dart`: canonical schema for vault items.
  - `lib/core/models/vault_folder.dart`, `lib/core/models/album.dart`
  - `lib/core/models/vault_metadata.dart`: multi-vault metadata.
  - `lib/core/models/subscription_tier.dart`

- **Core services** (`lib/core/services/`)
  - Auth/crypto: `auth_service.dart`, `encryption_service.dart`, `advanced_cryptography_service.dart`
  - Vault storage/index/thumbnails: `vault_service.dart`, `thumbnail_cache_service.dart`, `video_poster_background_service.dart`
  - Import pipeline: `background_import_service.dart`, `background_execution_service.dart`
  - Playback coordination: `media_playback_manager.dart`
  - Browser + detection + downloads: `browser_session_service.dart`, `redirect_blocker_service.dart`,
    `youtube_download_service.dart`, `generic_video_detection_service.dart`, `media_extraction_engine.dart`,
    `download_manager_service.dart`, `streaming_detector_service.dart`, `video_extraction_service.dart`
  - Wi‑Fi transfer server: `wifi_transfer_service.dart`
  - Security: `panic_switch_service.dart`, `tamper_detection_service.dart`, `permission_service.dart`
  - Subscription/IAP: `subscription_service.dart`
  - Other utilities: `performance_service.dart`, `failure_intelligence_service.dart`, etc.

- **Feature pages**
  - Disguise: `lib/features/disguise/pages/calculator_page.dart`
  - Onboarding/unlock: `lib/features/onboarding/pages/onboarding_page.dart`, `lib/features/unlock/pages/*`
  - Vault: `lib/features/vault/pages/*`
  - Settings: `lib/features/settings/pages/*`
  - Subscription UI: `lib/features/subscription/pages/*`

---

## 3) Dependency injection (Provider graph)

Nyx uses `provider` (mostly `ChangeNotifierProvider`) to expose long-lived services throughout the widget tree.

In `lib/main.dart`, `runApp(MultiProvider(...))` registers (non-exhaustive, but major ones):

- `AuthService`
- `VaultService`
- `DownloadManagerService` + `MediaExtractionEngine` (injected circularly)
- `SubscriptionService`
- `BrowserSessionService`
- `MediaPlaybackManager`
- `VideoPosterBackgroundService`
- `WiFiTransferService`
- `TutorialService`
- `MultiVaultService`
- `PanicSwitchService` (plain `Provider`)
- `AdvancedCryptographyService` (plain `Provider`)
- `TamperDetectionService` (plain `Provider`)

Implication: pages generally obtain functionality via `Provider.of<T>(context)` / `Consumer<T>`.

---

## 4) App state machine and routing

### 4.1 AppState
`lib/core/models/app_state.dart` defines states:

- `onboarding`
- `pinSetup`
- `disguised`
- `locked`
- `unlocked`

### 4.2 Root routing
`lib/app/app.dart` uses `Consumer<AuthService>` and switches on `authService.appState`:

- `onboarding` → `OnboardingPage`
- `pinSetup` → `UnlockMethodSelectionPage`
- `disguised` → `CalculatorPage`
- `locked` → `UnlockPage`
- `unlocked` → `VaultHomePage(vaultId: authService.currentVaultId)`

### 4.3 Lifecycle locking (security)
`lib/app/app.dart` implements `WidgetsBindingObserver` and locks when the app backgrounds:

- On `paused/inactive/hidden/detached`: calls `authService.lockVault()` and pops to the first route so the calculator is what the user sees on resume.

---

## 5) Authentication, PIN, and key derivation

### 5.1 Where secrets live
`lib/core/services/auth_service.dart` uses:

- `FlutterSecureStorage` for durable secret material (PIN hash + salt, vault metadata, subscription status, etc.).
- `SharedPreferences` for a “fresh install detection” flag because iOS Keychain can persist after uninstall.

### 5.2 PIN setup
`AuthService.setupPIN(pin, {unlockTriggerCode})`:

- Generates a random salt.
- Computes stored hash via `EncryptionService.hashPassword()` (iterative HMAC-SHA256; runs in an isolate).
- Stores `pin_salt`, `pin_hash`, and initialization flags in secure storage.
- Sets app state to `disguised` and clears in-memory master key (user must later unlock).

### 5.3 Unlock and lock
`AuthService.verifyPIN(pin)`:

- Reads salt/hash from secure storage.
- Derives `masterKey = EncryptionService.deriveMasterKey(pin, salt)` (isolate).
- Verifies pin using stored hash.
- On success sets:
  - `_masterKey` (in memory)
  - `_currentVaultId = null` (primary)
  - `_appState = unlocked`

`AuthService.lockVault()`:

- Clears `_masterKey`, clears `_currentVaultId`, and sets `_appState = disguised`.

### 5.4 EncryptionService (crypto primitives)
`lib/core/services/encryption_service.dart` provides:

- Iterative HMAC-SHA256 derivation (100,000 iterations) used for:
  - deriving a master key from the PIN + salt
  - hashing/verifying the PIN for storage
- AES‑256‑GCM helpers (`encryptFile`/`decryptFile`) and string encryption helpers.

Important: the app’s “master key” is kept in memory when unlocked; persistent storage holds the verification hash+salt, not the plaintext PIN.

---

## 6) Multi‑vault architecture

### 6.1 Metadata storage
`lib/core/services/multi_vault_service.dart` persists `vaults_metadata` (JSON) in secure storage.

Each vault has `VaultMetadata` (`lib/core/models/vault_metadata.dart`) including:

- `id`
- `name`
- `triggerCode`
- `createdAt`
- `isPrimary`

### 6.2 Secondary vault PIN storage
For secondary vaults, PIN material is stored in secure storage under:

- `pin_hash_<vaultId>`
- `pin_salt_<vaultId>`

`AuthService.verifySecondaryVaultPIN(vaultId, pin)` derives the vault’s in-memory master key and sets `currentVaultId = vaultId` if valid.

---

## 7) Vault: data model, persistence, and storage layout

### 7.1 VaultItem model
`lib/core/models/vault_item.dart` represents any stored file:

- Stable random `id` (not derived from filename).
- `originalFilename`, optional `customName`
- `type` (`photo`, `video`, `audio`, `document`, `archive`, `unknown`)
- `mimeType`, `sizeBytes`
- `dateAdded`, optional `dateModified`
- `source` (`camera`, `browser`, `import`, `share`, `unknown`)
- `thumbnailPath` (relative)
- `vaultRelativePath` (relative)
- `metadata` map (duration, dimensions, timestamps, hashes, tags, etc.)

### 7.2 VaultService responsibilities
`lib/core/services/vault_service.dart` manages:

- Vault directories (vault root, thumbnails, index directories)
- Index/albums/folders persistence (JSON files)
- Thumbnail generation and caching
- Metadata extraction (dimensions/duration)
- Deduplication (SHA‑256), indexing, sorting by timestamp
- Tags stored in metadata
- iCloud backup hooks (if enabled by app settings; some references exist)

### 7.3 Index and metadata
The “index” is the source of truth for what appears in the vault UI. The index is debounced to avoid constant disk writes.

Nyx stores a normalized timestamp in `metadata['timestampMs']` to drive chronological ordering, and backfills missing values from `dateAdded`.

### 7.4 Tags
Tags are stored as a list of string IDs in `metadata['tags']`.
`VaultService` exposes:

- `getItemTagIds(itemId)`
- `setItemTagIds(itemId, tagIds)`
- `toggleItemTagId(itemId, tagId)`

---

## 8) Import pipeline (device → vault) and anti-freeze design

Nyx separates **selection** (UI) from **processing/storage** (background queue).

### 8.1 UI selection
Primary orchestration is in `lib/features/vault/pages/vault_home_page.dart` (and related selection pages such as `photo_selection_page.dart`).

Sources commonly include:

- File picker (documents/images)
- Asset picker / device photos (platform-specific)
- Camera capture
- Share-sheet imports (where present)

### 8.2 BackgroundImportService
`lib/core/services/background_import_service.dart` provides:

- A persisted queue of `ImportTask`s (stored in `SharedPreferences`).
- A background loop that processes items serially.
- Progress reporting via `Stream<ImportProgress>` for UI.

Anti-stall measures:

- **Throttled persistence**: queue state is not written on every single item; it persists every N items or minimum time interval to avoid O(n²) behavior for large batches.
- **Playback-aware pausing**: if a video is playing (`MediaPlaybackManager.isVideoPlaying`), imports yield to reduce memory pressure.
- **Delays**: additional delays for video tasks (especially on iOS) to reduce crash risk during heavy decoding/poster generation.

### 8.3 Store into vault
Ultimately tasks call into `VaultService` to store files by path, update the index, and (eventually) generate thumbnails/posters.

---

## 9) Thumbnails and video posters

### 9.1 Images
`VaultService` generates image thumbnails using the `image` package and resizes to a small square (~200px), usually in an isolate for CPU work.

### 9.2 Videos
Video posters/thumbnails use `video_thumbnail` and/or background generation via:

- `lib/core/services/video_poster_background_service.dart`

To prevent iOS crashes during bulk operations, thumbnail extraction is serialized (a job chain) and concurrency is limited.

---

## 10) Media viewing and playback coordination

### 10.1 Viewer pages
Common pages/components:

- `lib/features/vault/pages/vault_item_detail_page.dart`: paging through items, image/video viewer.
- `lib/features/vault/widgets/photo_viewer_widget.dart`: zoom/pan/fullscreen.
- `lib/features/vault/widgets/video_player_widget.dart`: video controller management + gestures.

### 10.2 Single active playback (anti-overlap)
`lib/core/services/media_playback_manager.dart` is a singleton responsible for:

- Registering the currently playing video controller or audio player.
- Stopping existing playback when a new media starts.

This is used to prevent multiple videos playing simultaneously and reduce memory pressure.

---

## 11) In-app Browser, detection, extraction, and downloads

### 11.1 Browser UI
`lib/features/vault/pages/browser_page.dart` provides a multi-tab web browser using `webview_flutter`:

- Tabs, omnibox, session persistence (`BrowserSessionService`)
- Redirect blocking (`RedirectBlockerService`)
- Incognito/desktop toggles (behavior varies by platform)
- Video detection for supported sites and generic detectors
- Download flows and navigation to downloads/history pages

### 11.2 Extraction engine (progressive/HLS/DASH)
`lib/core/services/media_extraction_engine.dart`:

- Detects stream type by URL patterns and/or HEAD response content-type
- Parses:
  - Progressive URLs (direct video file URLs)
  - HLS manifests (`.m3u8`)
  - DASH manifests (`.mpd`)
- Produces a list of candidate `MediaStream`s with quality metadata.

### 11.3 Download manager
`lib/core/services/download_manager_service.dart` implements a resumable download queue:

- Keeps tasks on disk (`tasks.json`) under a temp folder.
- Supports retry/pause/resume/cancel.
- Limits concurrency (`_maxConcurrentDownloads`).
- On completion, stores downloaded files into the vault via `VaultService`.

### 11.4 Streaming player
`lib/features/vault/pages/streaming_player_page.dart` plays extracted streams using `video_player`:

- Builds a `VideoPlayerController.networkUrl`
- Includes “auto-resume” logic to recover from automatic pauses.

---

## 12) Wi‑Fi transfer (local network server)

### 12.1 Service
`lib/core/services/wifi_transfer_service.dart` runs a local HTTP server (Shelf + Router):

- Binds to LAN and exposes a simple web UI plus JSON APIs.
- Uses an access token for authorization (middleware).
- Supports:
  - listing items/folders
  - uploading files (multipart)
  - downloading items
  - downloading folders as ZIP
  - deleting items

Stability guards:

- Uploads are serialized so multiple parallel multipart uploads don’t cause excessive buffering/memory pressure.
- Upload size is capped (`_maxUploadBytes`) to reduce OOM risk.
- Multipart file data is written to a temp file as it streams in.

### 12.2 UI
`lib/features/vault/pages/wifi_transfer_page.dart` controls start/stop and displays the URL/QR and transfer stats.

---

## 13) Subscriptions, trial, and paywall enforcement

### 13.1 SubscriptionService
`lib/core/services/subscription_service.dart` uses `in_app_purchase`:

- Product IDs:
  - `nyx_unlimited_monthly`
  - `nyx_unlimited_yearly`
- Loads products, listens to purchase stream, restores purchases.
- Supports a free trial concept with stored `trial_start_date`.
- Persists tier/status to secure storage.

Security note: the code includes a “god mode” bypass flag stored as `god_mode` in secure storage. This document does not describe how it’s activated.

### 13.2 Paywall UI
`lib/features/subscription/pages/paywall_page.dart` and `subscription_setup_page.dart` show subscription options and manage purchase flow.

---

## 14) Security features (beyond PIN)

- **Auto-lock on background**: `lib/app/app.dart`
- **Panic switch**: `lib/core/services/panic_switch_service.dart` (monitoring can be enabled/disabled; starts/stops with lifecycle).
- **Tamper detection**: `lib/core/services/tamper_detection_service.dart` (tracks failed attempts; policy-driven responses).
- **Permissions**: `lib/core/services/permission_service.dart` centralizes permission checks and requests.

---

## 15) Persistence map (what is stored where)

### 15.1 Secure storage (Keychain/Keystore)
Common keys (non-exhaustive):

- Initialization: `onboarding_complete`, `vault_initialized`, `has_launched_before` (note: `has_launched_before` is in SharedPreferences)
- Primary PIN: `pin_salt`, `pin_hash`
- Secondary vault PIN: `pin_salt_<vaultId>`, `pin_hash_<vaultId>`
- Unlock trigger code: `unlock_trigger_code`
- Multi-vault metadata: `vaults_metadata`
- Subscription: `subscription_tier`, `subscription_status`, `trial_start_date`, `god_mode`

### 15.2 SharedPreferences
- Background import queue persistence:
  - `background_import_queue`
  - `background_import_processing`
- Fresh install detection:
  - `has_launched_before`

### 15.3 Filesystem
Managed by `VaultService` and `DownloadManagerService`:

- Vault root directory (items, index, thumbnails)
- Temp download directory + `tasks.json`

---

## 16) End-to-end user flows (system view)

### 16.1 First launch → onboarding → PIN setup
1. `AuthService._initialize()` checks `onboarding_complete`.
2. If not complete: state → `onboarding`, shows `OnboardingPage`.
3. On completion: state → `pinSetup`, shows `UnlockMethodSelectionPage` and then PIN setup (`PinSetupPage`).
4. PIN setup writes salt/hash, initializes primary vault metadata, then returns state → `disguised`.

### 16.2 Normal launch
1. App starts in `disguised` (calculator).
2. User performs calculator unlock flow.
3. `AuthService.verifyPIN()` (primary) or `verifySecondaryVaultPIN()` (secondary) sets in-memory `masterKey`.
4. App state → `unlocked`, routing shows `VaultHomePage`.

### 16.3 Import files into vault
1. User selects media/files in `VaultHomePage` flows.
2. UI enqueues tasks into `BackgroundImportService`.
3. Background import loop stores into `VaultService`, updates index, generates thumbnails/posters gradually.
4. UI observes progress stream and updates the banner/progress indicator.

### 16.4 Browse/download/stream
1. User opens `BrowserPage`.
2. Detection services identify downloadable media.
3. Either:
   - Download: tasks go to `DownloadManagerService`, then final files get stored into vault.
   - Stream: `StreamingPlayerPage` plays extracted stream URL.

### 16.5 Wi‑Fi transfer
1. User opens `WiFiTransferPage`, starts server (`WiFiTransferService.startServer()`).
2. Desktop browser connects to server URL with token.
3. Upload/download endpoints stream files and store into vault.

### 16.6 Backgrounding / minimizing app
1. App lifecycle observer triggers lock.
2. Master key is cleared.
3. Navigation is popped back to root; calculator screen becomes visible.

---

## 17) Practical extension points (where to change behavior)

- **Access flow / routing**: `lib/app/app.dart`, `lib/core/services/auth_service.dart`, `lib/features/disguise/pages/calculator_page.dart`
- **Vault storage + indexing**: `lib/core/services/vault_service.dart`
- **Import performance/stability**: `lib/core/services/background_import_service.dart` and vault store methods
- **Thumbnail/poster generation**: `vault_service.dart`, `video_poster_background_service.dart`
- **Viewer UX/gestures**: `vault_item_detail_page.dart`, `photo_viewer_widget.dart`, `video_player_widget.dart`
- **Browser/extraction**: `browser_page.dart`, `media_extraction_engine.dart`, `generic_video_detection_service.dart`
- **Wi‑Fi transfer protocol**: `wifi_transfer_service.dart`
- **Subscription enforcement**: `subscription_service.dart`, `paywall_page.dart`

---

## 18) Quick reference: key files

- Entry/DI: `lib/main.dart`
- Routing + lifecycle lock: `lib/app/app.dart`
- Auth state + PIN: `lib/core/services/auth_service.dart`
- Crypto primitives: `lib/core/services/encryption_service.dart`
- Vault storage/index/thumbnails/tags/dedupe: `lib/core/services/vault_service.dart`
- Background import queue: `lib/core/services/background_import_service.dart`
- Playback singletons: `lib/core/services/media_playback_manager.dart`
- Browser: `lib/features/vault/pages/browser_page.dart`
- Extraction: `lib/core/services/media_extraction_engine.dart`
- Downloads: `lib/core/services/download_manager_service.dart`
- Streaming player: `lib/features/vault/pages/streaming_player_page.dart`
- Wi‑Fi transfer: `lib/core/services/wifi_transfer_service.dart`
- Multi-vault: `lib/core/services/multi_vault_service.dart`
- Subscriptions: `lib/core/services/subscription_service.dart`


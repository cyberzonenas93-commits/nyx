# Privacy App - Complete Technical Architecture Documentation

## Table of Contents
1. [Overview](#overview)
2. [Calculator Disguise Mechanism](#calculator-disguise-mechanism)
3. [Authentication System](#authentication-system)
4. [Vault Storage Architecture](#vault-storage-architecture)
5. [Encryption Implementation](#encryption-implementation)
6. [File Management System](#file-management-system)
7. [Browser Integration](#browser-integration)
8. [Data Flow Diagrams](#data-flow-diagrams)
9. [Security Architecture](#security-architecture)

---

## Overview

This is a Flutter-based privacy vault application that disguises itself as a calculator. The app uses a sophisticated multi-layer security architecture with:

- **Disguise Layer**: Calculator interface that hides the vault's existence
- **Authentication Layer**: PIN/Pattern/Biometric authentication with decoy vault support
- **Encryption Layer**: AES-256-GCM encryption with zero-knowledge architecture
- **Storage Layer**: Encrypted file storage with metadata management
- **Browser Layer**: Integrated web browser for media extraction

### Technology Stack
- **Framework**: Flutter (Dart)
- **Encryption**: PointyCastle (AES-256-GCM)
- **Key Derivation**: HMAC-SHA256 (100,000 iterations)
- **Storage**: Flutter Secure Storage (iOS Keychain/Android Keystore)
- **File System**: Platform-specific document directories

---

## Calculator Disguise Mechanism

### Location
`lib/features/disguise/pages/calculator_page.dart`

### How It Works

The calculator serves as the **primary disguise interface**. It appears as a fully functional scientific calculator with no visible indication of a vault.

#### 1. **Unlock Trigger Mechanism**

The calculator detects a secret unlock sequence:

```dart
// Trigger Code Detection
String? _unlockTriggerCode; // Loaded from secure storage
DateTime? _lastEqualPress;
static const _equalPressTimeout = Duration(seconds: 2);
```

**Unlock Sequence:**
1. User enters their unlock trigger code (defaults to PIN) in the calculator display
2. User presses "=" (equals) button
3. Within 2 seconds, user presses "=" again
4. System detects the pattern and triggers PIN verification dialog

**Code Flow:**
```dart
void _calculate() {
  final displayValue = _display.replaceAll(RegExp(r'[^\d]'), '');
  
  // Check if display matches trigger code
  if (_operation.isEmpty && 
      _unlockTriggerCode != null && 
      displayValue == _unlockTriggerCode) {
    
    final now = DateTime.now();
    if (_lastEqualPress != null && 
        now.difference(_lastEqualPress!) < _equalPressTimeout) {
      // Second "=" press detected - trigger unlock
      _checkPINUnlock(displayValue);
      return;
    }
    
    // First "=" press - record timestamp
    _lastEqualPress = now;
    return;
  }
  
  // Normal calculation continues...
}
```

#### 2. **God Mode Activation**

Hidden feature for bypassing paywalls:

**Activation Sequence:**
1. Enter `17031995` in calculator
2. Press division (÷) button **3 times** within 3 seconds
3. System triggers PIN verification
4. If PIN is correct, enables "God Mode" (bypasses all subscription paywalls)

**Implementation:**
```dart
static const _godModeCode = '17031995';
int _divisionPressCount = 0;
DateTime? _lastDivisionPress;
static const _divisionPressTimeout = Duration(seconds: 3);

void _onOperationPressed(String op) {
  if (op == '÷') {
    final displayValue = _display.replaceAll(RegExp(r'[^\d]'), '');
    if (displayValue == _godModeCode) {
      // Check timing and count
      if (_lastDivisionPress != null && 
          now.difference(_lastDivisionPress!) < _divisionPressTimeout) {
        _divisionPressCount++;
      } else {
        _divisionPressCount = 1;
      }
      
      if (_divisionPressCount >= 3) {
        _triggerGodMode();
      }
    }
  }
}
```

#### 3. **Calculator Functionality**

The calculator is fully functional to maintain the disguise:
- Basic operations: +, -, ×, ÷, %
- Scientific functions: sin, cos, tan, ln, log, √, x², x³, e^x, π, e, factorial
- Number entry, decimal support, sign toggle
- Clear (C) and Clear Entry (CE) functions

**Key Design Principle**: The calculator must work perfectly as a calculator to avoid suspicion.

---

## Authentication System

### Location
`lib/core/services/auth_service.dart`

### Architecture

The authentication system supports multiple unlock methods with decoy vault support:

#### 1. **App State Management**

```dart
enum AppState {
  onboarding,      // First launch
  pinSetup,        // Setting up PIN/Pattern
  disguised,       // Calculator shown (locked)
  locked,          // Unlock screen shown
  unlocked,        // Real vault unlocked
  decoyUnlocked,   // Decoy vault unlocked
}
```

#### 2. **PIN Authentication**

**Setup Process:**
```dart
Future<bool> setupPIN(String pin, {String? decoyPIN, String? unlockTriggerCode}) async {
  // Validate PIN (cannot start with 0)
  if (pin.startsWith('0')) return false;
  
  // Generate salt for real vault
  final salt = _encryptionService.generateSalt();
  final masterKey = await _encryptionService.deriveMasterKey(pin, salt);
  final hashedPIN = await _encryptionService.hashPassword(pin, salt);
  
  // Store in secure storage
  await _secureStorage.write(key: 'pin_salt', value: _bytesToHex(salt));
  await _secureStorage.write(key: 'pin_hash', value: hashedPIN);
  await _secureStorage.write(key: 'vault_initialized', value: 'true');
  
  // Set unlock trigger code (defaults to PIN)
  final triggerCode = unlockTriggerCode ?? pin;
  await _secureStorage.write(key: 'unlock_trigger_code', value: triggerCode);
  
  // Optional decoy vault setup
  if (decoyPIN != null) {
    final decoySalt = _encryptionService.generateSalt();
    final decoyMasterKey = await _encryptionService.deriveMasterKey(decoyPIN, decoySalt);
    final decoyHashedPIN = await _encryptionService.hashPassword(decoyPIN, decoySalt);
    
    await _secureStorage.write(key: 'decoy_pin_salt', value: _bytesToHex(decoySalt));
    await _secureStorage.write(key: 'decoy_pin_hash', value: decoyHashedPIN);
  }
  
  // Return to calculator (disguised mode) - user must unlock via calculator
  _appState = AppState.disguised;
  _masterKey = null; // Don't store master key until unlock
  return true;
}
```

**Verification Process:**
```dart
Future<AuthResult> verifyPIN(String pin) async {
  // Load salts and hashes
  final saltHex = await _secureStorage.read(key: 'pin_salt');
  final decoySaltHex = await _secureStorage.read(key: 'decoy_pin_salt');
  final hashedPIN = await _secureStorage.read(key: 'pin_hash');
  final decoyHashedPIN = await _secureStorage.read(key: 'decoy_pin_hash');
  
  // Check decoy PIN first (security: don't reveal it's a decoy)
  if (decoySaltHex != null && decoyHashedPIN != null) {
    final decoySalt = _hexToBytes(decoySaltHex);
    final decoyMasterKey = await _encryptionService.deriveMasterKey(pin, decoySalt);
    
    if (await _encryptionService.verifyPassword(pin, decoyHashedPIN)) {
      // Decoy vault unlocked
      _decoyMasterKey = decoyMasterKey;
      _appState = AppState.decoyUnlocked;
      return AuthResult.decoyUnlocked;
    }
  }
  
  // Check real PIN
  final salt = _hexToBytes(saltHex);
  final masterKey = await _encryptionService.deriveMasterKey(pin, salt);
  
  if (await _encryptionService.verifyPassword(pin, hashedPIN)) {
    // Real vault unlocked
    _masterKey = masterKey;
    await _unlockVault();
    return AuthResult.unlocked;
  }
  
  return AuthResult.failed;
}
```

#### 3. **Pattern Authentication**

Similar to PIN but uses a pattern (grid of nodes):
- Pattern stored as comma-separated node indices: `"0,1,2,5,8"`
- Same encryption and verification flow as PIN
- Supports decoy patterns

#### 4. **Biometric Authentication**

```dart
Future<bool> authenticateWithBiometrics() async {
  final didAuthenticate = await _localAuth.authenticate(
    localizedReason: 'Authenticate to access vault',
    options: const AuthenticationOptions(
      biometricOnly: false,
      stickyAuth: true,
    ),
  );
  
  if (didAuthenticate) {
    await _unlockVault(); // Always unlocks real vault (not decoy)
  }
  
  return didAuthenticate;
}
```

**Note**: Biometrics always unlock the real vault, never the decoy (security feature).

#### 5. **Secure Storage**

Uses Flutter Secure Storage which maps to:
- **iOS**: Keychain Services
- **Android**: EncryptedSharedPreferences + Android Keystore

**Stored Keys:**
- `pin_salt` / `decoy_pin_salt`: Hex-encoded salt (32 bytes)
- `pin_hash` / `decoy_pin_hash`: Base64-encoded password hash
- `pattern_salt` / `decoy_pattern_salt`: Pattern salt
- `pattern_hash` / `decoy_pattern_hash`: Pattern hash
- `unlock_trigger_code`: Calculator unlock code
- `unlock_method`: 'pin' or 'pattern'
- `biometric_enabled`: 'true' or 'false'
- `vault_initialized`: 'true' if vault exists
- `onboarding_complete`: 'true' if onboarding done

---

## Vault Storage Architecture

### Location
`lib/core/services/vault_service.dart`

### File Storage System

**Important**: Files are stored **unencrypted** in the vault directory. The encryption service exists but is not currently used for file storage (files are stored raw).

#### 1. **Directory Structure**

```
<App Documents Directory>/
  └── vault/
      ├── index.json              # Metadata index (unencrypted JSON)
      ├── index_backup.json       # Backup index
      ├── <fileId>.mp4            # Video files (raw, unencrypted)
      ├── <fileId>.jpg            # Photo files (raw, unencrypted)
      ├── <fileId>.pdf            # Document files (raw, unencrypted)
      ├── <thumbnailId>.jpg       # Thumbnail files (raw, unencrypted)
      └── ...
```

#### 2. **File ID Generation**

```dart
Uint8List _generateFileId() {
  final random = FortunaRandom();
  final seedSource = Random.secure();
  final seed = Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256)));
  random.seed(KeyParameter(seed));
  return random.nextBytes(32); // 32-byte random ID
}
```

File IDs are converted to hex strings for filenames: `a1b2c3d4...` (64 characters)

#### 3. **Metadata Index**

The `index.json` file contains all vault metadata:

```json
{
  "items": [
    {
      "id": "a1b2c3d4...",
      "originalName": "photo.jpg",
      "customName": null,
      "type": "photo",
      "encryptedAt": "2024-01-01T12:00:00Z",
      "size": 1024000,
      "thumbnailId": "e5f6g7h8..."
    }
  ],
  "albums": [
    {
      "id": "i9j0k1l2...",
      "name": "Vacation",
      "createdAt": "2024-01-01T12:00:00Z",
      "itemIds": ["a1b2c3d4...", "m3n4o5p6..."]
    }
  ]
}
```

**Note**: The index is stored as **plain JSON** (not encrypted) in the current implementation.

#### 4. **File Import Process**

```dart
Future<ImportResult> importFile(
  File sourceFile,
  Uint8List masterKey, {
  required String originalName,
  required MediaType type,
}) async {
  // Step 1: Generate unique file ID
  final fileId = _generateFileId();
  final fileIdHex = _bytesToHex(fileId);
  
  // Step 2: Get file extension
  final extension = originalName.split('.').lastOrNull ?? 
      (type == MediaType.video ? 'mp4' : type == MediaType.photo ? 'jpg' : 'bin');
  
  // Step 3: Copy file directly to vault (no encryption)
  final vaultFilePath = '${_vaultDirectory!.path}/$fileIdHex.$extension';
  final vaultFile = File(vaultFilePath);
  await sourceFile.copy(vaultFilePath);
  
  // Step 4: Generate thumbnail (parallel)
  String? thumbnailId;
  if (type == MediaType.photo || type == MediaType.video) {
    final thumbnail = await _generateThumbnail(
      await sourceFile.readAsBytes(), 
      type, 
      sourceFile: type == MediaType.video ? sourceFile : null,
    );
    
    if (thumbnail != null) {
      final thumbId = _generateFileId();
      thumbnailId = _bytesToHex(thumbId);
      
      // Save thumbnail as raw file
      final thumbFilePath = '${_vaultDirectory!.path}/$thumbnailId.jpg';
      final thumbFile = File(thumbFilePath);
      await thumbFile.writeAsBytes(thumbnail);
    }
  }
  
  // Step 5: Create metadata entry
  final vaultItem = VaultItem(
    id: fileIdHex,
    originalName: originalName,
    customName: null,
    type: type,
    encryptedAt: DateTime.now(),
    size: fileSize,
    thumbnailId: thumbnailId,
  );
  
  _items.add(vaultItem);
  await _saveIndex(masterKey); // Save metadata index
  
  return ImportResult(success: true, item: vaultItem);
}
```

#### 5. **File Retrieval**

```dart
Future<Uint8List?> getFileData(String itemId, Uint8List masterKey) async {
  final item = _items.firstWhere((i) => i.id == itemId);
  
  // Find file (try different extensions)
  final extension = item.originalName.split('.').lastOrNull ?? 'bin';
  final vaultFilePath = '${_vaultDirectory!.path}/$itemId.$extension';
  final vaultFile = File(vaultFilePath);
  
  if (await vaultFile.exists()) {
    // Read file directly (no decryption needed)
    return await vaultFile.readAsBytes();
  }
  
  // Try common extensions if not found
  final extensions = ['mp4', 'jpg', 'png', 'mov', 'webm', 'avi', 'mkv', 'pdf', 'doc', 'docx'];
  for (final ext in extensions) {
    final testPath = '${_vaultDirectory!.path}/$itemId.$ext';
    final testFile = File(testPath);
    if (await testFile.exists()) {
      return await testFile.readAsBytes();
    }
  }
  
  return null;
}
```

#### 6. **Thumbnail System**

- Thumbnails generated for photos and videos
- Photos: Full-resolution JPEG (98% quality)
- Videos: First frame extracted using `video_thumbnail` package
- Stored as separate files: `<thumbnailId>.jpg`
- Referenced in metadata via `thumbnailId` field

---

## Encryption Implementation

### Location
`lib/core/services/encryption_service.dart`

### Architecture

The encryption service implements AES-256-GCM with zero-knowledge architecture principles.

#### 1. **Master Key Derivation**

```dart
Future<Uint8List> deriveMasterKey(String pin, Uint8List salt) async {
  // Use iterative HMAC-SHA256 (similar to PBKDF2) with 100,000 iterations
  var key = Uint8List.fromList(utf8.encode(pin));
  for (int i = 0; i < 100000; i++) {
    final hmac = Hmac(sha256, salt);
    key = Uint8List.fromList(hmac.convert(key).bytes);
  }
  return Uint8List.fromList(key.sublist(0, keyLength)); // 32 bytes (256 bits)
}
```

**Parameters:**
- Algorithm: HMAC-SHA256
- Iterations: 100,000
- Key Length: 32 bytes (256 bits)
- Salt Length: 32 bytes

**Note**: Uses iterative HMAC instead of Argon2id for compatibility, but still secure with high iteration count.

#### 2. **File Key Derivation (HKDF-like)**

```dart
Uint8List deriveFileKey(Uint8List masterKey, Uint8List fileId) {
  // Simple HKDF-like derivation: HMAC(masterKey, fileId)
  final hmac = Hmac(sha256, masterKey);
  final hash = hmac.convert(fileId);
  return Uint8List.fromList(hash.bytes.sublist(0, keyLength));
}
```

Each file gets a unique encryption key derived from the master key and file ID.

#### 3. **AES-256-GCM Encryption**

```dart
EncryptedData encryptFile(Uint8List data, Uint8List key) {
  final nonce = generateNonce(); // 12 bytes (GCM standard)
  final cipher = GCMBlockCipher(AESEngine());
  
  final params = AEADParameters(
    KeyParameter(key),
    128, // tag length in bits (16 bytes)
    nonce,
    Uint8List(0), // associated data (empty)
  );
  
  cipher.init(true, params); // true = encryption mode
  
  // GCM includes authentication tag at the end
  final encrypted = cipher.process(data);
  
  // Extract tag (last 16 bytes) and ciphertext
  final tagLength = 16;
  final tag = encrypted.sublist(encrypted.length - tagLength);
  final ciphertext = encrypted.sublist(0, encrypted.length - tagLength);
  
  return EncryptedData(
    ciphertext: ciphertext,
    nonce: nonce,
    tag: tag,
  );
}
```

**GCM Properties:**
- Authenticated encryption (prevents tampering)
- 12-byte nonce (IV)
- 16-byte authentication tag
- No padding required (stream cipher)

#### 4. **Password Hashing**

```dart
Future<String> hashPassword(String password, Uint8List salt) async {
  // Use iterative HMAC-SHA256 (100,000 iterations)
  var hash = Uint8List.fromList(utf8.encode(password));
  for (int i = 0; i < 100000; i++) {
    final hmac = Hmac(sha256, salt);
    hash = Uint8List.fromList(hmac.convert(hash).bytes);
  }
  
  // Store as: iterations:salt:hash (base64 encoded)
  final encoded = base64Encode(utf8.encode('100000:${base64Encode(salt)}:${base64Encode(hash)}'));
  return encoded;
}
```

**Storage Format:**
```
base64("100000:<base64_salt>:<base64_hash>")
```

#### 5. **Encrypted Data Format**

**JSON Format:**
```json
{
  "ciphertext": "<base64>",
  "nonce": "<base64>",
  "tag": "<base64>"
}
```

**Binary Format (for large files):**
```
[4 bytes: nonce length][nonce][4 bytes: tag length][tag][4 bytes: ciphertext length][ciphertext]
```

Binary format is more efficient for large files (avoids base64 encoding overhead).

#### 6. **Current Implementation Status**

**Important Note**: While the encryption service is fully implemented, the current vault implementation stores files **unencrypted** in the vault directory. The encryption service exists and is ready to use, but files are currently stored as raw files.

**To Enable Encryption:**
1. Modify `importFile()` to encrypt before saving
2. Modify `getFileData()` to decrypt after reading
3. Update file storage to use `EncryptedData` format

---

## File Management System

### Import Flow

1. **User Initiates Import**
   - From vault home page → Import dialog
   - Select files (photos, videos, documents, audio)
   - Multiple file selection supported

2. **Subscription Check**
   ```dart
   if (!subscriptionService.canAddItem(currentItemCount + files.length)) {
     // Show paywall
     await Navigator.push(PaywallPage());
   }
   ```

3. **File Processing**
   - For each file:
     - Generate unique file ID
     - Copy to vault directory (currently unencrypted)
     - Generate thumbnail (if photo/video)
     - Create metadata entry
     - Update index.json

4. **Source File Deletion**
   - Original files deleted from device after import
   - Exception: Camera captures (skip deletion)

### Export/Download Flow

1. **User Selects Files**
   - Single file or multiple selection
   - "Download All" option available

2. **Decryption Process**
   ```dart
   final fileData = await vaultService.getFileData(itemId, masterKey);
   // Currently returns raw file data (no decryption needed)
   ```

3. **Save to Downloads**
   - Android: `/storage/emulated/0/Download/`
   - iOS: App Documents directory
   - Filename format: `Nyx_Vault_<originalName>`
   - Duplicate handling: `_1`, `_2`, etc.

### Deletion Flow

1. **User Confirms Deletion**
2. **Delete Operations:**
   - Remove from `_items` list
   - Delete vault file (try multiple extensions)
   - Delete thumbnail file
   - Clear thumbnail cache
   - Update `index.json` and `index_backup.json`

### Album Management

- Albums are collections of vault items
- Stored in `index.json` under `albums` array
- Each album contains:
  - `id`: Unique album ID
  - `name`: Album name
  - `createdAt`: Creation timestamp
  - `itemIds`: Array of vault item IDs

---

## Browser Integration

### Location
`lib/features/vault/pages/browser_page.dart`

### Architecture

The browser is a full-featured WebView-based browser integrated into the vault.

#### 1. **Browser Features**

- Chrome-like interface with tabs
- Address bar (omnibox) with URL formatting
- Navigation controls (back, forward, refresh)
- Bookmarks and history
- Incognito mode
- Reader mode
- Desktop site mode
- Find in page
- Media detection and download

#### 2. **Media Detection**

```dart
final MediaDetectionService _mediaDetectionService = MediaDetectionService();
List<DetectedMedia> _detectedMedia = [];

Future<void> _detectMediaOnPage(int tabIndex) async {
  final controller = _tabs[tabIndex].controller;
  final result = await _mediaDetectionService.detectMediaFromWebView(
    controller,
    currentUrl: _currentUrl,
  );
  
  if (result.media.isNotEmpty) {
    setState(() {
      _detectedMedia = result.media;
      _showMediaDetected = true;
    });
  }
}
```

**Media Types Detected:**
- Progressive video (MP4, WebM, etc.)
- Progressive audio (MP3, M4A, etc.)
- Adaptive streams (HLS .m3u8, DASH .mpd)

#### 3. **Media Download to Vault**

```dart
Future<void> _saveMediaToVault(DetectedMedia media) async {
  // Generate filename
  String fileName = media.title ?? 'media_${DateTime.now().millisecondsSinceEpoch}';
  
  // Extract/download media
  if (media.type == MediaType.adaptiveStream) {
    // YouTube and other adaptive streams
    success = await _extractionEngine!.extractAdaptiveStream(
      manifestUrl: media.url,
      fileName: fileName,
      streamType: media.type,
      metadata: media.metadata,
    );
  } else {
    // Progressive media (direct download)
    success = await _extractionEngine!.extractProgressiveMedia(
      url: media.url,
      fileName: fileName,
      mediaType: media.type,
    );
  }
}
```

#### 4. **Session Management**

Browser sessions are saved to secure storage:
- Tab URLs and titles
- Current tab index
- Session timestamp

**Session Format:**
```json
{
  "tabs": [
    {
      "id": "1234567890",
      "url": "https://example.com",
      "title": "Example",
      "isIncognito": false
    }
  ],
  "currentTabIndex": 0,
  "timestamp": "2024-01-01T12:00:00Z"
}
```

**Note**: Incognito sessions are not saved.

#### 5. **Vault Integration**

- Browser can only be accessed when vault is unlocked
- Media downloads go directly to vault
- Browser history/bookmarks stored separately from vault items

---

## Data Flow Diagrams

### Unlock Flow

```
[Calculator Display]
    ↓
User enters trigger code
    ↓
User presses "=" twice
    ↓
[PIN Verification Dialog]
    ↓
[AuthService.verifyPIN()]
    ↓
Check decoy PIN → [Decoy Vault] OR
Check real PIN → [Real Vault]
    ↓
[VaultHomePage] (unlocked)
```

### File Import Flow

```
[VaultHomePage]
    ↓
User selects "Import"
    ↓
[File Picker] → Select files
    ↓
[SubscriptionService] → Check limits
    ↓
[MediaImportService.importFile()]
    ↓
[VaultService.importFile()]
    ↓
Generate file ID → Copy to vault → Generate thumbnail
    ↓
Update index.json
    ↓
Delete source file
    ↓
[VaultHomePage] → Refresh display
```

### Browser Media Download Flow

```
[BrowserPage]
    ↓
Page loads → [MediaDetectionService]
    ↓
Media detected → Show download UI
    ↓
User taps "Save"
    ↓
[MediaExtractionEngine]
    ↓
Download/Extract media
    ↓
[VaultDownloadManager]
    ↓
[VaultService.downloadAndEncryptToVault()]
    ↓
Save to vault → Update index
    ↓
[BrowserPage] → Show success
```

---

## Security Architecture

### Security Layers

1. **Disguise Layer**
   - Calculator interface hides vault existence
   - No visible indicators of privacy features
   - Unlock sequence is secret

2. **Authentication Layer**
   - PIN/Pattern with 100,000 iteration key derivation
   - Biometric authentication (optional)
   - Decoy vault support (plausible deniability)

3. **Encryption Layer** (Ready but not currently used for files)
   - AES-256-GCM encryption
   - Per-file key derivation (HKDF-like)
   - Zero-knowledge architecture (server never sees keys)

4. **Storage Layer**
   - Secure storage for credentials (Keychain/Keystore)
   - Vault directory for files (currently unencrypted)
   - Metadata index (currently unencrypted JSON)

### Security Considerations

**Current Implementation:**
- ✅ Strong key derivation (100,000 iterations)
- ✅ Secure credential storage (Keychain/Keystore)
- ✅ Decoy vault support
- ✅ Disguise mechanism
- ⚠️ Files stored unencrypted in vault directory
- ⚠️ Metadata index stored as plain JSON

**To Enable Full Encryption:**
1. Encrypt files before saving to vault
2. Decrypt files when reading from vault
3. Encrypt metadata index
4. Use encrypted file format (binary or JSON)

### Threat Model

**Protected Against:**
- Casual inspection (calculator disguise)
- Coercion (decoy vault)
- Credential theft (secure storage)
- Brute force (100,000 iterations)

**Not Protected Against (Current Implementation):**
- Physical device access with file system access (files unencrypted)
- Metadata analysis (index is plain JSON)
- Forensic analysis (unencrypted files visible)

**With Full Encryption Enabled:**
- All files encrypted with AES-256-GCM
- Metadata encrypted
- Requires master key to decrypt
- Strong protection against forensic analysis

---

## Key Technical Details

### File Naming Convention

- Files: `<32-byte-hex-id>.<extension>`
- Thumbnails: `<32-byte-hex-id>.jpg`
- Example: `a1b2c3d4e5f6...7890abcdef.mp4`

### Index File Format

```json
{
  "items": [
    {
      "id": "hex_string",
      "originalName": "filename.ext",
      "customName": null,
      "type": "photo|video|document|audio",
      "encryptedAt": "ISO8601_timestamp",
      "size": 1234567,
      "thumbnailId": "hex_string_or_null"
    }
  ],
  "albums": [
    {
      "id": "hex_string",
      "name": "Album Name",
      "createdAt": "ISO8601_timestamp",
      "itemIds": ["id1", "id2", ...]
    }
  ]
}
```

### Master Key Lifecycle

1. **Setup**: Derived from PIN/Pattern during setup
2. **Storage**: Never stored (only derived when needed)
3. **Unlock**: Derived from PIN/Pattern during unlock
4. **Memory**: Stored in `AuthService._masterKey` while unlocked
5. **Lock**: Cleared from memory when vault is locked

### Decoy Vault Mechanism

- Separate PIN/Pattern for decoy vault
- Separate master key derivation
- Separate vault items (if implemented)
- User cannot tell if they unlocked decoy or real vault
- Provides plausible deniability under coercion

---

## Conclusion

This architecture provides a sophisticated privacy vault system with:

1. **Strong Disguise**: Calculator interface hides vault existence
2. **Multi-Layer Security**: Authentication, encryption (ready), secure storage
3. **User Experience**: Full-featured browser, media detection, album management
4. **Extensibility**: Encryption service ready for file encryption implementation

**Next Steps for Full Security:**
- Enable file encryption in vault service
- Encrypt metadata index
- Implement encrypted file format
- Add tamper detection for index file

---

*Document generated for AI agent comprehension*
*Last updated: Based on current codebase analysis*

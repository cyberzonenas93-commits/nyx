# Technical Summary: Media Upload, Processing, and Playback Flow

## Table of Contents
1. [Media Upload Flow](#media-upload-flow)
2. [Media Processing in Vault](#media-processing-in-vault)
3. [Media Viewer Architecture](#media-viewer-architecture)
4. [Video Player Implementation](#video-player-implementation)

---

## Media Upload Flow

### Overview
The media upload system uses a **background import service** that processes files asynchronously without blocking the UI. Files can be imported from multiple sources: device photo/video library, camera capture, file picker, or browser downloads.

### Architecture Components

#### 1. **Entry Points** (`VaultHomePage`)
- **Photo Import**: `_importPhotos()` - Uses `ImagePicker` to select multiple photos
- **Video Import**: `_importVideos()` - Uses `ImagePicker` to select multiple videos
- **File Import**: `_importFiles()` - Uses `FilePicker` for general files
- **Camera Capture**: `_capturePhoto()` and `_recordVideo()` - Direct camera access

#### 2. **Background Import Service** (`BackgroundImportService`)

**Purpose**: Queue-based import system that processes files in background isolates to prevent UI blocking.

**Key Features**:
- **Queue Management**: Files are queued using `Queue<ImportTask>` with persistence to `SharedPreferences`
- **Background Execution**: Continues processing even when app is backgrounded using `BackgroundExecutionService`
- **Progress Tracking**: Broadcasts progress via `StreamController<ImportProgress>`
- **Memory Management**: Detects video playback and uses streaming for large files (>10MB) to prevent memory pressure

**Import Task Structure**:
```dart
ImportTask {
  String filePath;        // Source file path
  String filename;        // Original filename
  String? mimeType;       // MIME type if detected
  VaultItemSource source; // Source (camera, library, download, etc.)
  Map<String, dynamic>? metadata; // Additional metadata
  bool deleteOriginal;    // Whether to delete source after import
  String? folderId;        // Target folder ID (null = root)
}
```

**Processing Flow**:

1. **Queue Addition**:
   - Files are added to queue via `queueImports(List<ImportTask> tasks)`
   - Queue is persisted to `SharedPreferences` for recovery
   - Background processing starts if not already running

2. **File Reading**:
   - **Normal Mode**: Files read in isolate using `compute(_readFileInIsolate, filePath)`
   - **Streaming Mode** (when video playing + file >10MB):
     - Reads file in 1MB chunks
     - Yields every 1MB (`Future.delayed(Duration(milliseconds: 10))`)
     - Checks if video stopped playing to optimize speed
     - Prevents memory pressure during video playback

3. **Video Playback Detection**:
   ```dart
   final playbackManager = MediaPlaybackManager();
   final isVideoPlaying = playbackManager.isVideoPlaying;
   ```
   - If video is playing, imports pause briefly (500ms-1s)
   - Large files use streaming approach
   - Memory is cleared immediately after storage

4. **Storage**:
   - Files passed to `VaultService.storeFile()` with folder context
   - Original file deleted if `deleteOriginal = true`
   - Memory cleared immediately after storage

5. **Progress Updates**:
   - Progress broadcast via `StreamController`:
     ```dart
     ImportProgress {
       int current;      // Current file number
       int total;        // Total files
       String status;    // Status message
       bool isComplete;  // Whether import is complete
       int? successCount; // Success count
       int? failCount;   // Failure count
     }
     ```

### 3. **Vault Service Storage** (`VaultService.storeFile()`)

**File Storage Process**:

1. **File ID Generation**:
   - Cryptographically random UUID (never filename-based)
   - Format: `{uuid}.{extension}` (if extension available)

2. **File Type Detection**:
   - Analyzes filename and MIME type
   - Types: `photo`, `video`, `audio`, `document`, `unknown`

3. **File Writing**:
   - **Small Files (<5MB)**: Direct write using `File.writeAsBytes()`
   - **Large Files (≥5MB)**: Streaming write:
     - Chunk size: 512KB
     - Flush every 1MB (every 2 chunks)
     - Yield every 5ms to prevent memory pressure
     - Allows video playback to continue smoothly

4. **Vault Item Creation**:
   ```dart
   VaultItem {
     id: fileId,
     originalFilename: filename,
     type: fileType,
     mimeType: mimeType,
     sizeBytes: data.length,
     dateAdded: DateTime.now(),
     source: source,
     sourceUrl: sourceUrl,
     sourceSite: sourceSite,
     thumbnailId: null, // Set later
     metadata: metadata,
     isEncrypted: false, // Files stored unencrypted
   }
   ```

5. **Thumbnail Generation** (Asynchronous):
   - **Photos**: Generated immediately in isolate using `compute(_processImageThumbnail, data)`
     - Resized to 200x200px
     - JPEG quality: 75%
   - **Videos**: Generated asynchronously using `VideoThumbnail` package
     - Screenshot at 1 second mark (fallback to first frame)
     - Timeout: 15 seconds (1s frame), 10 seconds (first frame)
     - Max width: 200px, quality: 75%
   - Thumbnail saved to `{thumbnailsDirectory}/{fileId}_thumb.jpg`
   - Item updated with `thumbnailId` after generation

6. **Index Management**:
   - Item added to `_items` list immediately
   - Index save scheduled with debounce (2 seconds)
   - Uses atomic writes (temp file + rename) for safety

7. **Folder Assignment**:
   - If `folderId` provided, item added to folder via `addItemToFolder()`
   - Folder's `itemIds` list updated
   - Folder modification date updated

8. **iCloud Backup** (if enabled):
   - File queued for iCloud sync
   - Sync happens in background
   - Files always stored locally first (performance)

---

## Media Processing in Vault

### File Storage Architecture

**Storage Location**:
- **Local Storage**: `{appDocumentsDirectory}/vault/{vaultId}/`
- **Thumbnails**: `{appDocumentsDirectory}/vault/{vaultId}/thumbnails/`
- **Index**: `{appDocumentsDirectory}/vault/{vaultId}/index.json`
- **Albums**: `{appDocumentsDirectory}/vault/{vaultId}/albums.json`
- **Folders**: `{appDocumentsDirectory}/vault/{vaultId}/folders.json`

**File Naming**:
- Files stored with UUID as filename (no original filename)
- Original filename stored in `VaultItem.originalFilename`
- Thumbnails: `{fileId}_thumb.jpg`

### Thumbnail Processing

#### Photo Thumbnails
- **Processing**: Isolate-based using `compute()` function
- **Algorithm**: 
  ```dart
  _processImageThumbnail(Uint8List imageData) {
    final image = img.decodeImage(imageData);
    final thumbnail = img.copyResize(
      image, 
      width: 200,
      height: 200, 
      interpolation: img.Interpolation.linear,
    );
    return Uint8List.fromList(img.encodeJpg(thumbnail, quality: 75));
  }
  ```
- **Caching**: 
  - Memory cache: 30MB limit (FIFO eviction)
  - Disk cache: Managed by `ThumbnailCacheService`
  - Cache key: `{itemId}_{thumbnailId}`

#### Video Thumbnails
- **Package**: `video_thumbnail` (native implementation)
- **Strategy**:
  1. Try 1-second frame (15s timeout)
  2. Fallback to first frame (10s timeout)
  3. If both fail, return null (placeholder shown)
- **Format**: JPEG, 200px max width, 75% quality
- **Storage**: Same as photo thumbnails

### Index Management

**Index Structure**:
```json
{
  "version": 1,
  "lastUpdated": "ISO8601 timestamp",
  "items": [
    {
      "id": "uuid",
      "originalFilename": "filename.ext",
      "type": "photo|video|audio|document|unknown",
      "mimeType": "image/jpeg",
      "sizeBytes": 1234567,
      "dateAdded": "ISO8601",
      "source": "camera|library|download|...",
      "thumbnailId": "uuid_thumb",
      "isEncrypted": false
    }
  ]
}
```

**Saving Strategy**:
- **Debounced**: 2-second delay after last change
- **Atomic Writes**: Write to temp file, then rename
- **Streaming JSON** (for large indexes):
  - Writes JSON in chunks
  - Flushes periodically
  - Prevents memory issues with thousands of items

### Memory Management

**Thumbnail Cache**:
- **Memory Cache**: `Map<String, Uint8List>`
- **Size Limit**: 30MB
- **Eviction**: FIFO (oldest removed first)
- **Cache Key**: `thumbnailId`

**Photo Cache** (in viewer):
- **Size**: 30 photos max
- **Purpose**: Faster swiping in `VaultItemDetailPage`
- **Eviction**: FIFO

**File Data**:
- Files stored unencrypted (raw bytes)
- No in-memory caching of full files
- Temporary files created only for playback

---

## Media Viewer Architecture

### Overview
The `VaultItemDetailPage` provides a full-screen media viewer with swipe navigation, supporting photos, videos, audio, and documents.

### Component Structure

#### 1. **Page Controller** (`PageView.builder`)
- **Purpose**: Swipe navigation between items
- **Configuration**:
  - `allowImplicitScrolling: false` (performance)
  - `itemBuilder`: Only builds current ± 2 pages
  - Non-adjacent pages show loading indicator
- **Preloading**: Aggressive preloading of adjacent items (±2 pages)

#### 2. **File Loading** (`_loadFileDataForItem()`)

**Loading Strategy**:

1. **Cache Check** (Photos):
   - Check `_photoCache` first
   - If cached, use immediately (no loading state)

2. **Loading State**:
   - Set `_isLoading = true`
   - Clear previous errors

3. **File Retrieval**:
   ```dart
   final fileData = await vaultService.getFileData(item.id, masterKey: masterKey);
   ```
   - Files stored unencrypted, so no decryption needed
   - Direct read from vault directory

4. **Race Condition Prevention**:
   - Check `_currentItem.id == item.id` after each async operation
   - Discard results if item changed during load
   - Prevents stale data from being displayed

5. **Type-Specific Processing**:
   - **Photos**: Display immediately from memory
   - **Videos**: Initialize video player (async)
   - **Audio**: Initialize audio player (async)
   - **Documents**: Create temp file for external viewer

6. **Photo Caching**:
   - Cache loaded photos in `_photoCache`
   - Limit: 30 photos (FIFO eviction)
   - Enables smooth swiping

#### 3. **Photo Viewer** (`PhotoViewerWidget`)

**Features**:
- Pinch-to-zoom
- Pan gestures
- Tap to show/hide controls
- Share functionality

**Implementation**:
- Uses `photo_view` package for zoom/pan
- Displays from `Uint8List` directly (no temp file needed)

#### 4. **Document Viewer**

**PDF Support**:
- Uses `syncfusion_flutter_pdfviewer`
- Creates temporary file from vault data
- Full PDF viewing with zoom/scroll

**Other Documents**:
- Uses `open_filex` package
- Opens in external app
- Temporary file created and cleaned up after viewing

---

## Video Player Implementation

### Architecture

#### 1. **Video Player Widget** (`VideoPlayerWidget`)

**Purpose**: Full-featured video player with advanced controls and gesture support.

**Key Features**:
- Auto-play on initialization
- Auto-fullscreen for portrait videos
- Gesture controls (volume, brightness, seek)
- Playback speed control (0.25x - 2.0x)
- Loop support
- Immersive fullscreen mode

#### 2. **Video Initialization** (`_initializeVideoPlayer()`)

**Process**:

1. **Cancellation Check**:
   - Check `_isVideoInitCancelled` flag
   - Check `_currentVideoInitId` matches current item
   - Prevents initialization of wrong video

2. **File Validation**:
   - Check file size (minimum 1KB)
   - Verify video file headers
   - Detect AV1 codec (not supported on iOS)

3. **Format Detection**:
   - Primary: File extension from filename
   - Secondary: MIME type analysis
   - Tertiary: File header analysis (MP4, WebM, AVI, etc.)

4. **Temporary File Creation**:
   ```dart
   _videoFile = File('${tempDir.path}/video_${itemId}_${timestamp}.${extension}');
   ```
   - Created in system temp directory
   - Unique filename per item
   - Cleaned up on dispose

5. **File Writing** (Chunked):
   - Write in 1MB chunks
   - Check cancellation after each chunk
   - Yield control periodically (`Future.delayed(Duration.zero)`)
   - Prevents UI blocking during large file writes

6. **Controller Initialization**:
   ```dart
   _videoController = VideoPlayerController.file(_videoFile);
   await _videoController!.initialize();
   ```
   - Initialize controller with temp file
   - Register with `MediaPlaybackManager`
   - Set looping if enabled

7. **Auto-Play & Fullscreen**:
   - If `autoPlay = true`: Start playback immediately
   - If `autoFullscreen = true`: Enter fullscreen
   - Detect video orientation (portrait vs landscape)
   - Set appropriate orientation lock

#### 3. **Orientation Handling**

**Portrait Videos**:
- Auto-enter fullscreen portrait mode
- Hide all UI elements (immersive)
- Tap to show controls overlay
- System UI hidden (`SystemUiMode.immersiveSticky`)

**Landscape Videos**:
- Auto-enter fullscreen landscape mode
- Controls overlay visible
- System UI hidden

**Orientation Detection**:
```dart
final videoAspectRatio = controller.value.aspectRatio;
final isVideoPortrait = videoAspectRatio > 0 && videoAspectRatio < 1.0;
final isVideoLandscape = videoAspectRatio >= 1.0;
```

#### 4. **Gesture Controls**

**Vertical Gestures** (Left Side):
- **Volume Control**: Swipe up/down
- Visual feedback with volume indicator

**Vertical Gestures** (Right Side):
- **Brightness Control**: Swipe up/down
- Visual feedback with brightness indicator

**Horizontal Gestures**:
- **Seek**: Swipe left/right
- 10-second skip forward/backward
- Visual position indicator

**Tap Gestures**:
- **Single Tap**: Show/hide controls
- **Double Tap**: Play/pause
- **Tap Left/Right**: Skip 10 seconds

#### 5. **Playback Controls**

**Standard Controls**:
- Play/Pause button
- Seek bar with position indicator
- Volume slider
- Brightness slider (in settings)
- Playback speed selector (0.25x, 0.5x, 0.75x, 1.0x, 1.25x, 1.5x, 2.0x)
- Fullscreen toggle
- Settings menu

**Advanced Features**:
- **Looping**: Automatic restart when video ends
- **Speed Control**: Adjustable playback speed
- **Volume Control**: System volume + gesture control
- **Brightness Control**: System brightness + gesture control

#### 6. **Memory Management**

**Video Controller Lifecycle**:
- **Registration**: Registered with `MediaPlaybackManager` on initialization
- **Unregistration**: Unregistered on dispose
- **Cleanup**: Temp file deleted on dispose

**Playback Manager**:
- Tracks currently playing video
- Prevents multiple videos playing simultaneously
- Used by import service to detect playback state

**Cancellation Handling**:
- When swiping to new video:
  1. Set `_isVideoInitCancelled = true`
  2. Dispose previous controller (async)
  3. Clean up previous temp file (async)
  4. Start new video initialization

#### 7. **Error Handling**

**AV1 Codec Detection**:
- Checks file headers for AV1 codec
- Shows error message: "AV1 video format is not supported on iOS"
- Prevents initialization attempt

**Initialization Failures**:
- Catches all exceptions during initialization
- Sets `_videoError` state
- Shows error message to user
- Allows retry or navigation away

**File Corruption**:
- Validates file size (minimum 1KB)
- Checks file headers
- Validates video format before initialization

---

## Performance Optimizations

### Upload Optimizations

1. **Isolate-Based Reading**: Files read in separate isolates to prevent UI blocking
2. **Streaming Writes**: Large files written in chunks with periodic yields
3. **Video Playback Detection**: Pauses imports when video is playing
4. **Memory Management**: Immediate memory clearing after storage
5. **Debounced Index Saves**: Reduces disk I/O frequency

### Viewer Optimizations

1. **Photo Caching**: 30-photo cache for smooth swiping
2. **Preloading**: Aggressive preloading of adjacent items (±2 pages)
3. **Lazy Loading**: Only builds visible and adjacent pages
4. **Race Condition Prevention**: Validates item ID after each async operation
5. **Cancellation**: Cancels ongoing operations when swiping to new item

### Video Player Optimizations

1. **Chunked File Writing**: 1MB chunks with periodic yields
2. **Cancellation Checks**: Multiple checkpoints during initialization
3. **Controller Reuse**: Reuses controller if same video already playing
4. **Async Disposal**: Disposes previous controllers asynchronously
5. **Memory Cleanup**: Immediate temp file deletion on dispose

### Thumbnail Optimizations

1. **Memory Cache**: 30MB limit with FIFO eviction
2. **Disk Cache**: Persistent cache for faster loading
3. **Isolate Processing**: Photo thumbnails generated in isolates
4. **Async Generation**: Thumbnails generated in background
5. **On-Demand Loading**: Thumbnails loaded only when needed

---

## Data Flow Diagrams

### Upload Flow
```
User Action (Import/Capture)
    ↓
BackgroundImportService.queueImports()
    ↓
Queue Persisted to SharedPreferences
    ↓
_processQueueInternal() [Background]
    ↓
For each file:
    ├─ Check video playback state
    ├─ Read file (isolate or streaming)
    ├─ VaultService.storeFile()
    │   ├─ Generate file ID
    │   ├─ Write file (chunked if large)
    │   ├─ Create VaultItem
    │   ├─ Generate thumbnail (async)
    │   └─ Update index (debounced)
    ├─ Clear memory
    └─ Delete original (if requested)
    ↓
Progress Updates via Stream
    ↓
Complete → Clear Queue
```

### Video Playback Flow
```
User Opens Video
    ↓
VaultItemDetailPage._loadFileDataForItem()
    ↓
vaultService.getFileData() [Unencrypted Read]
    ↓
_initializeVideoPlayer()
    ├─ Validate file data
    ├─ Detect format
    ├─ Create temp file (chunked write)
    ├─ VideoPlayerController.file()
    ├─ controller.initialize()
    ├─ Register with MediaPlaybackManager
    └─ Auto-play + Auto-fullscreen
    ↓
VideoPlayerWidget
    ├─ Gesture handling
    ├─ Control overlay
    └─ Playback management
    ↓
On Dispose:
    ├─ Pause playback
    ├─ Unregister from manager
    ├─ Dispose controller
    └─ Delete temp file
```

---

## Security Considerations

### File Storage
- **Unencrypted Storage**: Files stored as raw bytes (no encryption)
- **Vault Access**: Protected by trigger code and PIN authentication
- **File IDs**: Cryptographically random UUIDs (not filename-based)
- **Directory Structure**: Hidden in app documents directory

### Authentication
- **Master Key**: Derived from PIN using HMAC-SHA256 (100,000 iterations)
- **Vault Initialization**: Requires master key for access
- **Session Management**: Master key cleared on vault lock

### Data Privacy
- **No Cloud Sync**: Files stored locally only (unless iCloud backup enabled)
- **Temporary Files**: Created only for playback, deleted immediately
- **Memory Clearing**: File data cleared from memory after use

---

## Error Handling & Recovery

### Upload Errors
- **File Read Failures**: Logged, file skipped, import continues
- **Storage Failures**: Logged, error reported to user
- **Thumbnail Failures**: Logged, placeholder shown
- **Queue Persistence**: Queue saved to recover from crashes

### Playback Errors
- **Initialization Failures**: Error message shown, user can retry
- **Codec Unsupported**: Clear error message (e.g., AV1)
- **File Corruption**: Validation before initialization
- **Network Errors**: N/A (local files only)

### Recovery Mechanisms
- **Queue Persistence**: Import queue survives app restarts
- **Index Atomic Writes**: Prevents corruption from crashes
- **Thumbnail Regeneration**: On-demand regeneration if missing
- **Controller Cleanup**: Proper disposal prevents memory leaks

---

## Future Enhancements

### Potential Improvements
1. **Video Transcoding**: Convert unsupported formats on import
2. **Thumbnail Preloading**: Generate thumbnails during import
3. **Batch Operations**: Optimize bulk imports
4. **Cloud Sync**: Optional cloud backup with encryption
5. **Format Support**: Additional video/audio codecs
6. **Streaming**: Stream large videos without full download
7. **Compression**: Optional image/video compression on import

---

## Conclusion

The media upload, processing, and playback system is designed for:
- **Performance**: Non-blocking operations, efficient memory usage
- **Reliability**: Error handling, recovery mechanisms, atomic operations
- **User Experience**: Smooth playback, responsive UI, background processing
- **Scalability**: Handles large files, many items, concurrent operations

The architecture separates concerns cleanly:
- **BackgroundImportService**: Handles file reading and queuing
- **VaultService**: Manages storage, thumbnails, and indexing
- **VaultItemDetailPage**: Handles viewing and playback
- **VideoPlayerWidget**: Provides video playback functionality

This separation enables independent optimization and maintenance of each component.

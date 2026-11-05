import Flutter
import UIKit
import AVFoundation
import AVKit
import AVFAudio
import CryptoKit

/// Vault file encryption with CryptoKit, byte-compatible with the Dart
/// VaultCipher format:
///   [0x01] then chunks of [12-byte nonce][ciphertext][16-byte tag],
///   1 MiB of plaintext per chunk (last one shorter; an empty file is one
///   empty chunk), AAD = aadPrefix(8) || chunkIndex as 4 bytes big-endian.
/// Dart derives the per-file key and the AAD prefix and passes them in.
enum VaultCrypto {
  static let versionByte: UInt8 = 0x01
  static let chunkSize = 1024 * 1024
  static let nonceLength = 12
  static let tagLength = 16
  static let chunkOnDisk = 12 + 1024 * 1024 + 16
  private static let queue = DispatchQueue(label: "com.angelonartey.nyx.vaultcrypto", qos: .userInitiated, attributes: .concurrent)

  struct Failure: Error {
    let code: String
    let message: String
  }

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let src = args["src"] as? String,
          let keyData = (args["key"] as? FlutterStandardTypedData)?.data,
          let prefix = (args["aadPrefix"] as? FlutterStandardTypedData)?.data,
          keyData.count == 32, prefix.count == 8 else {
      result(FlutterError(code: "INVALID_ARGS", message: "src, 32-byte key and 8-byte aadPrefix are required", details: nil))
      return
    }
    let key = SymmetricKey(data: keyData)
    queue.async {
      var reply: Any? = nil
      do {
        switch call.method {
        case "encryptFile":
          guard let dst = args["dst"] as? String else { throw Failure(code: "INVALID_ARGS", message: "dst is required") }
          let (bytes, digest) = try encryptFile(src: src, dst: dst, key: key, prefix: prefix, hash: (args["computeSha256"] as? Bool) ?? false)
          var map: [String: Any] = ["bytes": bytes]
          if let digest = digest { map["sha256"] = digest }
          reply = map
        case "decryptFile":
          guard let dst = args["dst"] as? String else { throw Failure(code: "INVALID_ARGS", message: "dst is required") }
          reply = try decryptFile(src: src, dst: dst, key: key, prefix: prefix)
        case "plainSha256":
          reply = try plainSha256(src: src, key: key, prefix: prefix)
        case "decryptChunks":
          let first = (args["first"] as? Int) ?? 0
          let count = (args["count"] as? Int) ?? 1
          reply = FlutterStandardTypedData(bytes: try decryptChunks(src: src, key: key, prefix: prefix, first: first, count: count))
        default:
          reply = FlutterMethodNotImplemented
        }
      } catch let failure as Failure {
        reply = FlutterError(code: failure.code, message: failure.message, details: nil)
      } catch {
        reply = FlutterError(code: "CRYPTO", message: "\(error)", details: nil)
      }
      DispatchQueue.main.async { result(reply) }
    }
  }

  private static func aad(_ prefix: Data, _ index: Int) -> Data {
    var data = prefix
    data.append(contentsOf: [UInt8((index >> 24) & 0xFF), UInt8((index >> 16) & 0xFF), UInt8((index >> 8) & 0xFF), UInt8(index & 0xFF)])
    return data
  }

  private static func ioFailure(_ what: String) -> Failure {
    Failure(code: "IO", message: "\(what): \(String(cString: strerror(errno)))")
  }

  private static func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard var ptr = raw.baseAddress else { return }
      var left = raw.count
      while left > 0 {
        let n = write(fd, ptr, left)
        if n < 0 {
          if errno == EINTR { continue }
          throw ioFailure("write")
        }
        left -= n
        ptr += n
      }
    }
  }

  /// Reads up to [count] bytes at [offset]; short only at end of file.
  private static func readAt(_ fd: Int32, _ offset: Int, _ count: Int) throws -> Data {
    var buffer = Data(count: count)
    var filled = 0
    try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      while filled < count {
        let n = pread(fd, raw.baseAddress! + filled, count - filled, off_t(offset + filled))
        if n < 0 {
          if errno == EINTR { continue }
          throw ioFailure("read")
        }
        if n == 0 { break }
        filled += n
      }
    }
    if filled < count { buffer.removeSubrange(filled..<count) }
    return buffer
  }

  private static func open(_ chunk: Data, key: SymmetricKey, prefix: Data, index: Int) throws -> Data {
    guard chunk.count >= nonceLength + tagLength else {
      throw Failure(code: "FORMAT", message: "Truncated chunk \(index)")
    }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: chunk.prefix(nonceLength)),
        ciphertext: chunk.dropFirst(nonceLength).dropLast(tagLength),
        tag: chunk.suffix(tagLength))
      return try AES.GCM.open(box, using: key, authenticating: aad(prefix, index))
    } catch {
      throw Failure(code: "AUTH_FAILED", message: "Authentication failed for chunk \(index)")
    }
  }

  private static func checkVersion(_ fd: Int32) throws {
    let first = try readAt(fd, 0, 1)
    guard first.first == versionByte else {
      throw Failure(code: "FORMAT", message: "Unsupported version byte")
    }
  }

  static func encryptFile(src: String, dst: String, key: SymmetricKey, prefix: Data, hash: Bool) throws -> (Int, String?) {
    let input = Darwin.open(src, O_RDONLY)
    guard input >= 0 else { throw ioFailure("open source") }
    defer { close(input) }
    let output = Darwin.open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard output >= 0 else { throw ioFailure("open destination") }
    var ok = false
    defer {
      close(output)
      if !ok { unlink(dst) }
    }
    try writeAll(output, Data([versionByte]))
    var hasher = SHA256()
    var index = 0
    var total = 0
    while true {
      let plain = try autoreleasepool { () -> Data in
        let chunk = try readAt(input, total, chunkSize)
        if chunk.isEmpty && index > 0 { return chunk }
        if hash { hasher.update(data: chunk) }
        let box = try AES.GCM.seal(chunk, using: key, nonce: AES.GCM.Nonce(), authenticating: aad(prefix, index))
        var out = Data(capacity: nonceLength + chunk.count + tagLength)
        box.nonce.withUnsafeBytes { out.append(contentsOf: $0) }
        out.append(box.ciphertext)
        out.append(box.tag)
        try writeAll(output, out)
        return chunk
      }
      if plain.isEmpty && index > 0 { break }
      total += plain.count
      index += 1
      if plain.count < chunkSize { break }
    }
    guard fsync(output) == 0 else { throw ioFailure("fsync") }
    ok = true
    let digest = hash ? hasher.finalize().map { String(format: "%02x", $0) }.joined() : nil
    return (total, digest)
  }

  static func decryptFile(src: String, dst: String, key: SymmetricKey, prefix: Data) throws -> Int {
    let input = Darwin.open(src, O_RDONLY)
    guard input >= 0 else { throw ioFailure("open source") }
    defer { close(input) }
    var info = stat()
    guard fstat(input, &info) == 0 else { throw ioFailure("stat") }
    let size = Int(info.st_size)
    try checkVersion(input)
    let output = Darwin.open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard output >= 0 else { throw ioFailure("open destination") }
    var ok = false
    defer {
      close(output)
      if !ok { unlink(dst) }
    }
    var index = 0
    var total = 0
    var offset = 1
    while offset < size {
      try autoreleasepool {
        let chunk = try readAt(input, offset, min(chunkOnDisk, size - offset))
        let plain = try open(chunk, key: key, prefix: prefix, index: index)
        try writeAll(output, plain)
        total += plain.count
        offset += chunk.count
        index += 1
      }
    }
    ok = true
    return total
  }

  /// Lowercase hex SHA-256 of the plaintext, decrypted chunk by chunk in memory;
  /// nothing is written to disk. Used to find duplicate vault files.
  static func plainSha256(src: String, key: SymmetricKey, prefix: Data) throws -> String {
    let input = Darwin.open(src, O_RDONLY)
    guard input >= 0 else { throw ioFailure("open source") }
    defer { close(input) }
    var info = stat()
    guard fstat(input, &info) == 0 else { throw ioFailure("stat") }
    let size = Int(info.st_size)
    try checkVersion(input)
    var hasher = SHA256()
    var index = 0
    var offset = 1
    while offset < size {
      try autoreleasepool {
        let chunk = try readAt(input, offset, min(chunkOnDisk, size - offset))
        hasher.update(data: try open(chunk, key: key, prefix: prefix, index: index))
        offset += chunk.count
        index += 1
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func decryptChunks(src: String, key: SymmetricKey, prefix: Data, first: Int, count: Int) throws -> Data {
    let input = Darwin.open(src, O_RDONLY)
    guard input >= 0 else { throw ioFailure("open source") }
    defer { close(input) }
    var info = stat()
    guard fstat(input, &info) == 0 else { throw ioFailure("stat") }
    let size = Int(info.st_size)
    try checkVersion(input)
    var out = Data(capacity: max(0, count) * chunkSize)
    var index = max(0, first)
    while index < first + count {
      let offset = 1 + index * chunkOnDisk
      if offset >= size { break }
      try autoreleasepool {
        let chunk = try readAt(input, offset, min(chunkOnDisk, size - offset))
        out.append(try open(chunk, key: key, prefix: prefix, index: index))
      }
      index += 1
    }
    return out
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let securityViewTag = 9999
  private var pendingSharedFiles: [String]? = nil
  private var shareChannel: FlutterMethodChannel? = nil
  private var voiceRecorderChannel: FlutterMethodChannel? = nil
  private var audioRecorder: AVAudioRecorder? = nil
  private var currentRecordingPath: String? = nil
  private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()

    shareChannel = FlutterMethodChannel(name: "com.nyx.app/share_handler", binaryMessenger: messenger)
    shareChannel?.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "getSharedFiles" {
        let files = self?.pendingSharedFiles
        self?.pendingSharedFiles = nil
        result(files)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    voiceRecorderChannel = FlutterMethodChannel(name: "com.nyx.app/voice_recorder", binaryMessenger: messenger)
    voiceRecorderChannel?.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else {
        result(FlutterError(code: "UNAVAILABLE", message: "AppDelegate not available", details: nil))
        return
      }
      switch call.method {
      case "startRecording":
        if let filePath = call.arguments as? [String: Any], let path = filePath["filePath"] as? String {
          result(self.startRecording(filePath: path))
        } else {
          result(FlutterError(code: "INVALID_ARGUMENT", message: "filePath is required", details: nil))
        }
      case "stopRecording":
        result(self.stopRecording())
      case "cancelRecording":
        self.cancelRecording()
        result(nil)
      case "isRecording":
        result(self.audioRecorder != nil && self.audioRecorder!.isRecording)
      case "getDuration":
        if let recorder = self.audioRecorder, recorder.isRecording {
          result(Int(recorder.currentTime * 1000))
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let iCloudChannel = FlutterMethodChannel(name: "com.angelonartey.nyx/icloud", binaryMessenger: messenger)
    iCloudChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "getICloudContainerPath" {
        if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
          let documentsPath = containerURL.appendingPathComponent("Documents")
          try? FileManager.default.createDirectory(at: documentsPath, withIntermediateDirectories: true, attributes: nil)
          result(documentsPath.path)
        } else {
          result(nil)
        }
      } else if call.method == "excludeFromBackup" {
        // Vault thumbnails are poster frames of the user's private media and
        // live under Documents, which iCloud/iTunes back up by default. Mark
        // them excluded so a recognizable frame of every vault video does not
        // leave the device in a backup.
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "path is required", details: nil))
          return
        }
        var url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
          result(false)
          return
        }
        do {
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try url.setResourceValues(values)
          result(true)
        } catch {
          result(FlutterError(code: "EXCLUDE_FAILED", message: error.localizedDescription, details: nil))
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let mediaConverterChannel = FlutterMethodChannel(name: "com.angelonartey.nyx/media_converter", binaryMessenger: messenger)
    mediaConverterChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { result(FlutterError(code: "UNAVAILABLE", message: "AppDelegate not available", details: nil)); return }
      if call.method == "convertVideoToAudio" {
        guard let args = call.arguments as? [String: Any],
              let videoPath = args["videoPath"] as? String,
              let outputPath = args["outputPath"] as? String,
              let format = args["format"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing required arguments", details: nil))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          self.convertVideoToAudio(videoPath: videoPath, outputPath: outputPath, format: format) { success, error in
            DispatchQueue.main.async {
              if success { result(outputPath) } else { result(FlutterError(code: "CONVERSION_FAILED", message: error ?? "Unknown error", details: nil)) }
            }
          }
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // Hardware AES-GCM for vault files. Same on-disk format as the Dart
    // VaultCipher (lib/core/services/vault_cipher.dart); see NativeVaultCrypto.
    let vaultCryptoChannel = FlutterMethodChannel(name: "com.angelonartey.nyx/vault_crypto", binaryMessenger: messenger)
    vaultCryptoChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      VaultCrypto.handle(call, result: result)
    }

    let backgroundExecutionChannel = FlutterMethodChannel(name: "com.nyx.app/background_execution", binaryMessenger: messenger)
    backgroundExecutionChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self, let application = UIApplication.shared as? UIApplication else { result(nil); return }
      switch call.method {
      case "requestBackgroundExecution":
        let args = call.arguments as? [String: Any]
        let reason = args?["reason"] as? String ?? "BackgroundTask"
        self.backgroundTaskID = application.beginBackgroundTask(withName: reason) {
          if self.backgroundTaskID != .invalid {
            application.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
          }
        }
        do {
          let audioSession = AVAudioSession.sharedInstance()
          try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
          try audioSession.setActive(true)
        } catch { print("Failed to activate audio session for background: \(error)") }
        result(true)
      case "endBackgroundExecution":
        if self.backgroundTaskID != .invalid {
          application.endBackgroundTask(self.backgroundTaskID)
          self.backgroundTaskID = .invalid
        }
        result(nil)
      case "updateProgress":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
      try audioSession.setActive(true)
    } catch {
      print("Failed to configure audio session: \(error)")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  private func startRecording(filePath: String) -> Bool {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      // Use .record category for background recording without playback
      // Set options to allow recording in background and mix with other audio
      try audioSession.setCategory(.record, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
      
      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
      ]
      
      let url = URL(fileURLWithPath: filePath)
      audioRecorder = try AVAudioRecorder(url: url, settings: settings)
      
      // Enable recording in background
      audioRecorder?.record()
      currentRecordingPath = filePath
      
      // Keep audio session active for background recording
      try audioSession.setActive(true)
      
      return true
    } catch {
      print("Error starting recording: \(error)")
      audioRecorder = nil
      currentRecordingPath = nil
      return false
    }
  }
  
  private func stopRecording() -> String? {
    audioRecorder?.stop()
    let path = currentRecordingPath
    audioRecorder = nil
    currentRecordingPath = nil
    
    do {
      try AVAudioSession.sharedInstance().setActive(false)
    } catch {
      print("Error deactivating audio session: \(error)")
    }
    
    return path
  }
  
  private func cancelRecording() {
    audioRecorder?.stop()
    if let path = currentRecordingPath {
      try? FileManager.default.removeItem(atPath: path)
    }
    audioRecorder = nil
    currentRecordingPath = nil
    
    do {
      try AVAudioSession.sharedInstance().setActive(false)
    } catch {
      print("Error deactivating audio session: \(error)")
    }
  }
  
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    // Handle share extension URLs
    handleShareURL(url)
    return true
  }
  
  private func handleShareURL(_ url: URL) {
    // Share extension passes files via file:// URLs
    // Extract file paths from the URL
    if url.scheme == "file" {
      pendingSharedFiles = [url.path]
    }
  }
  
  // Convert video to audio using AVFoundation
  private func convertVideoToAudio(videoPath: String, outputPath: String, format: String, completion: @escaping (Bool, String?) -> Void) {
    // Verify input file exists
    guard FileManager.default.fileExists(atPath: videoPath) else {
      DispatchQueue.main.async {
        completion(false, "Input video file does not exist at path: \(videoPath)")
      }
      return
    }
    
    let videoURL = URL(fileURLWithPath: videoPath)
    let outputURL = URL(fileURLWithPath: outputPath)
    
    // Create output directory if it doesn't exist
    let outputDir = outputURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)
      
      // Verify directory was created and is writable
      guard FileManager.default.fileExists(atPath: outputDir.path) else {
        DispatchQueue.main.async {
          completion(false, "Failed to create output directory: Directory does not exist after creation")
        }
        return
      }
      
      guard FileManager.default.isWritableFile(atPath: outputDir.path) else {
        DispatchQueue.main.async {
          completion(false, "Output directory is not writable: \(outputDir.path)")
        }
        return
      }
    } catch {
      DispatchQueue.main.async {
        completion(false, "Failed to create output directory: \(error.localizedDescription)")
      }
      return
    }
    
    // Remove existing output file if it exists
    if FileManager.default.fileExists(atPath: outputURL.path) {
      do {
        try FileManager.default.removeItem(at: outputURL)
      } catch {
        print("[MediaConverter] Warning: Could not remove existing output file: \(error.localizedDescription)")
        // Continue anyway - export session should overwrite it
      }
    }
    
    let asset = AVAsset(url: videoURL)
    
    // Load asset properties asynchronously
    asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
      // Check if loading was successful
      var loadingError: NSError?
      let durationStatus = asset.statusOfValue(forKey: "duration", error: &loadingError)
      let tracksStatus = asset.statusOfValue(forKey: "tracks", error: &loadingError)
      
      guard durationStatus == .loaded && tracksStatus == .loaded else {
        DispatchQueue.main.async {
          let errorMsg = loadingError?.localizedDescription ?? "Failed to load asset properties"
          completion(false, errorMsg)
        }
        return
      }
      
      // Create a composition with only audio track
      let composition = AVMutableComposition()
      
      // Find audio track
      guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
        DispatchQueue.main.async {
          completion(false, "No audio track found in video")
        }
        return
      }
      
      // Add audio track to composition
      guard let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        DispatchQueue.main.async {
          completion(false, "Failed to create audio track in composition")
        }
        return
      }
      
      do {
        let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
      } catch {
        DispatchQueue.main.async {
          completion(false, "Failed to insert audio track: \(error.localizedDescription)")
        }
        return
      }
      
      // Only M4A is supported - use AVAssetExportPresetAppleM4A
      let fileType: AVFileType = .m4a
      let presetName: String = AVAssetExportPresetAppleM4A
      let needsConversion: Bool = false
      
      // Create export session with audio-only composition
      guard let exportSession = AVAssetExportSession(asset: composition, presetName: presetName) else {
        DispatchQueue.main.async {
          completion(false, "Failed to create export session")
        }
        return
      }
      
      // Set output URL and file type for M4A
      exportSession.outputURL = outputURL
      exportSession.outputFileType = fileType
      exportSession.shouldOptimizeForNetworkUse = true
      
      // Export asynchronously
      exportSession.exportAsynchronously {
        switch exportSession.status {
        case .completed:
          // Verify output file exists and has content
          DispatchQueue.main.async {
            if FileManager.default.fileExists(atPath: outputPath) {
              let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int64) ?? 0
              if fileSize > 0 {
                completion(true, nil)
              } else {
                completion(false, "Export completed but file is empty")
              }
            } else {
              completion(false, "Export completed but output file not found")
            }
          }
        case .failed:
          let errorMsg = exportSession.error?.localizedDescription ?? "Export failed"
          print("[MediaConverter] Export failed: \(errorMsg)")
          if let error = exportSession.error {
            print("[MediaConverter] Error details: \(error)")
            print("[MediaConverter] Error code: \((error as NSError).code)")
            print("[MediaConverter] Error domain: \((error as NSError).domain)")
            if let outputURL = exportSession.outputURL {
              print("[MediaConverter] Output URL: \(outputURL)")
              print("[MediaConverter] Output URL exists: \(FileManager.default.fileExists(atPath: outputURL.path))")
              print("[MediaConverter] Output directory writable: \(FileManager.default.isWritableFile(atPath: outputURL.deletingLastPathComponent().path))")
            } else {
              print("[MediaConverter] Output URL: nil")
            }
          }
          DispatchQueue.main.async {
            // Provide more specific error message
            let specificError = exportSession.error?.localizedDescription ?? "Cannot write output file"
            completion(false, specificError)
          }
        case .cancelled:
          DispatchQueue.main.async {
            completion(false, "Export cancelled")
          }
        default:
          DispatchQueue.main.async {
            completion(false, "Unknown export status: \(exportSession.status.rawValue)")
          }
        }
      }
    }
  }
}

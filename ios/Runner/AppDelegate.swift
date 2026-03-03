import Flutter
import UIKit
import AVFoundation
import AVKit
import AVFAudio

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

    let backgroundExecutionChannel = FlutterMethodChannel(name: "com.nyx.app/background_execution", binaryMessenger: messenger)
    backgroundExecutionChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self, let application = UIApplication.shared as? UIApplication else { result(nil); return }
      switch call.method {
      case "requestBackgroundExecution":
        self.backgroundTaskID = application.beginBackgroundTask(withName: "ImportTask") {
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

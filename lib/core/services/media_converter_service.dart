import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Service for converting video files to audio files
/// Uses native platform channels for conversion (AVFoundation on iOS, MediaCodec on Android)
class MediaConverterService {
  static final MediaConverterService _instance = MediaConverterService._internal();
  factory MediaConverterService() => _instance;
  MediaConverterService._internal();

  static const MethodChannel _channel = MethodChannel('com.angelonartey.nyx/media_converter');

  /// Convert video file to audio file
  /// Returns the path to the converted audio file, or null if conversion failed
  Future<String?> convertVideoToAudio({
    required String videoFilePath,
    required String outputFormat, // 'm4a' (only supported format)
    Function(double progress)? onProgress,
  }) async {
    try {
      debugPrint('[MediaConverter] Starting conversion: $videoFilePath -> $outputFormat');
      
      // Validate input file
      final inputFile = File(videoFilePath);
      if (!await inputFile.exists()) {
        debugPrint('[MediaConverter] Input file does not exist: $videoFilePath');
        return null;
      }

      // Create output file path
      final tempDir = await getTemporaryDirectory();
      final inputFileName = inputFile.path.split('/').last.split('.').first;
      
      // Use the requested format directly (all formats are natively supported)
      final actualFormat = outputFormat;
      final outputFileName = '$inputFileName.$actualFormat';
      final outputPath = '${tempDir.path}/$outputFileName';

      // Remove existing output file if it exists
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }

      debugPrint('[MediaConverter] Using platform channel for conversion');

      // Use platform channel for native conversion
      try {
        final result = await _channel.invokeMethod<String>('convertVideoToAudio', {
          'videoPath': videoFilePath,
          'outputPath': outputPath,
          'format': actualFormat,
        });

        if (result != null && await File(result).exists()) {
          final outputSize = await File(result).length();
          debugPrint('[MediaConverter] Conversion successful: $result (${outputSize} bytes)');
          return result;
        } else {
          debugPrint('[MediaConverter] Conversion completed but output file not found');
          return null;
        }
      } on PlatformException catch (e) {
        debugPrint('[MediaConverter] Platform conversion failed: ${e.message}');
        return null;
      }
    } catch (e, stackTrace) {
      debugPrint('[MediaConverter] Error converting video to audio: $e');
      debugPrint('[MediaConverter] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Get supported audio formats
  List<String> getSupportedAudioFormats() {
    // Only M4A is supported
    return ['m4a'];
  }

  /// Get recommended audio format for a given video format
  String getRecommendedAudioFormat(String videoFormat) {
    // Always return M4A (only supported format)
    return 'm4a';
  }

  /// Check if a video format can be converted
  bool canConvertVideoFormat(String videoFormat) {
    final supportedVideoFormats = [
      'mp4', 'm4v', 'mov', 'avi', 'mkv', 'webm', 
      'flv', 'wmv', '3gp', 'ogv', 'mpeg', 'mpg'
    ];
    return supportedVideoFormats.contains(videoFormat.toLowerCase());
  }
}

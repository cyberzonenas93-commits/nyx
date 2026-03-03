package com.nyx.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.media.MediaRecorder
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaCodec
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.ByteBuffer

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.nyx.app/share_handler"
    private val VOICE_RECORDER_CHANNEL = "com.nyx.app/voice_recorder"
    private val MEDIA_CONVERTER_CHANNEL = "com.angelonartey.nyx/media_converter"
    private var pendingSharedFiles: List<String>? = null
    private var mediaRecorder: MediaRecorder? = null
    private var currentRecordingPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Share handler channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSharedFiles" -> {
                    val files = pendingSharedFiles
                    pendingSharedFiles = null
                    result.success(files)
                }
                else -> result.notImplemented()
            }
        }
        
        // Voice recorder channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOICE_RECORDER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startRecording" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        startRecording(filePath)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGUMENT", "filePath is required", null)
                    }
                }
                "stopRecording" -> {
                    val path = stopRecording()
                    result.success(path)
                }
                "cancelRecording" -> {
                    cancelRecording()
                    result.success(null)
                }
                "isRecording" -> {
                    result.success(mediaRecorder != null)
                }
                "getDuration" -> {
                    // MediaRecorder doesn't provide duration directly
                    // Would need to track start time or use MediaMetadataRetriever
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        
        // Media converter channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CONVERTER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "convertVideoToAudio" -> {
                    val videoPath = call.argument<String>("videoPath")
                    val outputPath = call.argument<String>("outputPath")
                    val format = call.argument<String>("format")
                    
                    if (videoPath == null || outputPath == null || format == null) {
                        result.error("INVALID_ARGUMENT", "Missing required arguments", null)
                        return@setMethodCallHandler
                    }
                    
                    // Run conversion in background thread
                    Thread {
                        try {
                            val success = convertVideoToAudio(videoPath, outputPath, format)
                            runOnUiThread {
                                if (success) {
                                    result.success(outputPath)
                                } else {
                                    result.error("CONVERSION_FAILED", "Failed to convert video to audio", null)
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("CONVERSION_FAILED", e.message ?: "Unknown error", null)
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
        
        // Background execution channel
        val BACKGROUND_EXECUTION_CHANNEL = "com.nyx.app/background_execution"
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND_EXECUTION_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestBackgroundExecution" -> {
                    // Start foreground service to keep app active
                    val reason = call.argument<String>("reason") ?: "Importing files"
                    val intent = Intent(this, ImportForegroundService::class.java).apply {
                        putExtra("reason", reason)
                    }
                    
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "endBackgroundExecution" -> {
                    // Stop foreground service
                    val intent = Intent(this, ImportForegroundService::class.java)
                    stopService(intent)
                    result.success(null)
                }
                "updateProgress" -> {
                    // Update notification progress
                    val current = call.argument<Int>("current") ?: 0
                    val total = call.argument<Int>("total") ?: 0
                    val status = call.argument<String>("status") ?: "Processing..."
                    
                    val intent = Intent(this, ImportForegroundService::class.java).apply {
                        action = "UPDATE_PROGRESS"
                        putExtra("current", current)
                        putExtra("total", total)
                        putExtra("status", status)
                    }
                    startService(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
    
    private fun startRecording(filePath: String) {
        try {
            mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            
            mediaRecorder?.apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setOutputFile(filePath)
                prepare()
                start()
            }
            
            currentRecordingPath = filePath
        } catch (e: Exception) {
            e.printStackTrace()
            mediaRecorder?.release()
            mediaRecorder = null
            currentRecordingPath = null
        }
    }
    
    private fun stopRecording(): String? {
        return try {
            mediaRecorder?.apply {
                stop()
                release()
            }
            val path = currentRecordingPath
            mediaRecorder = null
            currentRecordingPath = null
            path
        } catch (e: Exception) {
            e.printStackTrace()
            mediaRecorder?.release()
            mediaRecorder = null
            currentRecordingPath = null
            null
        }
    }
    
    private fun cancelRecording() {
        try {
            mediaRecorder?.apply {
                stop()
                release()
            }
            currentRecordingPath?.let { path ->
                File(path).delete()
            }
            mediaRecorder = null
            currentRecordingPath = null
        } catch (e: Exception) {
            e.printStackTrace()
            mediaRecorder?.release()
            mediaRecorder = null
            currentRecordingPath = null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        
        val action = intent.action
        val type = intent.type

        if (Intent.ACTION_SEND == action && type != null) {
            // Handle single file share
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (uri != null) {
                val filePath = copyFileToTemp(uri)
                if (filePath != null) {
                    pendingSharedFiles = listOf(filePath)
                }
            }
        } else if (Intent.ACTION_SEND_MULTIPLE == action && type != null) {
            // Handle multiple files share
            val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            if (uris != null && uris.isNotEmpty()) {
                val filePaths = uris.mapNotNull { uri -> copyFileToTemp(uri) }
                if (filePaths.isNotEmpty()) {
                    pendingSharedFiles = filePaths
                }
            }
        }
    }

    private fun copyFileToTemp(uri: Uri): String? {
        return try {
            val inputStream: InputStream? = contentResolver.openInputStream(uri)
            if (inputStream == null) {
                null
            } else {
                // Create temp file
                val tempDir = File(cacheDir, "shared_files")
                if (!tempDir.exists()) {
                    tempDir.mkdirs()
                }
                val tempFile = File.createTempFile("shared_", ".tmp", tempDir)
                
                // Copy file
                val outputStream = FileOutputStream(tempFile)
                inputStream.use { input ->
                    outputStream.use { output ->
                        input.copyTo(output)
                    }
                }
                
                tempFile.absolutePath
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }
    
    /**
     * Convert video file to audio file using MediaExtractor and MediaMuxer
     * Extracts audio track from video and saves it as an audio file
     */
    private fun convertVideoToAudio(videoPath: String, outputPath: String, format: String): Boolean {
        var extractor: MediaExtractor? = null
        var muxer: MediaMuxer? = null
        
        try {
            // Remove existing output file
            File(outputPath).delete()
            
            extractor = MediaExtractor()
            extractor.setDataSource(videoPath)
            
            // Find audio track
            var audioTrackIndex = -1
            var audioFormat: MediaFormat? = null
            
            for (i in 0 until extractor.trackCount) {
                val trackFormat = extractor.getTrackFormat(i)
                val mime = trackFormat.getString(MediaFormat.KEY_MIME)
                
                if (mime?.startsWith("audio/") == true) {
                    audioTrackIndex = i
                    audioFormat = trackFormat
                    break
                }
            }
            
            if (audioTrackIndex == -1 || audioFormat == null) {
                android.util.Log.e("MediaConverter", "No audio track found in video")
                return false
            }
            
            // Determine output format based on requested format
            val muxerFormat = when (format.lowercase()) {
                "mp3" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4 // MP3 not directly supported, use M4A
                "m4a", "aac" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
                "ogg" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_OGG
                "wav" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM // WAV not directly supported
                else -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4 // Default to M4A
            }
            
            muxer = MediaMuxer(outputPath, muxerFormat)
            
            // Select audio track
            extractor.selectTrack(audioTrackIndex)
            
            // Add audio track to muxer
            val muxerTrackIndex = muxer.addTrack(audioFormat)
            muxer.start()
            
            // Copy audio data
            val buffer = ByteBuffer.allocate(64 * 1024) // 64KB buffer
            val bufferInfo = MediaCodec.BufferInfo()
            
            while (true) {
                val sampleSize = extractor.readSampleData(buffer, 0)
                
                if (sampleSize < 0) {
                    break // End of stream
                }
                
                bufferInfo.offset = 0
                bufferInfo.size = sampleSize
                bufferInfo.flags = extractor.sampleFlags
                bufferInfo.presentationTimeUs = extractor.sampleTime
                
                muxer.writeSampleData(muxerTrackIndex, buffer, bufferInfo)
                
                if (!extractor.advance()) {
                    break
                }
            }
            
            muxer.stop()
            muxer.release()
            extractor.release()
            
            // Verify output file exists and has content
            val outputFile = File(outputPath)
            return outputFile.exists() && outputFile.length() > 0
            
        } catch (e: Exception) {
            android.util.Log.e("MediaConverter", "Error converting video to audio: ${e.message}", e)
            muxer?.release()
            extractor?.release()
            File(outputPath).delete() // Clean up on error
            return false
        }
    }
}

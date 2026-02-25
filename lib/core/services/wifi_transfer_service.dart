import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';
import 'package:archive/archive_io.dart';
import '../models/vault_item.dart';
import 'vault_service.dart';
import 'auth_service.dart';

/// Transfer event types
enum TransferEventType {
  upload,
  download,
}

/// Transfer event
class TransferEvent {
  final TransferEventType type;
  final String filename;
  final int sizeBytes;
  final bool success;
  final String? error;

  TransferEvent({
    required this.type,
    required this.filename,
    required this.sizeBytes,
    required this.success,
    this.error,
  });
}

/// WiFi Transfer Service - Enables file transfer between app and computer via local network
class WiFiTransferService extends ChangeNotifier {
  final VaultService _vaultService;
  final AuthService _authService;
  
  HttpServer? _server;
  String? _serverUrl;
  String? _accessToken;
  bool _isRunning = false;
  int _port = 8080;

  // Anti-crash guards: this implementation parses multipart by buffering the whole request.
  // Set an upper bound to prevent OOM / disk abuse when someone uploads huge videos.
  static const int _maxUploadBytes = 500 * 1024 * 1024; // 500MB
  
  // Transfer statistics
  int _uploadedFiles = 0;
  int _downloadedFiles = 0;
  int _totalUploadedBytes = 0;
  int _totalDownloadedBytes = 0;
  
  // Transfer event stream
  final _transferEventController = StreamController<TransferEvent>.broadcast();
  Stream<TransferEvent> get transferEvents => _transferEventController.stream;

  // Serialize uploads to prevent multiple concurrent large buffers (anti-crash).
  // The web UI can fire multiple requests in parallel; this forces one-at-a-time processing.
  Future<void> _uploadSerial = Future.value();
  
  bool get isRunning => _isRunning;
  String? get serverUrl => _serverUrl;
  /// URL that includes the access token, intended for the QR code / browser entry.
  /// Opening this URL makes the web UI automatically authenticate subsequent API calls.
  String? get serverUrlWithToken {
    final url = _serverUrl;
    final token = _accessToken;
    if (url == null || token == null) return null;
    return '$url/?token=$token';
  }
  /// True if the server URL uses a real LAN IP (reachable from another device on same WiFi).
  bool get isUrlReachableFromComputer =>
      _serverUrl != null &&
      !_serverUrl!.contains('localhost') &&
      !_serverUrl!.contains('127.0.0.1');
  String? get accessToken => _accessToken;
  int get uploadedFiles => _uploadedFiles;
  int get downloadedFiles => _downloadedFiles;
  int get totalUploadedBytes => _totalUploadedBytes;
  int get totalDownloadedBytes => _totalDownloadedBytes;
  
  WiFiTransferService(this._vaultService, this._authService);

  bool _isVaultUnlocked() => _authService.masterKey != null;

  String _sanitizeFilename(String input) {
    var name = input.replaceAll('\u0000', '');
    name = name.split('/').last.split('\\').last; // basename
    name = name.replaceAll(RegExp(r'[\r\n]'), '');
    if (name.trim().isEmpty) return 'uploaded_file';
    return name;
  }

  Future<({File file, Directory tempDir, String filename, int bytesWritten})?> _saveFirstMultipartFileToTemp(Request request) async {
    final contentTypeHeader = request.headers['content-type'];
    if (contentTypeHeader == null) {
      return null;
    }

    HeaderValue headerValue;
    try {
      headerValue = HeaderValue.parse(contentTypeHeader);
    } catch (_) {
      return null;
    }

    final boundary = headerValue.parameters['boundary'];
    if (boundary == null || boundary.isEmpty) return null;

    final transformer = MimeMultipartTransformer(boundary);
    await for (final part in request.read().transform(transformer)) {
      final disposition = part.headers['content-disposition'] ?? '';
      final filenameMatch = RegExp(r'filename="?([^"\r\n]+)"?').firstMatch(disposition);
      if (filenameMatch == null) {
        // Skip non-file fields.
        continue;
      }

      final filename = _sanitizeFilename(filenameMatch.group(1) ?? 'uploaded_file');
      final tempDir = await Directory.systemTemp.createTemp('nyx_wifi_');
      final tempFile = File('${tempDir.path}/${const Uuid().v4()}_$filename');

      final sink = tempFile.openWrite();
      int written = 0;
      bool success = false;
      try {
        await for (final chunk in part) {
          written += chunk.length;
          if (written > _maxUploadBytes) {
            throw StateError('Upload too large');
          }
          sink.add(chunk);
        }
        await sink.flush();
        success = true;
      } finally {
        await sink.close();
        if (!success) {
          // Cleanup partial files on any failure (best-effort).
          try {
            if (await tempFile.exists()) {
              await tempFile.delete();
            }
          } catch (_) {}
          try {
            if (await tempDir.exists()) {
              await tempDir.delete(recursive: true);
            }
          } catch (_) {}
        }
      }

      return (file: tempFile, tempDir: tempDir, filename: filename, bytesWritten: written);
    }

    return null;
  }

  Future<T> _serializeUpload<T>(Future<T> Function() action) {
    final next = _uploadSerial.then((_) => action());
    _uploadSerial = next.then((_) => null, onError: (_) => null);
    return next;
  }
  
  /// Start the WiFi transfer server
  Future<bool> startServer() async {
    if (_isRunning) {
      debugPrint('[WiFiTransfer] Server already running');
      return true;
    }
    
    try {
      // Generate access token for security
      _accessToken = const Uuid().v4();
      
      // Create router
      final router = Router();
      
      // Serve web interface
      router.get('/', _handleIndex);
      router.get('/api/status', _handleStatus);
      router.get('/api/items', _handleGetItems);
      router.get('/api/folders', _handleGetFolders);
      router.post('/api/upload', _handleUpload);
      router.post('/api/upload-folder', _handleUploadFolder);
      router.get('/api/download/<itemId>', _handleDownload);
      router.get('/api/download-folder/<folderId>', _handleDownloadFolder);
      router.delete('/api/delete/<itemId>', _handleDelete);
      
      // Create middleware for CORS and logging
      final handler = Pipeline()
          .addMiddleware(_logRequests())
          .addMiddleware(_corsMiddleware())
          .addMiddleware(_authMiddleware())
          .addHandler(router);
      
      // Start server
      _server = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        _port,
      );
      
      _serverUrl = 'http://${await _getLocalIP()}:$_port';
      _isRunning = true;
      
      debugPrint('[WiFiTransfer] Server started at $_serverUrl');
      debugPrint('[WiFiTransfer] Access token: $_accessToken');
      
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[WiFiTransfer] Error starting server: $e');
      // Try next port if current one is in use
      if (_port < 8090) {
        _port++;
        return startServer();
      }
      return false;
    }
  }
  
  /// Stop the WiFi transfer server
  Future<void> stopServer() async {
    if (!_isRunning || _server == null) return;
    
    try {
      await _server!.close(force: true);
      _server = null;
      _serverUrl = null;
      _accessToken = null;
      _isRunning = false;
      _uploadedFiles = 0;
      _downloadedFiles = 0;
      _totalUploadedBytes = 0;
      _totalDownloadedBytes = 0;
      
      debugPrint('[WiFiTransfer] Server stopped');
      notifyListeners();
    } catch (e) {
      debugPrint('[WiFiTransfer] Error stopping server: $e');
    }
  }
  
  /// Get local IP address. Prefers WiFi (en0) so the URL is reachable from a computer on the same WiFi.
  /// Returns 'localhost' only if no suitable address is found (e.g. not on WiFi).
  Future<String> _getLocalIP() async {
    try {
      final interfaces = await NetworkInterface.list();
      String? wifiIp;
      String? fallbackIp;
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        // Skip cellular and other non-LAN interfaces so computer on WiFi can reach us
        if (name.startsWith('pdp_') || name == 'awdl0' || name.startsWith('utun')) continue;
        for (final addr in interface.addresses) {
          if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) continue;
          final ip = addr.address;
          if (name == 'en0') {
            wifiIp ??= ip;
            break; // use first en0 address
          }
          fallbackIp ??= ip; // use first non-en0 LAN address as fallback
        }
      }
      final chosen = wifiIp ?? fallbackIp;
      if (chosen != null) {
        debugPrint('[WiFiTransfer] Using IP: $chosen (WiFi: ${wifiIp != null})');
        return chosen;
      }
    } catch (e) {
      debugPrint('[WiFiTransfer] Error getting IP: $e');
    }
    debugPrint('[WiFiTransfer] No WiFi/LAN IP found, using localhost (site may be unreachable from computer)');
    return 'localhost';
  }
  
  /// CORS middleware
  Middleware _corsMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        // Handle preflight.
        if (request.method.toUpperCase() == 'OPTIONS') {
          return Response.ok(
            '',
            headers: _corsHeadersForRequest(request),
          );
        }

        final response = await handler(request);
        return response.change(
          headers: _corsHeadersForRequest(request),
        );
      };
    };
  }

  Map<String, String> _corsHeadersForRequest(Request request) {
    // This server serves its own web UI from the same origin, so CORS isn't required.
    // We only reflect the Origin for same-origin requests (defense in depth).
    final origin = request.headers['origin'];
    final url = _serverUrl;
    final headers = <String, String>{
      'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Vary': 'Origin',
    };

    if (origin != null && url != null && origin == url) {
      headers['Access-Control-Allow-Origin'] = origin;
    }
    return headers;
  }
  
  /// Logging middleware
  Middleware _logRequests() {
    return (Handler handler) {
      return (Request request) async {
        debugPrint('[WiFiTransfer] ${request.method} ${request.url}');
        return handler(request);
      };
    };
  }

  Middleware _authMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        // Allow preflight to be handled by CORS middleware.
        if (request.method.toUpperCase() == 'OPTIONS') {
          return handler(request);
        }

        // If server isn't running or token isn't initialized, deny (shouldn't happen).
        final token = _accessToken;
        if (token == null || token.isEmpty) {
          return Response.forbidden('Server not ready');
        }

        // Require token for ALL routes (including index).
        final provided = request.url.queryParameters['token'];
        if (provided != token) {
          return Response.forbidden(
            'Unauthorized. Open the tokenized URL from the app (QR code) to authenticate.',
          );
        }

        return handler(request);
      };
    };
  }
  
  /// Handle index page (web interface)
  Future<Response> _handleIndex(Request request) async {
    final html = _getWebInterface();
    return Response.ok(
      html,
      headers: {'Content-Type': 'text/html; charset=utf-8'},
    );
  }
  
  /// Handle status API
  Future<Response> _handleStatus(Request request) async {
    if (!_isVaultUnlocked()) {
      return Response.forbidden('Vault must be unlocked');
    }
    final status = {
      'running': _isRunning,
      'url': _serverUrl,
      'itemsCount': _vaultService.items.length,
      'uploadedFiles': _uploadedFiles,
      'downloadedFiles': _downloadedFiles,
      'totalUploadedBytes': _totalUploadedBytes,
      'totalDownloadedBytes': _totalDownloadedBytes,
    };
    return Response.ok(
      jsonEncode(status),
      headers: {'Content-Type': 'application/json'},
    );
  }
  
  /// Handle get folders API
  Future<Response> _handleGetFolders(Request request) async {
    try {
      if (!_isVaultUnlocked()) {
        return Response.forbidden('Vault must be unlocked');
      }
      final folders = _vaultService.folders.map((folder) => {
        'id': folder.id,
        'name': folder.name,
        'itemCount': folder.itemIds.length,
        'createdAt': folder.createdAt.toIso8601String(),
      }).toList();
      
      return Response.ok(
        jsonEncode({'folders': folders}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      debugPrint('[WiFiTransfer] Error getting folders: $e');
      return Response.internalServerError(body: 'Failed to get folders: $e');
    }
  }
  
  /// Handle get items API
  Future<Response> _handleGetItems(Request request) async {
    try {
      if (!_isVaultUnlocked()) {
        return Response.forbidden('Vault must be unlocked');
      }
      final items = _vaultService.items.map((item) => {
        'id': item.id,
        'name': item.displayName,
        'type': item.type.toString().split('.').last,
        'size': item.sizeBytes,
        'dateAdded': item.dateAdded.toIso8601String(),
      }).toList();
      
      return Response.ok(
        jsonEncode({'items': items}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Error: $e');
    }
  }
  
  /// Handle file upload
  Future<Response> _handleUpload(Request request) async {
    return _serializeUpload(() async {
      String filename = 'uploaded_file';
      try {
        if (!_isVaultUnlocked()) {
          return Response.forbidden('Vault must be unlocked');
        }
        
        final saved = await _saveFirstMultipartFileToTemp(request);
        if (saved == null) {
          return Response.badRequest(body: 'No file data');
        }

        filename = saved.filename;

        // Store file in vault using path-based copy (no full in-RAM buffering).
        final item = await _vaultService.storeFileFromPath(
          sourceFilePath: saved.file.path,
          filename: filename,
          source: VaultItemSource.unknown,
        );

        // Cleanup temp upload
        try {
          if (await saved.file.exists()) {
            await saved.file.delete();
          }
          await saved.tempDir.delete(recursive: true);
        } catch (_) {}
        
        _uploadedFiles++;
        _totalUploadedBytes += saved.bytesWritten;
        notifyListeners();
        
        // Emit transfer event
        _transferEventController.add(TransferEvent(
          type: TransferEventType.upload,
          filename: filename,
          sizeBytes: saved.bytesWritten,
          success: true,
        ));
        
        return Response.ok(
          jsonEncode({
            'success': true,
            'itemId': item.id,
            'message': 'File uploaded successfully',
          }),
          headers: {'Content-Type': 'application/json'},
        );
      } on StateError catch (e) {
        if (e.message.toString().toLowerCase().contains('upload too large')) {
          return Response(
            413,
            body: 'Upload too large. Max size is ${(_maxUploadBytes / 1024 / 1024).round()}MB.',
          );
        }
        debugPrint('[WiFiTransfer] Upload error: $e');
        _transferEventController.add(TransferEvent(
          type: TransferEventType.upload,
          filename: filename,
          sizeBytes: 0,
          success: false,
          error: e.toString(),
        ));
        return Response.internalServerError(body: 'Upload failed: $e');
      } catch (e) {
        debugPrint('[WiFiTransfer] Upload error: $e');
        
        // Emit error event
        _transferEventController.add(TransferEvent(
          type: TransferEventType.upload,
          filename: filename,
          sizeBytes: 0,
          success: false,
          error: e.toString(),
        ));
        
        return Response.internalServerError(body: 'Upload failed: $e');
      }
    });
  }
  
  /// Handle file download
  Future<Response> _handleDownload(Request request, String itemId) async {
    try {
      if (!_isVaultUnlocked()) {
        return Response.forbidden('Vault must be unlocked');
      }
      
      final item = _vaultService.items.firstWhere(
        (i) => i.id == itemId,
        orElse: () => throw Exception('Item not found'),
      );
      
      // Stream from disk (path-first) to avoid loading full file into RAM.
      final filePath = _vaultService.getFilePath(itemId);
      if (filePath == null) {
        return Response.notFound('File not found');
      }
      final file = File(filePath);
      if (!await file.exists()) {
        return Response.notFound('File not found');
      }

      final length = await file.length();
      
      _downloadedFiles++;
      _totalDownloadedBytes += length;
      notifyListeners();
      
      // Emit transfer event (best-effort)
      _transferEventController.add(TransferEvent(
        type: TransferEventType.download,
        filename: item.displayName,
        sizeBytes: length,
        success: true,
      ));

      return Response.ok(
        file.openRead(),
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Disposition': 'attachment; filename="${item.displayName}"',
          'Content-Length': length.toString(),
        },
      );
    } catch (e) {
      debugPrint('[WiFiTransfer] Download error: $e');
      
      // Emit error event
      try {
        final item = _vaultService.items.firstWhere(
          (i) => i.id == itemId,
          orElse: () => throw Exception('Item not found'),
        );
        _transferEventController.add(TransferEvent(
          type: TransferEventType.download,
          filename: item.displayName,
          sizeBytes: 0,
          success: false,
          error: e.toString(),
        ));
      } catch (_) {
        _transferEventController.add(TransferEvent(
          type: TransferEventType.download,
          filename: 'unknown',
          sizeBytes: 0,
          success: false,
          error: e.toString(),
        ));
      }
      
      return Response.internalServerError(body: 'Download failed: $e');
    }
  }
  
  /// Handle folder upload (zip file containing multiple files)
  Future<Response> _handleUploadFolder(Request request) async {
    return _serializeUpload(() async {
      String folderName = 'uploaded_folder';
      try {
        if (!_isVaultUnlocked()) {
          return Response.forbidden('Vault must be unlocked');
        }

        final saved = await _saveFirstMultipartFileToTemp(request);
        if (saved == null) {
          return Response.badRequest(body: 'No file data');
        }

        final zipFilename = saved.filename;
        if (!zipFilename.toLowerCase().endsWith('.zip')) {
          try {
            await saved.file.delete();
            await saved.tempDir.delete(recursive: true);
          } catch (_) {}
          return Response.badRequest(body: 'Folder upload must be a .zip file');
        }

        folderName = zipFilename.substring(0, zipFilename.length - 4);

        // Extract zip file from disk (avoid buffering the upload in RAM).
        final archive = ZipDecoder().decodeBuffer(InputFileStream(saved.file.path));
        
        // Create folder in vault
        final vaultFolder = await _vaultService.createFolder(folderName);
        
        int uploadedCount = 0;
        int totalBytes = 0;
        
        // Process each file in the archive (already sequential).
        for (final file in archive) {
          if (file.isFile) {
            final filename = file.name.split('/').last; // Get filename without path
            if (filename.isEmpty) continue;
            
            // Store file in vault folder (path-first: write temp then storeFileFromPath).
            final entryBytes = Uint8List.fromList(file.content as List<int>);
            final entryTemp = await Directory.systemTemp.createTemp('nyx_wifi_zip_');
            final entryFile = File('${entryTemp.path}/${const Uuid().v4()}_${_sanitizeFilename(filename)}');
            await entryFile.writeAsBytes(entryBytes, flush: true);

            await _vaultService.storeFileFromPath(
              sourceFilePath: entryFile.path,
              filename: _sanitizeFilename(filename),
              source: VaultItemSource.unknown,
              folderId: vaultFolder.id,
            );

            try {
              await entryFile.delete();
              await entryTemp.delete(recursive: true);
            } catch (_) {}
            
            uploadedCount++;
            totalBytes += file.size;
            
            // Emit transfer event for each file
            _transferEventController.add(TransferEvent(
              type: TransferEventType.upload,
              filename: filename,
              sizeBytes: file.size,
              success: true,
            ));
          }
        }

        // Cleanup uploaded zip temp file
        try {
          await saved.file.delete();
          await saved.tempDir.delete(recursive: true);
        } catch (_) {}
        
        _uploadedFiles += uploadedCount;
        _totalUploadedBytes += totalBytes;
        notifyListeners();
        
        return Response.ok(
          jsonEncode({
            'success': true,
            'folderId': vaultFolder.id,
            'folderName': folderName,
            'fileCount': uploadedCount,
            'totalBytes': totalBytes,
            'message': 'Folder uploaded successfully',
          }),
          headers: {'Content-Type': 'application/json'},
        );
      } on StateError catch (e) {
        if (e.message.toString().toLowerCase().contains('upload too large')) {
          return Response(
            413,
            body: 'Upload too large. Max size is ${(_maxUploadBytes / 1024 / 1024).round()}MB.',
          );
        }
        debugPrint('[WiFiTransfer] Folder upload error: $e');
        _transferEventController.add(TransferEvent(
          type: TransferEventType.upload,
          filename: folderName,
          sizeBytes: 0,
          success: false,
          error: e.toString(),
        ));
        return Response.internalServerError(body: 'Folder upload failed: $e');
      } catch (e) {
        debugPrint('[WiFiTransfer] Folder upload error: $e');
        
        _transferEventController.add(TransferEvent(
          type: TransferEventType.upload,
          filename: folderName,
          sizeBytes: 0,
          success: false,
          error: e.toString(),
        ));
        
        return Response.internalServerError(body: 'Folder upload failed: $e');
      }
    });
  }
  
  /// Handle folder download (as zip file)
  Future<Response> _handleDownloadFolder(Request request, String folderId) async {
    try {
      if (!_isVaultUnlocked()) {
        return Response.forbidden('Vault must be unlocked');
      }
      
      // Get folder
      final folder = _vaultService.folders.firstWhere(
        (f) => f.id == folderId,
        orElse: () => throw Exception('Folder not found'),
      );
      
      // Get all items in folder
      final items = _vaultService.getFolderItems(folderId);
      
      if (items.isEmpty) {
        return Response.badRequest(body: 'Folder is empty');
      }
      
      // Stream zip creation to disk to avoid huge in-RAM buffers.
      final tmpDir = await Directory.systemTemp.createTemp('nyx_wifi_folder_');
      final safeName = _sanitizeFilename(folder.name);
      final zipPath = '${tmpDir.path}/$safeName.zip';

      final encoder = ZipFileEncoder();
      encoder.create(zipPath);

      int totalBytes = 0;
      for (final item in items) {
        final filePath = _vaultService.getFilePath(item.id);
        if (filePath == null) continue;
        final f = File(filePath);
        if (!await f.exists()) continue;
        totalBytes += await f.length();
        encoder.addFile(f, item.displayName);
      }
      encoder.close();

      final zipFile = File(zipPath);
      if (!await zipFile.exists()) {
        await tmpDir.delete(recursive: true);
        return Response.internalServerError(body: 'Failed to create zip file');
      }
      final zipLength = await zipFile.length();
      
      _downloadedFiles += items.length;
      _totalDownloadedBytes += totalBytes;
      notifyListeners();
      
      // Emit transfer event
      _transferEventController.add(TransferEvent(
        type: TransferEventType.download,
        filename: '${folder.name}.zip',
        sizeBytes: zipLength,
        success: true,
      ));
      
      final controller = StreamController<List<int>>();
      late final StreamSubscription<List<int>> sub;

      Future<void> cleanup() async {
        try {
          if (await zipFile.exists()) {
            await zipFile.delete();
          }
        } catch (_) {}
        try {
          if (await tmpDir.exists()) {
            await tmpDir.delete(recursive: true);
          }
        } catch (_) {}
      }

      sub = zipFile.openRead().listen(
        controller.add,
        onError: (e, st) {
          controller.addError(e, st);
        },
        onDone: () {
          // Best-effort cleanup after stream completes.
          cleanup();
          controller.close();
        },
        cancelOnError: true,
      );

      controller.onCancel = () async {
        await sub.cancel();
        await cleanup();
      };

      return Response.ok(
        controller.stream,
        headers: {
          'Content-Type': 'application/zip',
          'Content-Disposition': 'attachment; filename="${folder.name}.zip"',
          'Content-Length': zipLength.toString(),
        },
      );
    } catch (e) {
      debugPrint('[WiFiTransfer] Folder download error: $e');
      
      _transferEventController.add(TransferEvent(
        type: TransferEventType.download,
        filename: 'folder.zip',
        sizeBytes: 0,
        success: false,
        error: e.toString(),
      ));
      
      return Response.internalServerError(body: 'Folder download failed: $e');
    }
  }
  
  /// No-op: We do not modify or enumerate the user's photo library (App Store guideline 2.5.1).
  /// Files uploaded to the vault remain in the user's Photos app; we only store a copy in the vault.
  Future<void> _deleteFromDeviceIfMedia(VaultItem item, Uint8List fileData) async {
    // Intentionally empty - no access to Photos API for deletion or enumeration.
  }

  /// Handle file delete
  Future<Response> _handleDelete(Request request, String itemId) async {
    try {
      if (!_isVaultUnlocked()) {
        return Response.forbidden('Vault must be unlocked');
      }
      final success = await _vaultService.deleteItem(itemId);
      if (success) {
        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } else {
        return Response.notFound('Item not found');
      }
    } catch (e) {
      return Response.internalServerError(body: 'Delete failed: $e');
    }
  }
  
  /// Get web interface HTML
  String _getWebInterface() {
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nyx WiFi Transfer</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #0E0E11;
            color: #FFFFFF;
            padding: 20px;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { margin-bottom: 30px; color: #00D4FF; }
        .section { background: #1A1A1F; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .upload-area {
            border: 2px dashed #00D4FF;
            border-radius: 8px;
            padding: 40px;
            text-align: center;
            cursor: pointer;
            transition: all 0.3s;
        }
        .upload-area:hover { background: #25252A; }
        .upload-area.dragover { background: #25252A; border-color: #00D4FF; }
        input[type="file"] { display: none; }
        button {
            background: #00D4FF;
            color: #0E0E11;
            border: none;
            padding: 12px 24px;
            border-radius: 6px;
            cursor: pointer;
            font-weight: 600;
            margin: 5px;
        }
        button:hover { opacity: 0.9; }
        button:disabled { opacity: 0.5; cursor: not-allowed; }
        .file-list { margin-top: 20px; }
        .file-item {
            background: #25252A;
            padding: 15px;
            border-radius: 6px;
            margin-bottom: 10px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .file-info { flex: 1; }
        .file-name { font-weight: 600; margin-bottom: 5px; }
        .file-meta { color: #888; font-size: 12px; }
        .progress-bar {
            width: 100%;
            height: 4px;
            background: #25252A;
            border-radius: 2px;
            margin-top: 10px;
            overflow: hidden;
        }
        .progress-fill {
            height: 100%;
            background: #00D4FF;
            transition: width 0.3s;
        }
        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-top: 20px;
        }
        .stat-item {
            background: #25252A;
            padding: 15px;
            border-radius: 6px;
            text-align: center;
        }
        .stat-value { font-size: 24px; font-weight: 600; color: #00D4FF; }
        .stat-label { font-size: 12px; color: #888; margin-top: 5px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>📱 Nyx WiFi Transfer</h1>
        
        <div class="section">
            <h2>Upload Files</h2>
            <div class="upload-area" id="uploadArea">
                <p>📁 Drag & drop files here or click to select</p>
                <p style="color: #888; margin-top: 10px;">Supports multiple files</p>
            </div>
            <input type="file" id="fileInput" multiple>
            <div style="margin-top: 10px;">
                <button onclick="document.getElementById('folderInput').click()">📁 Upload Folder</button>
            </div>
            <input type="file" id="folderInput" webkitdirectory directory multiple style="display: none;">
            <script src="https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js"></script>
            <div id="uploadProgress"></div>
        </div>
        
        <div class="section">
            <h2>Vault Files</h2>
            <div id="fileList" class="file-list">Loading...</div>
        </div>

        <div class="section">
            <h2>Vault Folders</h2>
            <div id="folderList" class="file-list">Loading...</div>
        </div>
        
        <div class="section">
            <h2>Statistics</h2>
            <div class="stats" id="stats"></div>
        </div>
    </div>
    
    <script>
        const TOKEN = new URLSearchParams(window.location.search).get('token') || '';
        function apiUrl(path) {
            if (!TOKEN) return path;
            const sep = path.includes('?') ? '&' : '?';
            return path + sep + 'token=' + encodeURIComponent(TOKEN);
        }
        if (!TOKEN) {
            alert('Unauthorized. Please open this page using the QR code / URL shown in the Nyx app.');
        }

        const uploadArea = document.getElementById('uploadArea');
        const fileInput = document.getElementById('fileInput');
        const uploadProgress = document.getElementById('uploadProgress');
        const fileList = document.getElementById('fileList');
        const folderList = document.getElementById('folderList');
        const stats = document.getElementById('stats');
        
        // Upload area click
        uploadArea.addEventListener('click', () => fileInput.click());
        
        // Drag and drop
        uploadArea.addEventListener('dragover', (e) => {
            e.preventDefault();
            uploadArea.classList.add('dragover');
        });
        uploadArea.addEventListener('dragleave', () => {
            uploadArea.classList.remove('dragover');
        });
        uploadArea.addEventListener('drop', (e) => {
            e.preventDefault();
            uploadArea.classList.remove('dragover');
            handleFiles(e.dataTransfer.files);
        });
        
        // File input change
        fileInput.addEventListener('change', (e) => {
            handleFiles(e.target.files);
        });
        
        // Folder input change
        const folderInput = document.getElementById('folderInput');
        folderInput.addEventListener('change', (e) => {
            handleFolder(e.target.files);
        });
        
        async function handleFiles(files) {
            for (const file of files) {
                await uploadFile(file);
            }
        }
        
        async function handleFolder(files) {
            if (files.length === 0) return;
            
            // Create zip file from folder
            const JSZip = window.JSZip || await loadJSZip();
            const zip = new JSZip();
            
            // Add all files to zip
            for (let i = 0; i < files.length; i++) {
                const file = files[i];
                zip.file(file.webkitRelativePath || file.name, file);
            }
            
            // Generate zip blob
            const zipBlob = await zip.generateAsync({type: 'blob'});
            
            // Get folder name from first file's path
            const folderName = files[0].webkitRelativePath 
                ? files[0].webkitRelativePath.split('/')[0] 
                : 'uploaded_folder';
            
            // Upload zip file
            await uploadFolder(zipBlob, folderName);
        }
        
        async function loadJSZip() {
            // Load JSZip library dynamically
            const script = document.createElement('script');
            script.src = 'https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js';
            document.head.appendChild(script);
            return new Promise((resolve) => {
                script.onload = () => resolve(window.JSZip);
            });
        }
        
        async function uploadFolder(zipBlob, folderName) {
            const formData = new FormData();
            formData.append('file', zipBlob, folderName + '.zip');
            
            const progressDiv = document.createElement('div');
            progressDiv.innerHTML = \`
                <div style="margin: 10px 0;">
                    <div style="display: flex; justify-content: space-between; margin-bottom: 5px;">
                        <span>📁 \${folderName}</span>
                        <span id="progress-folder">Uploading...</span>
                    </div>
                    <div class="progress-bar">
                        <div class="progress-fill" id="bar-folder" style="width: 0%"></div>
                    </div>
                </div>
            \`;
            uploadProgress.appendChild(progressDiv);
            
            try {
                const xhr = new XMLHttpRequest();
                
                xhr.upload.addEventListener('progress', (e) => {
                    if (e.lengthComputable) {
                        const percent = Math.round((e.loaded / e.total) * 100);
                        document.getElementById('progress-folder').textContent = percent + '%';
                        document.getElementById('bar-folder').style.width = percent + '%';
                    }
                });
                
                xhr.addEventListener('load', () => {
                    if (xhr.status === 200) {
                        progressDiv.remove();
                        loadFiles();
                        loadFolders();
                        loadStats();
                    } else {
                        alert('Folder upload failed: ' + xhr.responseText);
                        progressDiv.remove();
                    }
                });
                
                xhr.addEventListener('error', () => {
                    alert('Folder upload failed');
                    progressDiv.remove();
                });
                
                xhr.open('POST', apiUrl('/api/upload-folder'));
                xhr.send(formData);
            } catch (error) {
                alert('Error uploading folder: ' + error);
                progressDiv.remove();
            }
        }
        
        async function uploadFile(file) {
            const formData = new FormData();
            formData.append('file', file);
            
            const progressDiv = document.createElement('div');
            progressDiv.innerHTML = \`
                <div style="margin: 10px 0;">
                    <div style="display: flex; justify-content: space-between; margin-bottom: 5px;">
                        <span>\${file.name}</span>
                        <span id="progress-\${file.name}">0%</span>
                    </div>
                    <div class="progress-bar">
                        <div class="progress-fill" id="bar-\${file.name}" style="width: 0%"></div>
                    </div>
                </div>
            \`;
            uploadProgress.appendChild(progressDiv);
            
            try {
                const xhr = new XMLHttpRequest();
                
                xhr.upload.addEventListener('progress', (e) => {
                    if (e.lengthComputable) {
                        const percent = Math.round((e.loaded / e.total) * 100);
                        document.getElementById(\`progress-\${file.name}\`).textContent = percent + '%';
                        document.getElementById(\`bar-\${file.name}\`).style.width = percent + '%';
                    }
                });
                
                xhr.addEventListener('load', () => {
                    if (xhr.status === 200) {
                        progressDiv.remove();
                        loadFiles();
                        loadStats();
                    } else {
                        alert('Upload failed: ' + xhr.responseText);
                    }
                });
                
                xhr.open('POST', apiUrl('/api/upload'));
                xhr.send(formData);
            } catch (error) {
                alert('Upload error: ' + error);
            }
        }
        
        async function loadFiles() {
            try {
                const response = await fetch(apiUrl('/api/items'));
                const data = await response.json();
                
                if (data.items && data.items.length > 0) {
                    fileList.innerHTML = data.items.map(item => \`
                        <div class="file-item">
                            <div class="file-info">
                                <div class="file-name">\${item.name}</div>
                                <div class="file-meta">
                                    \${formatBytes(item.size)} • \${formatDate(item.dateAdded)} • \${item.type}
                                </div>
                            </div>
                            <div>
                                <button onclick="downloadFile('\${item.id}', '\${item.name}')">Download</button>
                                <button onclick="deleteFile('\${item.id}')" style="background: #FF4444;">Delete</button>
                            </div>
                        </div>
                    \`).join('');
                } else {
                    fileList.innerHTML = '<p style="color: #888; text-align: center;">No files in vault</p>';
                }
            } catch (error) {
                fileList.innerHTML = '<p style="color: #FF4444;">Error loading files</p>';
            }
        }
        
        async function downloadFile(itemId, filename) {
            try {
                const response = await fetch(apiUrl(\`/api/download/\${itemId}\`));
                const blob = await response.blob();
                const url = window.URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = filename;
                a.click();
                window.URL.revokeObjectURL(url);
                loadStats();
            } catch (error) {
                alert('Download failed: ' + error);
            }
        }

        async function loadFolders() {
            try {
                const response = await fetch(apiUrl('/api/folders'));
                const data = await response.json();

                if (data.folders && data.folders.length > 0) {
                    folderList.innerHTML = data.folders.map(folder => \`
                        <div class="file-item">
                            <div class="file-info">
                                <div class="file-name">\${folder.name}</div>
                                <div class="file-meta">\${folder.itemCount} item(s)</div>
                            </div>
                            <div>
                                <button onclick="downloadFolder('\${folder.id}', '\${folder.name}')">Download</button>
                            </div>
                        </div>
                    \`).join('');
                } else {
                    folderList.innerHTML = '<p style="color: #888; text-align: center;">No folders</p>';
                }
            } catch (error) {
                folderList.innerHTML = '<p style="color: #FF4444;">Error loading folders</p>';
            }
        }

        async function downloadFolder(folderId, folderName) {
            try {
                const response = await fetch(apiUrl(\`/api/download-folder/\${folderId}\`));
                const blob = await response.blob();
                const url = window.URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = folderName + '.zip';
                a.click();
                window.URL.revokeObjectURL(url);
                loadStats();
            } catch (error) {
                alert('Folder download failed: ' + error);
            }
        }
        
        async function deleteFile(itemId) {
            if (!confirm('Are you sure you want to delete this file?')) return;
            
            try {
                const response = await fetch(apiUrl(\`/api/delete/\${itemId}\`), { method: 'DELETE' });
                if (response.ok) {
                    loadFiles();
                    loadFolders();
                    loadStats();
                } else {
                    alert('Delete failed');
                }
            } catch (error) {
                alert('Delete error: ' + error);
            }
        }
        
        async function loadStats() {
            try {
                const response = await fetch(apiUrl('/api/status'));
                const data = await response.json();
                
                stats.innerHTML = \`
                    <div class="stat-item">
                        <div class="stat-value">\${data.itemsCount || 0}</div>
                        <div class="stat-label">Total Files</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-value">\${data.uploadedFiles || 0}</div>
                        <div class="stat-label">Uploaded</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-value">\${data.downloadedFiles || 0}</div>
                        <div class="stat-label">Downloaded</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-value">\${formatBytes(data.totalUploadedBytes || 0)}</div>
                        <div class="stat-label">Uploaded Size</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-value">\${formatBytes(data.totalDownloadedBytes || 0)}</div>
                        <div class="stat-label">Downloaded Size</div>
                    </div>
                \`;
            } catch (error) {
                console.error('Stats error:', error);
            }
        }
        
        function formatBytes(bytes) {
            if (bytes === 0) return '0 B';
            const k = 1024;
            const sizes = ['B', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i];
        }
        
        function formatDate(dateString) {
            const date = new Date(dateString);
            return date.toLocaleDateString() + ' ' + date.toLocaleTimeString();
        }
        
        // Load files and stats on page load
        loadFiles();
        loadFolders();
        loadStats();
        setInterval(loadFiles, 5000); // Refresh every 5 seconds
        setInterval(loadFolders, 5000);
        setInterval(loadStats, 5000);
    </script>
</body>
</html>
''';
  }
  
  @override
  void dispose() {
    stopServer();
    _transferEventController.close();
    super.dispose();
  }
}

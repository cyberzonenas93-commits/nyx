import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:mdns_dart/mdns_dart.dart';
import 'package:mdns_responder/mdns_responder.dart';
import 'package:mime/mime.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:photo_manager/photo_manager.dart';
import 'package:shelf_router/shelf_router.dart';
import '../models/vault_item.dart';
import 'vault_service.dart';
import 'auth_service.dart';

/// Minimal WiFi Transfer: HTTP server so a computer on the same WiFi can
/// browse vault items, upload files, and download files.
class WiFiTransferService extends ChangeNotifier {
  final VaultService _vaultService;
  final AuthService _authService;

  HttpServer? _server;
  MDNSServer? _mdnsServer;
  bool _usedNativeMdns = false;
  String? _serverUrl;
  bool _isRunning = false;
  bool _mdnsDiscoverable = false;
  int _port = 8080;
  bool _isReceiving = false;
  bool _showUploadComplete = false;
  Timer? _uploadCompleteTimer;

  static const int _maxUploadBytes = 300 * 1024 * 1024; // 300MB

  bool get isRunning => _isRunning;
  bool get isReceiving => _isReceiving;
  bool get showUploadComplete => _showUploadComplete;
  String? get serverUrl => _serverUrl;
  int get port => _port;
  bool get isDiscoverableOnNetwork => _mdnsDiscoverable;
  bool get isReachableFromNetwork =>
      _serverUrl != null &&
      !_serverUrl!.contains('localhost') &&
      !_serverUrl!.contains('127.0.0.1');
  /// True when likely running on Android emulator (10.0.2.x). Use adb reverse to reach from host.
  bool get isLikelyEmulator =>
      Platform.isAndroid &&
      _serverUrl != null &&
      (_serverUrl!.contains('10.0.2.') || _serverUrl!.startsWith('http://10.0.2.'));

  WiFiTransferService(this._vaultService, this._authService);

  bool _isVaultUnlocked() => _authService.isUnlocked;

  Future<String> _getLocalIP() async {
    // On Android/iOS prefer WiFi IP from network_info_plus (reliable for wlan0/WiFi)
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final info = NetworkInfo();
        final wifiIP = await info.getWifiIP();
        if (wifiIP != null && wifiIP.isNotEmpty && wifiIP != '127.0.0.1') {
          debugPrint('[WiFiTransfer] Using WiFi IP: $wifiIP');
          return wifiIP;
        }
      } catch (e) {
        debugPrint('[WiFiTransfer] network_info_plus: $e');
      }
    }
    try {
      final interfaces = await NetworkInterface.list();
      String? wifiIp;
      String? fallbackIp;
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (name.startsWith('pdp_') || name == 'awdl0' || name.startsWith('utun')) continue;
        for (final addr in interface.addresses) {
          if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) continue;
          final ip = addr.address;
          // en0 = macOS/iOS WiFi, wlan0 = Android WiFi
          if (name == 'en0' || name == 'wlan0') {
            wifiIp ??= ip;
            break;
          }
          fallbackIp ??= ip;
        }
      }
      final chosen = wifiIp ?? fallbackIp;
      if (chosen != null && chosen != '127.0.0.1') return chosen;
    } catch (e) {
      debugPrint('[WiFiTransfer] NetworkInterface: $e');
    }
    try {
      final info = NetworkInfo();
      final wifiIP = await info.getWifiIP();
      if (wifiIP != null && wifiIP.isNotEmpty && wifiIP != '127.0.0.1') return wifiIP;
    } catch (e) {
      debugPrint('[WiFiTransfer] network_info_plus: $e');
    }
    return 'localhost';
  }

  Response _cors(Response res) {
    return res.change(headers: {
      ...res.headers,
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
  }

  Middleware _corsOptionsMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        if (request.method.toUpperCase() == 'OPTIONS') return _cors(Response.ok(''));
        return handler(request);
      };
    };
  }

  Future<Response> _handleIndex(Request request) async {
    final html = _buildIndexHtml();
    return _cors(Response.ok(html, headers: {'Content-Type': 'text/html; charset=utf-8'}));
  }

  String _buildIndexHtml() {
    final vs = _vaultService;
    final rootItems = vs.getRootItems();
    final folders = vs.folders;
    final totalItems = rootItems.length + folders.fold<int>(0, (s, f) => s + vs.getFolderItems(f.id).length);
    final downloadAllHtml = totalItems == 0
        ? ''
        : '<p><a href="/download-all" class="btn">Download all as ZIP</a></p>';

    final sections = <String>[];
    // Files (root)
    sections.add(_buildSectionHtml('Files', rootItems));
    for (final folder in folders) {
      final items = vs.getFolderItems(folder.id);
      sections.add(_buildSectionHtml(_escape(folder.name), items));
    }

    return '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Nyx Transfer</title>
<style>body{font-family:system-ui;background:#0e0e11;color:#f5f5f7;margin:1rem;max-width:720px;margin-left:auto;margin-right:auto;}
h1{color:#2ee6a6;} h2{font-size:1.1rem;color:#2ee6a6;margin-top:1.5rem;} h3{font-size:1rem;color:#c0c0c0;margin-top:1.25rem;margin-bottom:0.5rem;}
a{color:#2ee6a6;} a.btn{display:inline-block;background:#2ee6a6;color:#0e0e11;padding:0.5rem 1rem;border-radius:8px;text-decoration:none;margin:0.5rem 0;}
table{width:100%;border-collapse:collapse;}
th,td{padding:0.5rem;text-align:left;border-bottom:1px solid #2a2a30;}
th{color:#888;}
td.thumb{width:56px;padding:0.25rem;vertical-align:middle;}
.thumb-img{width:48px;height:48px;object-fit:cover;border-radius:6px;display:block;}
.thumb-placeholder{width:48px;height:48px;border-radius:6px;background:#2a2a30;display:inline-flex;align-items:center;justify-content:center;font-size:1.2rem;}
input[type=file],button{padding:0.5rem 1rem;margin:0.5rem 0;} button{background:#2ee6a6;color:#0e0e11;border:none;border-radius:8px;cursor:pointer;}
.upload{margin:1.5rem 0;padding:1rem;background:#17171c;border-radius:12px;}
.download{margin:1.5rem 0;padding:1rem;background:#17171c;border-radius:12px;}
.upload-progress{margin:0.5rem 0;display:none;}
.upload-progress.visible{display:block;}
.progress-bar{height:8px;background:#2a2a30;border-radius:4px;overflow:hidden;margin:0.25rem 0;}
.progress-fill{height:100%;background:#2ee6a6;transition:width 0.15s ease;}
.upload-status{font-size:0.9rem;color:#c0c0c0;}
.upload-done{font-size:0.9rem;color:#2ee6a6;margin:0.5rem 0;}
.upload-err{font-size:0.9rem;color:#e66;margin:0.5rem 0;}</style></head>
<body>
<h1>Nyx Transfer</h1>
<p>Same WiFi only. Send files to the phone or get files from the phone.</p>

<div class="upload">
<h2>Send to phone</h2>
<form id="uploadForm" enctype="multipart/form-data">
<input type="file" name="file" multiple id="fileInput">
<button type="submit" id="uploadBtn">Upload</button>
</form>
<div id="uploadProgress" class="upload-progress">
  <div class="progress-bar"><div id="progressFill" class="progress-fill" style="width:0%"></div></div>
  <div id="uploadStatus" class="upload-status">Uploading… 0%</div>
</div>
<div id="uploadDone" class="upload-done" style="display:none">Upload complete.</div>
<div id="uploadErr" class="upload-err" style="display:none"></div>
</div>
<script>
(function(){
  var form = document.getElementById('uploadForm');
  var progress = document.getElementById('uploadProgress');
  var progressFill = document.getElementById('progressFill');
  var status = document.getElementById('uploadStatus');
  var done = document.getElementById('uploadDone');
  var err = document.getElementById('uploadErr');
  var btn = document.getElementById('uploadBtn');
  form.onsubmit = function(e) {
    e.preventDefault();
    var fd = new FormData(form);
    if (!fd.getAll('file').length) return;
    progress.classList.add('visible');
    progressFill.style.width = '0%';
    status.textContent = 'Uploading… 0%';
    done.style.display = 'none';
    err.style.display = 'none';
    btn.disabled = true;
    var xhr = new XMLHttpRequest();
    xhr.upload.onprogress = function(ev) {
      if (ev.lengthComputable) {
        var pct = Math.round(ev.loaded / ev.total * 100);
        progressFill.style.width = pct + '%';
        status.textContent = 'Uploading… ' + pct + '%';
      } else {
        status.textContent = 'Uploading…';
      }
    };
    xhr.onload = function() {
      progress.classList.remove('visible');
      btn.disabled = false;
      if (xhr.status >= 200 && xhr.status < 300) {
        done.style.display = 'block';
        setTimeout(function(){ location.reload(); }, 1500);
      } else {
        err.textContent = xhr.responseText || 'Upload failed';
        err.style.display = 'block';
      }
    };
    xhr.onerror = function() {
      progress.classList.remove('visible');
      btn.disabled = false;
      err.textContent = 'Network error';
      err.style.display = 'block';
    };
    xhr.open('POST', '/upload');
    xhr.send(fd);
    return false;
  };
})();
</script>
</div>

<div class="download">
<h2>Get from phone</h2>
<p>Click a file to download it, or get everything as a ZIP.</p>
$downloadAllHtml
${sections.join('\n')}
</div>
</body></html>''';
  }

  String _buildSectionHtml(String sectionTitle, List<VaultItem> items) {
    if (items.isEmpty) return '';
    final rows = items.map((item) {
      final size = _formatBytes(item.sizeBytes);
      final isMedia = item.type == VaultItemType.photo || item.type == VaultItemType.video;
      final thumbCell = isMedia
          ? '<td class="thumb"><img src="/thumbnail/${item.id}" alt="" class="thumb-img" onerror="this.classList.add(\'thumb-fail\'); this.style.background=\'#2a2a30\'; this.style.minWidth=\'48px\'; this.style.minHeight=\'48px\'"></td>'
          : '<td class="thumb"><span class="thumb-placeholder">&#128196;</span></td>';
      return '<tr>$thumbCell<td><a href="/download/${item.id}" download>${_escape(item.displayName)}</a></td><td>$size</td></tr>';
    }).join();
    return '<h3>$sectionTitle</h3><table><thead><tr><th></th><th>File</th><th>Size</th></tr></thead><tbody>$rows</tbody></table>';
  }

  String _escape(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<Response> _handleList(Request request) async {
    if (!_isVaultUnlocked()) return _cors(Response.forbidden('Vault locked'));
    final items = _vaultService.items.map((i) => {
      'id': i.id,
      'name': i.displayName,
      'size': i.sizeBytes,
      'type': i.type.toString().split('.').last,
    }).toList();
    return _cors(Response.ok(
      jsonEncode(items),
      headers: {'Content-Type': 'application/json'},
    ));
  }

  Future<Response> _handleUpload(Request request) async {
    if (!_isVaultUnlocked()) return _cors(Response.forbidden('Vault locked'));
    final contentType = request.headers['content-type'];
    if (contentType == null || !contentType.toLowerCase().contains('multipart')) {
      return _cors(Response.badRequest(body: 'Expected multipart/form-data'));
    }
    HeaderValue headerValue;
    try {
      headerValue = HeaderValue.parse(contentType);
    } catch (_) {
      return _cors(Response.badRequest(body: 'Invalid Content-Type'));
    }
    var boundary = headerValue.parameters['boundary']?.trim();
    if (boundary == null || boundary.isEmpty) return _cors(Response.badRequest(body: 'Missing boundary'));
    if ((boundary.startsWith('"') && boundary.endsWith('"')) || (boundary.startsWith("'") && boundary.endsWith("'"))) {
      boundary = boundary.substring(1, boundary.length - 1);
    }
    _isReceiving = true;
    notifyListeners();
    final transformer = MimeMultipartTransformer(boundary);
    try {
      final bytes = await request.read().expand((x) => x).toList();
      if (bytes.length > _maxUploadBytes) {
        return _cors(Response(413, body: 'File too large'));
      }
      int saved = 0;
      await for (final part in Stream.value(bytes).transform(transformer)) {
        final disposition = part.headers['content-disposition'] ?? '';
        final match = RegExp(r'filename="?([^"\r\n]+)"?').firstMatch(disposition);
        if (match == null) continue;
        final filename = (match.group(1) ?? 'upload').replaceAll(RegExp(r'[\r\n]'), '').split('/').last.split(r'\').last;
        if (filename.trim().isEmpty) continue;
        final data = await part.fold(<int>[], (a, b) => [...a, ...b]);
        final u8 = Uint8List.fromList(data);
        final item = await _vaultService.storeFile(
          data: u8,
          filename: filename,
          source: VaultItemSource.import,
        );
        saved++;
        // Save photos and videos to device gallery so they appear in Photos app
        if (item.type == VaultItemType.photo || item.type == VaultItemType.video) {
          _saveUploadToGallery(item);
        }
      }
      if (saved == 0) return _cors(Response.badRequest(body: 'No file in request'));
      return _cors(Response.ok('Uploaded $saved file(s)'));
    } catch (e) {
      debugPrint('[WiFiTransfer] Upload error: $e');
      return _cors(Response(500, body: e.toString()));
    } finally {
      _isReceiving = false;
      _uploadCompleteTimer?.cancel();
      _showUploadComplete = true;
      _uploadCompleteTimer = Timer(const Duration(seconds: 3), () {
        _showUploadComplete = false;
        notifyListeners();
      });
      notifyListeners();
    }
  }

  /// Saves an uploaded photo or video to the device gallery (Photos app).
  /// Called asynchronously after storeFile; failures are logged only.
  Future<void> _saveUploadToGallery(VaultItem item) async {
    if (item.type != VaultItemType.photo && item.type != VaultItemType.video) return;
    final filePath = _vaultService.getFilePath(item.id);
    if (filePath == null) return;
    final file = File(filePath);
    if (!await file.exists()) return;
    try {
      if (item.type == VaultItemType.photo) {
        final result = await PhotoManager.editor.saveImageWithPath(
          filePath,
          title: item.displayName,
        );
        if (result == null) debugPrint('[WiFiTransfer] Gallery save failed for photo: ${item.id}');
      } else {
        final result = await PhotoManager.editor.saveVideo(
          file,
          title: item.displayName,
        );
        if (result == null) debugPrint('[WiFiTransfer] Gallery save failed for video: ${item.id}');
      }
    } catch (e) {
      debugPrint('[WiFiTransfer] Error saving to gallery: $e');
    }
  }

  Future<Response> _handleThumbnail(Request request, String itemId) async {
    if (!_isVaultUnlocked()) return _cors(Response.forbidden('Vault locked'));
    final thumbPath = _vaultService.getThumbnailPath(itemId);
    if (thumbPath == null) return _cors(Response.notFound('No thumbnail'));
    final file = File(thumbPath);
    if (!await file.exists()) return _cors(Response.notFound('Not found'));
    final bytes = await file.readAsBytes();
    return _cors(Response.ok(
      bytes,
      headers: {
        'Content-Type': 'image/jpeg',
        'Cache-Control': 'private, max-age=300',
      },
    ));
  }

  Future<Response> _handleDownload(Request request, String itemId) async {
    if (!_isVaultUnlocked()) return _cors(Response.forbidden('Vault locked'));
    final path = _vaultService.getFilePath(itemId);
    if (path == null) return _cors(Response.notFound('Not found'));
    final file = File(path);
    if (!await file.exists()) return _cors(Response.notFound('Not found'));
    VaultItem? item;
    for (final i in _vaultService.items) {
      if (i.id == itemId) { item = i; break; }
    }
    final name = item?.originalFilename ?? itemId;
    final stream = file.openRead();
    return _cors(Response.ok(
      stream,
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': 'attachment; filename="${_escapeHeader(name)}"',
      },
    ));
  }

  String _escapeHeader(String s) => s.replaceAll('"', '\\"').replaceAll('\r', '').replaceAll('\n', '');

  Future<Response> _handleDownloadAll(Request request) async {
    if (!_isVaultUnlocked()) return _cors(Response.forbidden('Vault locked'));
    final items = _vaultService.items;
    if (items.isEmpty) {
      return _cors(Response.ok(
        'No files in vault.',
        headers: {'Content-Type': 'text/plain; charset=utf-8'},
      ));
    }
    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('nyx_wifi_zip_');
      final zipPath = path.join(tempDir.path, 'nyx-vault.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipPath, level: ZipFileEncoder.gzip);
      final usedNames = <String, int>{};
      for (final item in items) {
        final filePath = _vaultService.getFilePath(item.id);
        if (filePath == null) continue;
        final f = File(filePath);
        if (!await f.exists()) continue;
        String zipName = item.originalFilename;
        if (zipName.isEmpty) zipName = item.id;
        final count = (usedNames[zipName] ?? 0) + 1;
        usedNames[zipName] = count;
        if (count > 1) {
          final ext = path.extension(zipName);
          final base = path.basenameWithoutExtension(zipName);
          zipName = ext.isEmpty ? '$base ($count)' : '$base ($count)$ext';
        }
        await encoder.addFile(f, zipName);
      }
      await encoder.close();
      final zipFile = File(zipPath);
      if (!await zipFile.exists()) {
        return _cors(Response(500, body: 'Failed to create zip'));
      }
      Future.delayed(const Duration(minutes: 5), () async {
        try {
          await tempDir?.delete(recursive: true);
        } catch (_) {}
      });
      return _cors(Response.ok(
        zipFile.openRead(),
        headers: {
          'Content-Type': 'application/zip',
          'Content-Disposition': 'attachment; filename="nyx-vault.zip"',
        },
      ));
    } catch (e) {
      debugPrint('[WiFiTransfer] Download-all error: $e');
      try {
        await tempDir?.delete(recursive: true);
      } catch (_) {}
      return _cors(Response(500, body: e.toString()));
    }
  }

  Future<bool> startServer() async {
    if (_isRunning) return true;
    // No vault check here: WiFi transfer is only reachable after unlock, so vault is always unlocked
    try {
      final ip = await _getLocalIP();
      final bindAddress = (ip == 'localhost' || ip == '127.0.0.1')
          ? InternetAddress.anyIPv4
          : InternetAddress(ip);
      final router = Router();
      router.get('/', _handleIndex);
      router.get('/api/items', _handleList);
      router.get('/thumbnail/<itemId>', (Request req, String itemId) => _handleThumbnail(req, itemId));
      router.post('/upload', _handleUpload);
      router.get('/download/<itemId>', (Request req, String itemId) => _handleDownload(req, itemId));
      router.get('/download-all', _handleDownloadAll);

      final handler = Pipeline()
          .addMiddleware(_corsOptionsMiddleware())
          .addMiddleware(_logMiddleware())
          .addHandler(router.call);

      try {
        _server = await shelf_io.serve(handler, bindAddress, _port);
      } catch (e) {
        debugPrint('[WiFiTransfer] Bind failed: $e');
        _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, _port);
      }
      _serverUrl = 'http://$ip:$_port';
      _isRunning = true;
      _mdnsDiscoverable = false;
      _usedNativeMdns = false;
      if (ip != 'localhost' && ip != '127.0.0.1') {
        // Prefer native mDNS on iOS/Android (Bonjour/NsdManager) so real devices are discoverable
        if (Platform.isIOS || Platform.isAndroid) {
          try {
            final service = MdnsService(
              name: 'Nyx',
              type: '_http._tcp',
              port: _port,
              hostAddresses: Platform.isAndroid ? [ip] : null,
              attributes: {'path': '/'},
            );
            await MdnsResponder().publishService(service);
            _usedNativeMdns = true;
            _mdnsDiscoverable = true;
            debugPrint('[WiFiTransfer] mDNS (native): discoverable as "Nyx"');
          } catch (e) {
            debugPrint('[WiFiTransfer] Native mDNS failed: $e');
          }
        }
        // Fallback: pure Dart mDNS (works on desktop; can help on mobile if native failed)
        if (!_mdnsDiscoverable) {
          try {
            final mdnsService = await MDNSService.create(
              instance: 'Nyx',
              service: '_http._tcp',
              port: _port,
              ips: [InternetAddress(ip)],
              txt: ['path=/'],
            );
            _mdnsServer = MDNSServer(MDNSServerConfig(zone: mdnsService));
            await _mdnsServer!.start();
            _mdnsDiscoverable = true;
            debugPrint('[WiFiTransfer] mDNS (dart): discoverable as "Nyx"');
          } catch (e) {
            debugPrint('[WiFiTransfer] mDNS dart failed: $e');
          }
        }
      }
      debugPrint('[WiFiTransfer] Started $_serverUrl');
      notifyListeners();
      return true;
    } catch (e, st) {
      debugPrint('[WiFiTransfer] Start error: $e');
      debugPrint('[WiFiTransfer] $st');
      if (_port < 8090) {
        _port++;
        return startServer();
      }
      notifyListeners();
      return false;
    }
  }

  Middleware _logMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        debugPrint('[WiFiTransfer] ${request.method} ${request.url}');
        return handler(request);
      };
    };
  }

  Future<void> stopServer() async {
    if (!_isRunning || _server == null) return;
    if (_usedNativeMdns) {
      try {
        await MdnsResponder().stopService();
      } catch (e) {
        debugPrint('[WiFiTransfer] Native mDNS stop: $e');
      }
      _usedNativeMdns = false;
    }
    if (_mdnsServer != null) {
      try {
        await _mdnsServer!.stop();
      } catch (e) {
        debugPrint('[WiFiTransfer] mDNS stop: $e');
      }
      _mdnsServer = null;
    }
    _mdnsDiscoverable = false;
    try {
      await _server!.close(force: true);
    } catch (e) {
      debugPrint('[WiFiTransfer] Stop error: $e');
    }
    _server = null;
    _serverUrl = null;
    _isRunning = false;
    notifyListeners();
  }
}

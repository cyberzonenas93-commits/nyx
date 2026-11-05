import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'vault_cipher.dart';

/// What the server needs to serve one encrypted vault file.
class VaultStreamSource {
  final String cipherPath;
  final String fileId;
  final String contentType;

  const VaultStreamSource({
    required this.cipherPath,
    required this.fileId,
    required this.contentType,
  });
}

/// Decrypts [count] chunks of [source] starting at [firstChunk].
typedef VaultChunkDecryptor = Future<Uint8List> Function(
    VaultStreamSource source, int firstChunk, int count);

/// Serves encrypted vault videos to the platform player over
/// http://127.0.0.1, decrypting only the chunks a Range request touches.
///
/// Playback used to decrypt the whole video to a temp file before the first
/// frame, so a large video sat on a spinner for tens of seconds. AVPlayer reads
/// a few small ranges to start, so with this it starts at once at any size,
/// seeks without waiting, and no plaintext copy is written to disk.
///
/// Bound to loopback only. Every URL carries a random per-session token, and
/// the server is stopped when the vault locks, which also invalidates the
/// token.
class VaultStreamServer {
  VaultStreamServer({required this.resolve, required this.decrypt});

  /// Returns the file for an item id, or null when unknown or locked.
  final VaultStreamSource? Function(String itemId) resolve;
  final VaultChunkDecryptor decrypt;

  /// Chunks decrypted per call (2 MiB): small enough to start fast, large
  /// enough that sequential playback is not call-bound.
  static const int chunksPerRead = 2;

  HttpServer? _server;
  String? _token;
  Future<void>? _starting;

  bool get isRunning => _server != null;

  Future<Uri> uriFor(String itemId, {String? extension}) async {
    await _ensureStarted();
    final name = extension != null && extension.isNotEmpty
        ? '$itemId.$extension'
        : itemId;
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: _server!.port,
      pathSegments: <String>[_token!, name],
    );
  }

  Future<void> _ensureStarted() {
    if (_server != null) return Future<void>.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    final random = Random.secure();
    final token = List<int>.generate(24, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.idleTimeout = const Duration(seconds: 30);
    server.serverHeader = null;
    _token = token;
    _server = server;
    server.listen(
      (request) => unawaited(_handle(request, token)),
      onError: (Object e) => debugPrint('[VaultStream] Server error: $e'),
    );
    debugPrint('[VaultStream] Listening on 127.0.0.1:${server.port}');
  }

  Future<void> stop() async {
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }
    final server = _server;
    _server = null;
    _token = null;
    if (server != null) {
      await server.close(force: true);
      debugPrint('[VaultStream] Stopped');
    }
  }

  Future<void> _handle(HttpRequest request, String token) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (segments.length != 2 ||
          !_sameToken(segments[0], token) ||
          token != _token ||
          (request.method != 'GET' && request.method != 'HEAD')) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final name = segments[1];
      final dot = name.indexOf('.');
      final itemId = dot > 0 ? name.substring(0, dot) : name;
      final source = resolve(itemId);
      final cipherFile = source == null ? null : File(source.cipherPath);
      if (source == null || !await cipherFile!.exists()) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final total = VaultCipher.plaintextLengthForCipherLength(
          await cipherFile.length());
      final range = parseRange(request.headers.value(HttpHeaders.rangeHeader), total);
      response.headers
        ..set(HttpHeaders.contentTypeHeader, source.contentType)
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.cacheControlHeader, 'no-store');

      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        response.contentLength = 0;
        await response.close();
        return;
      }

      final (start, end, partial) = range;
      final length = total == 0 ? 0 : end - start + 1;
      response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
      if (partial) {
        response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      }
      response.contentLength = length;
      if (request.method == 'HEAD' || length == 0) {
        await response.close();
        return;
      }
      await response.addStream(_body(source, start, end));
      await response.close();
    } on HttpException {
      // Player cancelled the request (seek, switch, dispose). Normal.
    } on SocketException {
      // Same: the connection went away mid-response.
    } catch (e) {
      debugPrint('[VaultStream] Request failed: $e');
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    }
  }

  Stream<List<int>> _body(VaultStreamSource source, int start, int end) async* {
    const chunkSize = VaultCipher.chunkPlaintextSize;
    var position = start;
    while (position <= end) {
      final firstChunk = position ~/ chunkSize;
      final lastChunk = end ~/ chunkSize;
      final count = min(chunksPerRead, lastChunk - firstChunk + 1);
      final plain = await decrypt(source, firstChunk, count);
      final base = firstChunk * chunkSize;
      final from = position - base;
      final to = min(plain.length, end - base + 1);
      if (to <= from) {
        throw StateError('Ciphertext shorter than its length implies');
      }
      yield Uint8List.sublistView(plain, from, to);
      position = base + to;
    }
  }

  static bool _sameToken(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Parses a single-range `Range` header against [total] bytes.
  /// Returns (start, endInclusive, isPartial), or null when unsatisfiable.
  /// A missing or malformed header means the whole file.
  @visibleForTesting
  static (int, int, bool)? parseRange(String? header, int total) {
    final whole = (0, total == 0 ? 0 : total - 1, false);
    if (header == null) return whole;
    final match = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$').firstMatch(header);
    if (match == null) return whole;
    final a = match.group(1)!;
    final b = match.group(2)!;
    if (a.isEmpty && b.isEmpty) return whole;
    if (total == 0) return null;
    int start;
    int end;
    if (a.isEmpty) {
      // Suffix range: the last N bytes.
      final n = int.parse(b);
      if (n == 0) return null;
      start = max(0, total - n);
      end = total - 1;
    } else {
      start = int.parse(a);
      end = b.isEmpty ? total - 1 : min(int.parse(b), total - 1);
      if (start >= total || end < start) return null;
    }
    return (start, end, true);
  }

  /// MIME type for the player. AVFoundation picks its parser from this.
  static String contentTypeFor(String? extension, String? mimeType) {
    switch ((extension ?? '').toLowerCase()) {
      case 'mov':
      case 'qt':
        return 'video/quicktime';
      case 'mp4':
        return 'video/mp4';
      case 'm4v':
        return 'video/x-m4v';
      case '3gp':
        return 'video/3gpp';
      case 'm4a':
        return 'audio/mp4';
      case 'mp3':
        return 'audio/mpeg';
    }
    if (mimeType != null && mimeType.contains('/')) return mimeType;
    return 'video/mp4';
  }
}

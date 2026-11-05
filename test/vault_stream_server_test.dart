import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyx/core/services/encryption_service.dart';
import 'package:nyx/core/services/vault_cipher.dart';
import 'package:nyx/core/services/vault_stream_server.dart';

void main() {
  const mib = VaultCipher.chunkPlaintextSize;

  group('plaintextLengthForCipherLength', () {
    final cipher = VaultCipher(EncryptionService());
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
    for (final size in <int>[0, 1, 1000, mib - 1, mib, mib + 1, 3 * mib - 5, 2 * mib]) {
      test('$size bytes', () {
        final ct = cipher.encryptBytes(
            masterKey: key, fileId: 'len', plaintext: Uint8List(size));
        expect(VaultCipher.plaintextLengthForCipherLength(ct.length), size);
      });
    }
    test('rejects impossible lengths', () {
      expect(() => VaultCipher.plaintextLengthForCipherLength(10),
          throwsA(isA<VaultCipherException>()));
      expect(
          () => VaultCipher.plaintextLengthForCipherLength(
              1 + VaultCipher.chunkOnDiskSize + 5),
          throwsA(isA<VaultCipherException>()));
    });
  });

  group('parseRange', () {
    test('cases', () {
      expect(VaultStreamServer.parseRange(null, 100), (0, 99, false));
      expect(VaultStreamServer.parseRange('bytes=0-1', 100), (0, 1, true));
      expect(VaultStreamServer.parseRange('bytes=10-', 100), (10, 99, true));
      expect(VaultStreamServer.parseRange('bytes=-30', 100), (70, 99, true));
      expect(VaultStreamServer.parseRange('bytes=-300', 100), (0, 99, true));
      expect(VaultStreamServer.parseRange('bytes=90-500', 100), (90, 99, true));
      expect(VaultStreamServer.parseRange('bytes=100-', 100), isNull);
      expect(VaultStreamServer.parseRange('bytes=5-2', 100), isNull);
      expect(VaultStreamServer.parseRange('bytes=-0', 100), isNull);
      expect(VaultStreamServer.parseRange('items=0-1', 100), (0, 99, false));
    });
  });

  group('VaultStreamServer', () {
    late Directory dir;
    late Uint8List plain;
    late VaultStreamServer server;
    late HttpClient client;
    final masterKey = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
    const fileId = 'video-item-1';

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('nyx_stream_');
      final r = Random(7);
      plain = Uint8List.fromList(
          List<int>.generate(2 * mib + 123457, (_) => r.nextInt(256)));
      final cipher = VaultCipher(EncryptionService());
      final cipherFile = File('${dir.path}/$fileId.mp4');
      await cipherFile.writeAsBytes(
          cipher.encryptBytes(masterKey: masterKey, fileId: fileId, plaintext: plain));
      server = VaultStreamServer(
        resolve: (id) => id == fileId
            ? VaultStreamSource(
                cipherPath: cipherFile.path,
                fileId: fileId,
                contentType: 'video/mp4')
            : null,
        decrypt: (source, first, count) async {
          final raf = await File(source.cipherPath).open();
          try {
            return await cipher.decryptChunkRange(
              masterKey: masterKey,
              fileId: source.fileId,
              raf: raf,
              fileLength: await raf.length(),
              firstChunk: first,
              count: count,
            );
          } finally {
            await raf.close();
          }
        },
      );
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      await dir.delete(recursive: true);
    });

    Future<(int, HttpHeaders, Uint8List)> get(Uri uri,
        {String? range, String method = 'GET'}) async {
      final req = await client.openUrl(method, uri);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final res = await req.close();
      final builder = BytesBuilder();
      await for (final piece in res) {
        builder.add(piece);
      }
      return (res.statusCode, res.headers, builder.toBytes());
    }

    test('whole file without Range', () async {
      final uri = await server.uriFor(fileId, extension: 'mp4');
      expect(uri.host, '127.0.0.1');
      final (status, headers, body) = await get(uri);
      expect(status, 200);
      expect(headers.contentType?.mimeType, 'video/mp4');
      expect(headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(body, plain);
    });

    test('AVPlayer probe and ranges across chunk boundaries', () async {
      final uri = await server.uriFor(fileId, extension: 'mp4');
      final probe = await get(uri, range: 'bytes=0-1');
      expect(probe.$1, 206);
      expect(probe.$2.value(HttpHeaders.contentRangeHeader),
          'bytes 0-1/${plain.length}');
      expect(probe.$3, plain.sublist(0, 2));

      final across = await get(uri, range: 'bytes=${mib - 10}-${2 * mib + 10}');
      expect(across.$1, 206);
      expect(across.$3, plain.sublist(mib - 10, 2 * mib + 11));

      final tail = await get(uri, range: 'bytes=-100');
      expect(tail.$3, plain.sublist(plain.length - 100));

      final open = await get(uri, range: 'bytes=${2 * mib}-');
      expect(open.$3, plain.sublist(2 * mib));
    });

    test('HEAD, bad token, unknown item, unsatisfiable range', () async {
      final uri = await server.uriFor(fileId, extension: 'mp4');
      final head = await get(uri, method: 'HEAD');
      expect(head.$1, 200);
      expect(head.$2.contentLength, plain.length);
      expect(head.$3, isEmpty);

      final segments = List<String>.of(uri.pathSegments);
      final badToken =
          uri.replace(pathSegments: <String>['0' * segments[0].length, segments[1]]);
      expect((await get(badToken)).$1, 404);
      final unknown = uri.replace(pathSegments: <String>[segments[0], 'other.mp4']);
      expect((await get(unknown)).$1, 404);
      expect((await get(uri, range: 'bytes=${plain.length}-')).$1, 416);
    });

    test('stop invalidates URLs; restart issues a new token', () async {
      final first = await server.uriFor(fileId, extension: 'mp4');
      await server.stop();
      expect(server.isRunning, isFalse);
      await expectLater(get(first), throwsA(isA<SocketException>()));
      final second = await server.uriFor(fileId, extension: 'mp4');
      expect(second.pathSegments.first, isNot(first.pathSegments.first));
      expect((await get(second, range: 'bytes=0-9')).$3, plain.sublist(0, 10));
    });

    test('tampered chunk fails the request instead of serving bad bytes',
        () async {
      final cipherFile = File('${dir.path}/$fileId.mp4');
      final bytes = await cipherFile.readAsBytes();
      bytes[VaultCipher.cipherOffsetOfChunk(1) + 40] ^= 0x01;
      await cipherFile.writeAsBytes(bytes);
      final uri = await server.uriFor(fileId, extension: 'mp4');
      final ok = await get(uri, range: 'bytes=0-99');
      expect(ok.$3, plain.sublist(0, 100));
      Object? failure;
      try {
        final bad = await get(uri, range: 'bytes=${mib}-${mib + 99}');
        expect(bad.$3, isNot(plain.sublist(mib, mib + 100)));
      } catch (e) {
        failure = e;
      }
      // Either the connection is cut or the body is not the plaintext.
      expect(failure == null || failure is HttpException, isTrue);
    });
  });
}

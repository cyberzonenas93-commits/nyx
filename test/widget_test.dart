import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nyx/core/services/encryption_service.dart';

void main() {
  group('EncryptionService', () {
    late EncryptionService service;

    setUp(() {
      service = EncryptionService();
    });

    test('verifies a hashed password', () async {
      final salt = Uint8List.fromList(List<int>.generate(32, (index) => index));
      final hash = await service.hashPassword('123456', salt);

      expect(await service.verifyPassword('123456', hash), isTrue);
      expect(await service.verifyPassword('654321', hash), isFalse);
    });

    test('rejects malformed password hashes', () async {
      expect(await service.verifyPassword('123456', 'not-base64'), isFalse);
      expect(await service.verifyPassword('123456', ''), isFalse);
    });

    test('encrypts and decrypts strings round-trip', () {
      final key =
          Uint8List.fromList(List<int>.generate(32, (index) => index + 1));
      final encrypted = service.encryptString('hello nyx', key);

      expect(service.decryptString(encrypted, key), 'hello nyx');
    });
  });
}

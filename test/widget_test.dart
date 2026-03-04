import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

import 'package:nyx/app/app.dart';
import 'package:nyx/core/services/auth_service.dart';
import 'package:nyx/core/services/encryption_service.dart';
import 'package:nyx/core/services/panic_switch_service.dart';

class _InMemorySecureStorage extends FlutterSecureStoragePlatform {
  final Map<String, String> _store = <String, String>{};

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    _store[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    return _store[key];
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async {
    return _store.containsKey(key);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    _store.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    return Map<String, String>.from(_store);
  }

  @override
  Future<void> deleteAll({
    required Map<String, String> options,
  }) async {
    _store.clear();
  }
}

class _TestPanicSwitchService extends PanicSwitchService {
  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<void> startMonitoring() async {}

  @override
  Future<void> stopMonitoring() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStoragePlatform.instance = _InMemorySecureStorage();
  });

  testWidgets('App smoke test', (WidgetTester tester) async {
    final encryptionService = EncryptionService();
    final authService = AuthService(encryptionService);
    final panicSwitchService = _TestPanicSwitchService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: authService),
          Provider<PanicSwitchService>.value(value: panicSwitchService),
        ],
        child: const MediaPrivacyVaultApp(),
      ),
    );

    // Let delayed post-frame timers complete (e.g. permission check + onboarding scroll checks).
    await tester.pump(const Duration(seconds: 3));

    expect(find.byType(MediaPrivacyVaultApp), findsOneWidget);
  });
}

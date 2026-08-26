/// Compile-time configuration for Apple App Store receipt validation.
///
/// Set at build time so your validation endpoint and secrets are not hard-coded:
///
/// ```bash
/// flutter build ipa --dart-define=APPSTORE_RECEIPT_VALIDATE_URL=https://api.example.com/apple/validate-receipt
/// ```
///
/// Optional Bearer token for your backend:
///
/// ```bash
/// --dart-define=APPSTORE_RECEIPT_VALIDATE_AUTH=your-server-token
/// ```
///
/// See `docs/APPLE_RECEIPT_VALIDATION.md` for App Store Connect and backend setup.
class AppleReceiptValidationConfig {
  AppleReceiptValidationConfig._();

  /// HTTPS URL of **your** server that validates the receipt with Apple.
  /// Empty = validation skipped (current behavior: trust StoreKit only).
  static const String validateUrl = String.fromEnvironment(
    'APPSTORE_RECEIPT_VALIDATE_URL',
    defaultValue: '',
  );

  /// Optional `Authorization: Bearer <value>` sent to [validateUrl].
  static const String validateAuthBearer = String.fromEnvironment(
    'APPSTORE_RECEIPT_VALIDATE_AUTH',
    defaultValue: '',
  );

  static bool get isEnabled => validateUrl.trim().isNotEmpty;
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/apple_receipt_validation_config.dart';

/// Sends the App Store receipt (base64) to your backend for validation.
///
/// Your server should call Apple’s [verifyReceipt] API with your **App-Specific
/// Shared Secret** (never put that secret in the app).
///
/// [verifyReceipt]: https://developer.apple.com/documentation/appstorereceipts/verifyreceipt
class AppleReceiptValidationService {
  AppleReceiptValidationService._();
  static final AppleReceiptValidationService instance =
      AppleReceiptValidationService._();

  /// POST body field name your server can read (`receipt_data`).
  static const _jsonKeyReceipt = 'receipt_data';

  /// Returns `true` if the server confirms the receipt is valid.
  ///
  /// Expected success: HTTP 200 and JSON containing `"valid": true`
  /// (or top-level `"status": 0` for raw Apple-style responses from a thin proxy).
  Future<bool> validateReceipt(String receiptBase64) async {
    if (!AppleReceiptValidationConfig.isEnabled) {
      return true;
    }
    final url = AppleReceiptValidationConfig.validateUrl.trim();
    if (url.isEmpty) return true;

    final trimmed = receiptBase64.trim();
    if (trimmed.isEmpty) {
      debugPrint('[AppleReceiptValidation] Empty receipt; treating as invalid');
      return false;
    }

    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (e) {
      debugPrint('[AppleReceiptValidation] Invalid URL: $e');
      return false;
    }
    if (!uri.hasScheme || (uri.scheme != 'https' && uri.scheme != 'http')) {
      debugPrint('[AppleReceiptValidation] URL must be http(s)');
      return false;
    }
    if (uri.scheme == 'http' && !kDebugMode) {
      debugPrint('[AppleReceiptValidation] Use HTTPS in release builds');
      return false;
    }

    try {
      final headers = <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
      };
      final auth = AppleReceiptValidationConfig.validateAuthBearer.trim();
      if (auth.isNotEmpty) {
        headers['Authorization'] = 'Bearer $auth';
      }

      final response = await http
          .post(
            uri,
            headers: headers,
            body: jsonEncode(<String, String>{_jsonKeyReceipt: trimmed}),
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode != 200) {
        debugPrint(
          '[AppleReceiptValidation] HTTP ${response.statusCode}: ${response.body}',
        );
        return false;
      }

      final dynamic decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        if (decoded['valid'] == true) return true;
        // Thin proxy returning Apple’s verifyReceipt JSON
        if (decoded['status'] == 0) return true;
      }
      debugPrint('[AppleReceiptValidation] Unexpected response: ${response.body}');
      return false;
    } catch (e, st) {
      debugPrint('[AppleReceiptValidation] Request failed: $e\n$st');
      return false;
    }
  }
}

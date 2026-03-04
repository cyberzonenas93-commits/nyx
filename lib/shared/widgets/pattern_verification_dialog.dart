import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../app/theme.dart';
import '../../core/services/auth_service.dart';
import '../../features/unlock/widgets/pattern_lock_widget.dart';

/// Dialog to verify pattern (primary or a specific secondary vault).
/// Pops with true if pattern verified, null if cancelled.
class PatternVerificationDialog extends StatefulWidget {
  final String? title;
  final String? message;
  /// If set, verify this secondary vault's pattern instead of primary.
  final String? vaultId;

  const PatternVerificationDialog({
    super.key,
    this.title,
    this.message,
    this.vaultId,
  });

  static Future<bool?> show(
    BuildContext context, {
    String? title,
    String? message,
    String? vaultId,
  }) async {
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PatternVerificationDialog(
        title: title,
        message: message,
        vaultId: vaultId,
      ),
    );
  }

  @override
  State<PatternVerificationDialog> createState() => _PatternVerificationDialogState();
}

class _PatternVerificationDialogState extends State<PatternVerificationDialog> {
  String? _errorMessage;
  bool _wrongAttempt = false;

  Future<void> _onPatternComplete(List<int> indices) async {
    final patternString = patternToString(indices);
    final authService = Provider.of<AuthService>(context, listen: false);

    if (widget.vaultId != null) {
      final ok = await authService.verifySecondaryVaultPattern(widget.vaultId!, patternString);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
        return;
      }
    } else {
      final result = await authService.verifyPattern(patternString);
      if (!mounted) return;
      if (result == AuthResult.unlocked) {
        Navigator.of(context).pop(true);
        return;
      }
    }
      setState(() {
        _errorMessage = 'Wrong pattern';
        _wrongAttempt = true;
      });
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() {
          _wrongAttempt = false;
          _errorMessage = null;
        });
      });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.gesture_outlined,
              size: 48,
              color: AppTheme.accent,
            ),
            const SizedBox(height: 16),
            Text(
              widget.title ?? 'Draw your pattern',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
            ),
            if (widget.message != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.message!,
                style: TextStyle(
                  fontSize: 14,
                  color: AppTheme.text.withOpacity(0.7),
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
            PatternLockWidget(
              minLength: kPatternMinLength,
              wrongAttempt: _wrongAttempt,
              onPatternComplete: _onPatternComplete,
              onPatternTooShort: () {
                setState(() => _errorMessage = 'Use at least 4 dots');
              },
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(
                  color: AppTheme.warning,
                  fontSize: 14,
                ),
              ),
            ],
            const SizedBox(height: 20),
            TextButton(
              onPressed: () => Navigator.of(context).pop<bool?>(null),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

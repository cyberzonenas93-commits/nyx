import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../app/theme.dart';
import '../../core/services/auth_service.dart';

/// Dialog for verifying PIN before sensitive actions
/// Returns PIN string if PIN entered, or null if cancelled
class PinVerificationDialog extends StatefulWidget {
  final String? title;
  final String? message;
  
  const PinVerificationDialog({super.key, this.title, this.message});

  static Future<String?> show(
    BuildContext context, {
    String? title,
    String? message,
  }) async {
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PinVerificationDialog(
        title: title,
        message: message,
      ),
    );
  }

  @override
  State<PinVerificationDialog> createState() => _PinVerificationDialogState();
}

class _PinVerificationDialogState extends State<PinVerificationDialog> {
  String _pin = '';
  String? _errorMessage;
  bool _isLoading = false;

  void _onNumberPressed(String number) {
    if (_pin.length >= 6) return;
    
    setState(() {
      _pin += number;
      _errorMessage = null;
    });
    
    // Auto-submit when 6 digits entered
    if (_pin.length == 6) {
      _verifyPIN();
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _errorMessage = null;
    });
  }

  void _verifyPIN() async {
    if (_pin.length != 6) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // Return the PIN string to the caller for verification
    if (mounted) {
      Navigator.of(context).pop(_pin);
    }
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
              Icons.lock_outline,
              size: 48,
              color: AppTheme.accent,
            ),
            const SizedBox(height: 16),
            Text(
              widget.title ?? 'Enter PIN to Unlock',
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
            
            // PIN dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(6, (index) {
                final isFilled = index < _pin.length;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isFilled ? AppTheme.accent : AppTheme.surfaceVariant,
                  ),
                );
              }),
            ),
            
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                  border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, color: AppTheme.warning, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: AppTheme.warning,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            
            const SizedBox(height: 24),
            
            // Number pad
            Column(
              children: [
                Row(
                  children: [
                    _DialogNumberButton('1', onPressed: () => _onNumberPressed('1')),
                    _DialogNumberButton('2', onPressed: () => _onNumberPressed('2')),
                    _DialogNumberButton('3', onPressed: () => _onNumberPressed('3')),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _DialogNumberButton('4', onPressed: () => _onNumberPressed('4')),
                    _DialogNumberButton('5', onPressed: () => _onNumberPressed('5')),
                    _DialogNumberButton('6', onPressed: () => _onNumberPressed('6')),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _DialogNumberButton('7', onPressed: () => _onNumberPressed('7')),
                    _DialogNumberButton('8', onPressed: () => _onNumberPressed('8')),
                    _DialogNumberButton('9', onPressed: () => _onNumberPressed('9')),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Expanded(child: SizedBox()),
                    _DialogNumberButton('0', onPressed: () => _onNumberPressed('0')),
                    Expanded(
                      child: IconButton(
                        onPressed: _pin.isNotEmpty ? _onBackspace : null,
                        icon: const Icon(Icons.backspace_outlined),
                        color: AppTheme.text,
                        iconSize: 24,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            
            if (_isLoading) ...[
              const SizedBox(height: 16),
              const CircularProgressIndicator(
                color: AppTheme.accent,
              ),
            ],
            
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).pop<String?>(null),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogNumberButton extends StatelessWidget {
  final String number;
  final VoidCallback? onPressed;

  const _DialogNumberButton(this.number, {this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.surfaceVariant,
            foregroundColor: AppTheme.text,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radius),
            ),
          ),
          child: Text(
            number,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

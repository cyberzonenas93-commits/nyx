import 'package:flutter/material.dart';
import '../../app/theme.dart';

/// Lock overlay displayed when vault is locked or intrusion detected
class LockOverlay extends StatelessWidget {
  final String message;
  final VoidCallback? onUnlock;
  
  const LockOverlay({
    super.key,
    this.message = 'Vault Locked',
    this.onUnlock,
  });
  
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.primary,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lock_outline,
              size: 64,
              color: AppTheme.accent,
            ),
            const SizedBox(height: 24),
            Text(
              message,
              style: const TextStyle(
                color: AppTheme.text,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (onUnlock != null) ...[
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: onUnlock,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                ),
                child: const Text('Unlock'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

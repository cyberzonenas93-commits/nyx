import 'package:flutter/material.dart';
import '../../app/theme.dart';

/// Warning dialog for critical actions like deletion
class WarningDialog extends StatelessWidget {
  final String title;
  final String message;
  final String confirmText;
  final String cancelText;
  final VoidCallback onConfirm;
  final VoidCallback? onCancel;
  
  const WarningDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmText = 'Confirm',
    this.cancelText = 'Cancel',
    required this.onConfirm,
    this.onCancel,
  });
  
  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = 'Confirm',
    String cancelText = 'Cancel',
    required VoidCallback onConfirm,
    VoidCallback? onCancel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => WarningDialog(
        title: title,
        message: message,
        confirmText: confirmText,
        cancelText: cancelText,
        onConfirm: onConfirm,
        onCancel: onCancel,
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: AppTheme.warning,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title),
          ),
        ],
      ),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () {
            if (onCancel != null) {
              onCancel!();
            }
            Navigator.of(context).pop(false);
          },
          child: Text(cancelText),
        ),
        ElevatedButton(
          onPressed: () {
            onConfirm();
            Navigator.of(context).pop(true);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.warning,
            foregroundColor: AppTheme.text,
          ),
          child: Text(confirmText),
        ),
      ],
    );
  }
}

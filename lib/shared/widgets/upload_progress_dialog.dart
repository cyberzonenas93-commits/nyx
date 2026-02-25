import 'package:flutter/material.dart';
import '../../app/theme.dart';

/// Upload progress dialog for showing file upload status
/// Uses StatefulBuilder to allow updates without closing/reopening
class UploadProgressDialog extends StatefulWidget {
  final int initialCurrent;
  final int total;
  final String? initialFileName;
  
  const UploadProgressDialog({
    super.key,
    required this.initialCurrent,
    required this.total,
    this.initialFileName,
  });

  static void show(
    BuildContext context, {
    required int current,
    required int total,
    String? currentFileName,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => UploadProgressDialog(
        initialCurrent: current,
        total: total,
        initialFileName: currentFileName,
      ),
    );
  }

  static void update(
    BuildContext context, {
    required int current,
    required int total,
    String? currentFileName,
  }) {
    // Close existing and show updated version
    // This is simpler than trying to maintain state across dialog updates
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      // Small delay to ensure dialog is closed before showing new one
      // Only show new dialog if not at 100% (to avoid flicker when hiding)
      if (current < total) {
        Future.delayed(const Duration(milliseconds: 50), () {
          if (context.mounted) {
            show(context, current: current, total: total, currentFileName: currentFileName);
          }
        });
      }
    }
  }

  static void hide(BuildContext context) {
    Navigator.of(context).pop();
  }

  @override
  State<UploadProgressDialog> createState() => _UploadProgressDialogState();
}

class _UploadProgressDialogState extends State<UploadProgressDialog> {
  late int _current;
  late int _total;
  String? _currentFileName;

  @override
  void initState() {
    super.initState();
    _current = widget.initialCurrent;
    _total = widget.total;
    _currentFileName = widget.initialFileName;
  }

  void _updateProgress(int current, int total, String? fileName) {
    if (mounted) {
      setState(() {
        _current = current;
        _total = total;
        _currentFileName = fileName;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total > 0 ? _current / _total : 0.0;
    
    return PopScope(
      canPop: false, // Prevent dismissing
      child: AlertDialog(
        backgroundColor: AppTheme.surface,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(
              color: AppTheme.accent,
            ),
            const SizedBox(height: 24),
            Text(
              'Uploading files...',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$_current of $_total',
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.text.withOpacity(0.7),
              ),
            ),
            if (_currentFileName != null) ...[
              const SizedBox(height: 8),
              Text(
                _currentFileName!,
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.text.withOpacity(0.6),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: progress,
              backgroundColor: AppTheme.surfaceVariant,
              valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.accent),
            ),
            const SizedBox(height: 8),
            Text(
              '${(progress * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.text.withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/theme.dart';

/// Dialog for renaming vault items
class RenameDialog extends StatefulWidget {
  final String currentName;
  final String? originalName;
  final String title;
  
  const RenameDialog({
    super.key,
    required this.currentName,
    this.originalName,
    this.title = 'Rename Item',
  });
  
  static Future<String?> show(
    BuildContext context, {
    required String currentName,
    String? originalName,
    String title = 'Rename Item',
  }) async {
    return await showDialog<String>(
      context: context,
      builder: (context) => RenameDialog(
        currentName: currentName,
        originalName: originalName,
        title: title,
      ),
    );
  }
  
  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late TextEditingController _nameController;
  
  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName);
  }
  
  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: Text(
        widget.title,
        style: const TextStyle(color: AppTheme.text),
      ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.8,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter a new name for this item:',
              style: TextStyle(color: AppTheme.text),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              autofocus: true,
              style: const TextStyle(color: AppTheme.text),
              decoration: InputDecoration(
                hintText: 'Enter name',
                hintStyle: TextStyle(color: AppTheme.text.withOpacity(0.5)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  borderSide: BorderSide(color: AppTheme.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  borderSide: BorderSide(color: AppTheme.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  borderSide: BorderSide(color: AppTheme.accent),
                ),
              ),
              maxLength: 255,
              textInputAction: TextInputAction.done,
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  Navigator.of(context).pop(value.trim());
                }
              },
            ),
            if (widget.originalName != null && widget.originalName != widget.currentName) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  _nameController.text = widget.originalName!;
                },
                child: Text(
                  'Revert to original: ${widget.originalName}',
                  style: TextStyle(
                    color: AppTheme.accent,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final newName = _nameController.text.trim();
            if (newName.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Name cannot be empty'),
                  backgroundColor: AppTheme.warning,
                  behavior: SnackBarBehavior.floating,
                ),
              );
              return;
            }
            Navigator.of(context).pop(newName);
          },
          style: TextButton.styleFrom(
            foregroundColor: AppTheme.accent,
          ),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

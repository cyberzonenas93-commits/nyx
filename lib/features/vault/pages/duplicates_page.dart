import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/theme.dart';
import '../../../core/models/vault_item.dart';
import '../../../core/services/subscription_service.dart';
import '../../../core/services/vault_service.dart';
import '../../subscription/pages/paywall_page.dart';

/// Finds files stored more than once (identical content) and deletes the
/// extra copies the user picks. Every set keeps at least one copy. Premium.
class DuplicatesPage extends StatefulWidget {
  const DuplicatesPage({super.key});

  /// Opens the duplicate finder for Premium and trial users, the paywall for
  /// everyone else.
  static Future<void> open(BuildContext context) {
    final subscription = context.read<SubscriptionService>();
    final hasPremium =
        subscription.currentTier.isUnlimited || subscription.isInTrial;
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => hasPremium
          ? const DuplicatesPage()
          : const PaywallPage(showCloseButton: true),
    ));
  }

  @override
  State<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends State<DuplicatesPage> {
  List<DuplicateGroup>? _groups;
  final Set<String> _selected = {};
  int _done = 0;
  int _total = 0;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _groups = null;
      _done = 0;
      _total = 0;
    });
    final groups = await context.read<VaultService>().findDuplicateGroups(
      onProgress: (done, total) {
        if (mounted) setState(() => (_done, _total) = (done, total));
      },
    );
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _selected
        ..clear()
        ..addAll([for (final g in groups) ...g.items.skip(1).map((i) => i.id)]);
    });
  }

  void _toggle(DuplicateGroup group, VaultItem item) {
    setState(() {
      if (_selected.remove(item.id)) return;
      // Never let a whole set be selected: one copy always stays.
      final kept = group.items.where((i) => !_selected.contains(i.id)).length;
      if (kept > 1) _selected.add(item.id);
    });
  }

  int get _selectedBytes => [
        for (final g in _groups ?? const <DuplicateGroup>[]) ...g.items
      ].where((i) => _selected.contains(i.id)).fold(0, (s, i) => s + i.sizeBytes);

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: const Text('Delete copies',
            style: TextStyle(color: AppTheme.text)),
        content: Text(
          'Delete $count duplicate ${count == 1 ? 'copy' : 'copies'} '
          '(${_formatBytes(_selectedBytes)})? One copy of each file stays in '
          'your vault. This cannot be undone.',
          style: const TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.warning),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    setState(() => _deleting = true);
    final vault = context.read<VaultService>();
    final messenger = ScaffoldMessenger.of(context);
    final freed = _selectedBytes;
    var removed = 0;
    for (final group in _groups ?? const <DuplicateGroup>[]) {
      final kept = group.items.firstWhere((i) => !_selected.contains(i.id));
      for (final copy in group.items.where((i) => _selected.contains(i.id))) {
        if (await vault.deleteDuplicateCopy(copy.id, keptId: kept.id)) {
          removed++;
        }
      }
    }
    if (!mounted) return;
    setState(() => _deleting = false);
    messenger.showSnackBar(SnackBar(
      content: Text('Deleted $removed ${removed == 1 ? 'copy' : 'copies'}, '
          'freed ${_formatBytes(freed)}'),
      backgroundColor: AppTheme.accent,
    ));
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('Duplicates'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
      ),
      body: groups == null
          ? _buildScanning()
          : groups.isEmpty
              ? _buildEmpty()
              : _buildGroups(groups),
      bottomNavigationBar: groups == null || groups.isEmpty
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton.icon(
                key: const Key('duplicates_delete'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.warning,
                  foregroundColor: AppTheme.text,
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed:
                    _selected.isEmpty || _deleting ? null : _deleteSelected,
                icon: _deleting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline),
                label: Text(_selected.isEmpty
                    ? 'Select copies to delete'
                    : 'Delete ${_selected.length} '
                        '${_selected.length == 1 ? 'copy' : 'copies'} '
                        '(${_formatBytes(_selectedBytes)})'),
              ),
            ),
    );
  }

  Widget _buildScanning() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AppTheme.accent),
          const SizedBox(height: 16),
          Text(
            _total == 0
                ? 'Looking for duplicates...'
                : 'Checking $_done of $_total files...',
            style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline,
              size: 56, color: AppTheme.accent),
          const SizedBox(height: 12),
          const Text('No duplicates found',
              style: TextStyle(color: AppTheme.text, fontSize: 18)),
          const SizedBox(height: 4),
          Text('Every file in your vault is stored once.',
              style: TextStyle(color: AppTheme.text.withOpacity(0.6))),
        ],
      ),
    );
  }

  Widget _buildGroups(List<DuplicateGroup> groups) {
    final copies = groups.fold(0, (s, g) => s + g.items.length - 1);
    final wasted = groups.fold(0, (s, g) => s + g.wastedBytes);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text(
          '$copies extra ${copies == 1 ? 'copy' : 'copies'} using '
          '${_formatBytes(wasted)}. The oldest copy of each file is kept; '
          'tap a file to change what gets deleted.',
          style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
        ),
        for (final group in groups) ...[
          const SizedBox(height: 20),
          Text(
            '${group.items.first.displayName}: ${group.items.length} copies, '
            '${_formatBytes(group.items.first.sizeBytes)} each',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: AppTheme.text, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in group.items) _buildTile(group, item),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildTile(DuplicateGroup group, VaultItem item) {
    final selected = _selected.contains(item.id);
    final thumb = context.read<VaultService>().getThumbnailPathForItem(item);
    final date = item.dateAdded;
    return GestureDetector(
      onTap: _deleting ? null : () => _toggle(group, item),
      child: SizedBox(
        width: 100,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                  child: Container(
                    width: 100,
                    height: 100,
                    color: AppTheme.surfaceVariant,
                    foregroundDecoration: selected
                        ? BoxDecoration(
                            color: AppTheme.warning.withOpacity(0.35),
                            border:
                                Border.all(color: AppTheme.warning, width: 3),
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusSmall),
                          )
                        : null,
                    child: thumb == null
                        ? Icon(_iconFor(item.type),
                            color: AppTheme.text.withOpacity(0.5))
                        : Image.file(
                            File(thumb),
                            fit: BoxFit.cover,
                            cacheWidth: 200,
                            errorBuilder: (_, __, ___) => Icon(
                                _iconFor(item.type),
                                color: AppTheme.text.withOpacity(0.5)),
                          ),
                  ),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: Icon(
                    selected ? Icons.delete : Icons.check_circle,
                    size: 22,
                    color: selected ? AppTheme.text : AppTheme.accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              selected ? 'Delete' : 'Keep',
              style: TextStyle(
                color: selected ? AppTheme.warning : AppTheme.accent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${date.day}/${date.month}/${date.year}',
              style: TextStyle(
                  color: AppTheme.text.withOpacity(0.6), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(VaultItemType type) => switch (type) {
        VaultItemType.photo => Icons.image,
        VaultItemType.video => Icons.videocam,
        VaultItemType.audio => Icons.audiotrack,
        VaultItemType.document => Icons.description,
        _ => Icons.insert_drive_file,
      };

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

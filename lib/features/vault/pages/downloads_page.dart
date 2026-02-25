import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/services/download_manager_service.dart';
import '../../../core/services/vault_service.dart';
import '../../../core/models/vault_item.dart';
import 'vault_item_detail_page.dart';
import 'vault_home_page.dart';
import 'browser_page.dart';

/// Downloads page showing all download tasks
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          final navigator = Navigator.of(context);
          
          // Try to pop once first
          if (navigator.canPop()) {
            navigator.pop();
            
            // After popping, check if we're on the browser
            // Use a microtask to check after the pop completes
            Future.microtask(() {
              final currentRoute = ModalRoute.of(context);
              if (currentRoute?.settings.name != '/browser') {
                // Not on browser, navigate to it
                navigator.pushReplacement(
                  MaterialPageRoute(
                    builder: (context) => const BrowserPage(),
                    settings: const RouteSettings(name: '/browser'),
                  ),
                );
              }
            });
          } else {
            // Can't pop, navigate directly to browser
            navigator.pushReplacement(
              MaterialPageRoute(
                builder: (context) => const BrowserPage(),
                settings: const RouteSettings(name: '/browser'),
              ),
            );
          }
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.primary,
        appBar: AppBar(
          title: const Text('Downloads'),
          backgroundColor: AppTheme.surface,
          elevation: 0,
          actions: [
          Consumer<DownloadManagerService>(
            builder: (context, downloadManager, _) {
              if (downloadManager.tasks.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: 'Delete All',
                onPressed: () => _deleteAllDownloads(context, downloadManager),
              );
            },
          ),
        ],
      ),
      body: Consumer<DownloadManagerService>(
        builder: (context, downloadManager, _) {
          final allTasks = downloadManager.tasks;
          
          if (allTasks.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.download_outlined,
                    size: 64,
                    color: AppTheme.text.withOpacity(0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No downloads',
                    style: TextStyle(
                      color: AppTheme.text.withOpacity(0.7),
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            );
          }
          
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: allTasks.length,
            itemBuilder: (context, index) {
              final task = allTasks[index];
              return _buildDownloadItem(context, task, downloadManager);
            },
          );
        },
      ),
      ),
    );
  }
  
  Widget _buildDownloadItem(BuildContext context, DownloadTask task, DownloadManagerService downloadManager) {
    IconData statusIcon;
    Color statusColor;
    String statusText;
    
    switch (task.status) {
      case DownloadStatus.downloading:
        statusIcon = Icons.download;
        statusColor = AppTheme.accent;
        statusText = 'Downloading...';
        break;
      case DownloadStatus.pending:
        statusIcon = Icons.pending;
        statusColor = AppTheme.text.withOpacity(0.7);
        statusText = 'Pending';
        break;
      case DownloadStatus.paused:
        statusIcon = Icons.pause_circle;
        statusColor = AppTheme.text.withOpacity(0.7);
        statusText = 'Paused';
        break;
      case DownloadStatus.completed:
        statusIcon = Icons.check_circle;
        statusColor = Colors.green;
        statusText = 'Completed';
        break;
      case DownloadStatus.failed:
        statusIcon = Icons.error;
        statusColor = AppTheme.warning;
        statusText = 'Failed';
        break;
      case DownloadStatus.cancelled:
        statusIcon = Icons.cancel;
        statusColor = AppTheme.text.withOpacity(0.5);
        statusText = 'Cancelled';
        break;
    }
    
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: AppTheme.surfaceVariant,
      child: ListTile(
        leading: Icon(statusIcon, color: statusColor, size: 24),
        title: Text(
          task.filename,
          style: const TextStyle(color: AppTheme.text, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () {
          // If completed and has vault item, open it
          if (task.status == DownloadStatus.completed && task.vaultItemId != null) {
            _navigateToVaultItem(context, task);
          }
        },
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            if (task.status == DownloadStatus.downloading)
              LinearProgressIndicator(
                value: task.progress,
                backgroundColor: AppTheme.surface,
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 12,
                  ),
                ),
                if (task.status == DownloadStatus.downloading && task.totalBytes != null)
                  Text(
                    ' • ${_formatBytes(task.bytesDownloaded)} / ${_formatBytes(task.totalBytes!)}',
                    style: TextStyle(
                      color: AppTheme.text.withOpacity(0.7),
                      fontSize: 12,
                    ),
                  )
                else if (task.status == DownloadStatus.downloading)
                  Text(
                    ' • ${_formatBytes(task.bytesDownloaded)}',
                    style: TextStyle(
                      color: AppTheme.text.withOpacity(0.7),
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
            if (task.errorMessage != null)
              Text(
                task.errorMessage!,
                style: TextStyle(
                  color: AppTheme.warning,
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 20),
          onSelected: (value) async {
            switch (value) {
              case 'pause':
                await downloadManager.pauseDownload(task.id);
                break;
              case 'resume':
                await downloadManager.resumeDownload(task.id);
                break;
              case 'retry':
                await downloadManager.retryDownload(task.id);
                break;
              case 'cancel':
                await downloadManager.cancelDownload(task.id);
                break;
              case 'view_in_vault':
                _navigateToVaultItem(context, task);
                break;
              case 'delete':
                _deleteDownload(context, task, downloadManager);
                break;
            }
          },
          itemBuilder: (context) {
            final items = <PopupMenuEntry<String>>[];
            
            if (task.status == DownloadStatus.downloading) {
              items.add(const PopupMenuItem(
                value: 'pause',
                child: Row(
                  children: [
                    Icon(Icons.pause, size: 20),
                    SizedBox(width: 8),
                    Text('Pause'),
                  ],
                ),
              ));
            } else if (task.status == DownloadStatus.paused) {
              items.add(const PopupMenuItem(
                value: 'resume',
                child: Row(
                  children: [
                    Icon(Icons.play_arrow, size: 20),
                    SizedBox(width: 8),
                    Text('Resume'),
                  ],
                ),
              ));
            }
            
            if (task.status == DownloadStatus.failed) {
              items.add(const PopupMenuItem(
                value: 'retry',
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: 20),
                    SizedBox(width: 8),
                    Text('Retry'),
                  ],
                ),
              ));
            }
            
            if (task.status != DownloadStatus.completed) {
              items.add(const PopupMenuItem(
                value: 'cancel',
                child: Row(
                  children: [
                    Icon(Icons.cancel, size: 20),
                    SizedBox(width: 8),
                    Text('Cancel'),
                  ],
                ),
              ));
            }
            
            // Add "View in Vault" for completed downloads
            if (task.status == DownloadStatus.completed && task.vaultItemId != null) {
              items.add(const PopupMenuItem(
                value: 'view_in_vault',
                child: Row(
                  children: [
                    Icon(Icons.folder, size: 20),
                    SizedBox(width: 8),
                    Text('View in Vault'),
                  ],
                ),
              ));
            }
            
            // Add delete option for all downloads
            items.add(const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, size: 20, color: Colors.red),
                  SizedBox(width: 8),
                  Text('Delete', style: TextStyle(color: Colors.red)),
                ],
              ),
            ));
            
            return items;
          },
        ),
      ),
    );
  }
  
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  
  void _navigateToVaultItem(BuildContext context, DownloadTask task) {
    if (task.vaultItemId == null) return;
    
    try {
      final vaultService = Provider.of<VaultService>(context, listen: false);
      final vaultItem = vaultService.items.firstWhere(
        (item) => item.id == task.vaultItemId,
      );
      
      // Navigate to vault home first, then to item detail
      // Check if VaultHomePage is already in the stack
      final navigator = Navigator.of(context);
      bool vaultPageExists = false;
      
      navigator.popUntil((route) {
        if (route.settings.name == '/vault') {
          vaultPageExists = true;
          return true;
        }
        if (route.isFirst) {
          return true;
        }
        return false;
      });
      
      // If vault page doesn't exist, push it
      if (!vaultPageExists) {
        navigator.push(
          MaterialPageRoute(
            builder: (context) => const VaultHomePage(),
            settings: const RouteSettings(name: '/vault'),
          ),
        );
      }
      
      // Then navigate to item detail
      navigator.push(
        MaterialPageRoute(
          builder: (context) => VaultItemDetailPage(item: vaultItem),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Vault item not found: ${e.toString()}'),
          backgroundColor: AppTheme.warning,
        ),
      );
    }
  }
  
  Future<void> _deleteDownload(BuildContext context, DownloadTask task, DownloadManagerService downloadManager) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: const Text(
          'Delete Download',
          style: TextStyle(color: AppTheme.text),
        ),
        content: Text(
          'Are you sure you want to delete "${task.filename}"?',
          style: const TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.warning),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await downloadManager.removeDownload(task.id);
    }
  }
  
  Future<void> _deleteAllDownloads(BuildContext context, DownloadManagerService downloadManager) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: const Text(
          'Delete All Downloads',
          style: TextStyle(color: AppTheme.text),
        ),
        content: Text(
          'Are you sure you want to delete all ${downloadManager.tasks.length} download${downloadManager.tasks.length > 1 ? 's' : ''}?',
          style: const TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.warning),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      // Delete all downloads
      final taskIds = downloadManager.tasks.map((t) => t.id).toList();
      for (final taskId in taskIds) {
        await downloadManager.removeDownload(taskId);
      }
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted ${taskIds.length} download${taskIds.length > 1 ? 's' : ''}'),
            backgroundColor: AppTheme.accent,
          ),
        );
      }
    }
  }
}

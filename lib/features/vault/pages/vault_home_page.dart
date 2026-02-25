import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import '../../../core/services/permission_service.dart';
import 'package:path_provider/path_provider.dart';
import '../../../app/theme.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/vault_service.dart';
import '../../../core/services/background_import_service.dart';
import '../../../core/services/tutorial_service.dart';
import '../../../core/services/subscription_service.dart';
import '../../../core/models/subscription_tier.dart';
import '../../../core/models/vault_item.dart';
import '../../../core/models/app_state.dart';
import '../../../core/models/album.dart';
import '../../../core/models/vault_folder.dart';
import '../../../features/subscription/pages/paywall_page.dart';
import 'vault_item_detail_page.dart';
import 'browser_page.dart';
import 'wifi_transfer_page.dart';
import 'vault_settings_page.dart';
import '../widgets/tutorial_overlay.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

/// Premium vault home page with grid layout and media-first presentation
class VaultHomePage extends StatefulWidget {
  final String? vaultId; // If null, uses primary vault
  
  const VaultHomePage({super.key, this.vaultId});
  
  @override
  State<VaultHomePage> createState() => _VaultHomePageState();
}

class _VaultHomePageState extends State<VaultHomePage> {
  final ImagePicker _imagePicker = ImagePicker();
  final PermissionService _permissionService = PermissionService();
  BackgroundImportService? _backgroundImportService;
  StreamSubscription<ImportProgress>? _importProgressSubscription;
  String? _currentFolderId; // null = root, otherwise folder ID
  String _selectedAlbumId = 'smart_recent'; // Default to Recent
  final Set<String> _selectedTagFilterIds = <String>{}; // Color-tag filters (ANDed with album/folder)
  bool _isGridView = true;
  bool _isSelectionMode = false;
  Set<String> _selectedItemIds = {};
  bool _isImporting = false;
  int _importProgress = 0;
  int _importTotal = 0;
  String? _importStatus;
  Timer? _importBannerDismissTimer;
  bool _foldersMinimized = false;
  bool _filesMinimized = false;
  
  // Avoid repeatedly queuing thumbnail generation from the UI.
  final Set<String> _requestedMissingThumbnails = <String>{};

  // Color-coded tags (stored permanently per item in VaultItem.metadata['tags'] as List<String>)
  static const Map<String, Color> _tagColorById = <String, Color>{
    'red': Color(0xFFE53935),
    'orange': Color(0xFFFB8C00),
    'yellow': Color(0xFFFDD835),
    'green': Color(0xFF43A047),
    'blue': Color(0xFF1E88E5),
    'purple': Color(0xFF8E24AA),
    'pink': Color(0xFFD81B60),
    'gray': Color(0xFF78909C),
  };
  
  // Tutorial keys
  final GlobalKey _fabKey = GlobalKey();
  final GlobalKey _albumSelectorKey = GlobalKey();
  final GlobalKey _gridViewKey = GlobalKey();
  final GlobalKey _downloadAllKey = GlobalKey();
  final GlobalKey _browserKey = GlobalKey();
  final GlobalKey _wifiKey = GlobalKey();
  final GlobalKey _viewToggleKey = GlobalKey();
  final GlobalKey _settingsKey = GlobalKey();
  final GlobalKey _lockKey = GlobalKey();
  
  bool _showTutorial = false;
  int _tutorialStep = 0;
  
  @override
  void initState() {
    super.initState();
    _loadViewSettings();
    _initializeVault();
    _checkTutorialStatus();
    _checkTrialExpiration();
  }
  
  Future<void> _loadViewSettings() async {
    final prefs = await SharedPreferences.getInstance();
      setState(() {
      _foldersMinimized = prefs.getBool('vault_folders_minimized') ?? false;
      _filesMinimized = prefs.getBool('vault_files_minimized') ?? false;
    });
  }
  
  Future<void> _saveFoldersMinimized(bool minimized) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('vault_folders_minimized', minimized);
  }
  
  Future<void> _saveFilesMinimized(bool minimized) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('vault_files_minimized', minimized);
  }
  
  @override
  void dispose() {
    _importBannerDismissTimer?.cancel();
    _importBannerDismissTimer = null;
    _importProgressSubscription?.cancel();
    _backgroundImportService?.dispose();
    super.dispose();
  }
  
  /// Initialize background import service
  void _initBackgroundImportService() {
    if (_backgroundImportService == null) {
      final vaultService = Provider.of<VaultService>(context, listen: false);
      _backgroundImportService = BackgroundImportService(vaultService);
      
      // Resume any pending imports from background
      _backgroundImportService!.resume();
      
      // Listen to progress updates
      _importProgressSubscription = _backgroundImportService!.progressStream.listen((progress) {
        if (mounted) {
          if (!progress.isComplete) {
            // A new import update arrived; don't allow a pending completion timer
            // to clear the banner mid-import.
            _importBannerDismissTimer?.cancel();
            _importBannerDismissTimer = null;
          }

          // Defer setState to avoid calling during build phase
          Future.microtask(() {
            if (mounted) {
              setState(() {
                _importProgress = progress.current;
                _importTotal = progress.total;
                _importStatus = progress.status;
                _isImporting = !progress.isComplete;
              });
            }
          });
          
          // Show completion message
          if (progress.isComplete) {
            // Auto-dismiss the bottom banner after completion so it doesn't stick.
            _importBannerDismissTimer?.cancel();
            _importBannerDismissTimer = Timer(const Duration(seconds: 3), () {
              if (!mounted) return;
              setState(() {
                _importStatus = null;
                _importProgress = 0;
                _importTotal = 0;
                _isImporting = false;
              });
            });

            final hasFailures = progress.failCount != null && progress.failCount! > 0;
            final message = hasFailures
                ? 'Imported ${progress.successCount} file(s), ${progress.failCount} failed'
                : 'Imported ${progress.successCount} file(s)';
            final hint = hasFailures
                ? 'Files in iCloud: open them in Photos or Files first, then try again.'
                : null;
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message),
                    if (hint != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        hint,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.9),
                        ),
                      ),
                    ],
                  ],
                ),
                backgroundColor: hasFailures ? AppTheme.warning : AppTheme.accent,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }
      });
    }
  }

  // NOTE: iOS multi-select can yield items without filesystem paths.
  // We handle those by resolving via PhotoManager asset IDs (see _importVideos).

  Future<void> _importVideosIOS() async {
    // Use Photos-native multi-select to avoid iOS document picker hangs.
    List<AssetEntity>? assets;
    try {
      assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: const AssetPickerConfig(
          requestType: RequestType.video,
          maxAssets: 200,
        ),
      );
    } catch (e) {
      debugPrint('[VaultHomePage] iOS video picker error: $e');
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importStatus = null;
          _importProgress = 0;
          _importTotal = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open video picker: $e'),
            backgroundColor: AppTheme.warning,
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    if (assets == null || assets.isEmpty) {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importStatus = null;
          _importProgress = 0;
          _importTotal = 0;
        });
      }
      return;
    }

    final pickedAssets = assets; // non-null after guard above

    if (mounted) {
      setState(() {
        _isImporting = true;
        _importProgress = 0;
        _importTotal = pickedAssets.length;
        _importStatus = 'Preparing ${pickedAssets.length} video(s)...';
      });
    }

    // Resolve assets to file paths (can be async even when not in iCloud).
    final resolved = <Map<String, Object>>[];
    int skipped = 0;
    for (int i = 0; i < pickedAssets.length; i++) {
      if (mounted) {
        setState(() {
          _importProgress = i; // "preparing" progress
          _importStatus = 'Preparing video ${i + 1} / ${pickedAssets.length}...';
        });
      }
      try {
        // Guard against rare hangs while exporting a video asset.
        final file = await pickedAssets[i]
            .originFile
            .timeout(const Duration(seconds: 20), onTimeout: () => null);
        if (file != null) {
          final tsMs = pickedAssets[i].createDateTime.millisecondsSinceEpoch;
          resolved.add(<String, Object>{
            'path': file.path,
            'timestampMs': tsMs,
          });
        } else {
          skipped++;
        }
      } catch (e) {
        debugPrint('[VaultHomePage] Error resolving video asset file: $e');
        skipped++;
      }
      await Future.delayed(const Duration(milliseconds: 1));
    }

    if (resolved.isEmpty) {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importStatus = null;
          _importProgress = 0;
          _importTotal = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not access the selected videos for import. Please try again.'),
            backgroundColor: AppTheme.warning,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    // Initialize background import service
    _initBackgroundImportService();

    // Check subscription limits
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
    final hasPremium = subscriptionService.currentTier.isUnlimited || subscriptionService.isInTrial;

    if (!hasPremium) {
      final currentItemCount = vaultService.items.length;
      final maxItems = subscriptionService.currentTier.maxItems;
      if (currentItemCount + resolved.length > maxItems) {
        if (mounted) {
          setState(() {
            _isImporting = false;
            _importStatus = null;
          });
          _showPaywall();
        }
        return;
      }
    }

    final importTasks = resolved
        .map((entry) => ImportTask(
              filePath: entry['path'] as String,
              filename: (entry['path'] as String).split('/').last,
              mimeType: 'video/mp4',
              source: VaultItemSource.import,
              deleteOriginal: false, // Never delete from Photos library
              folderId: _currentFolderId,
              metadata: <String, dynamic>{
                'timestampMs': entry['timestampMs'] as int,
              },
            ))
        .toList();

    if (mounted) {
      setState(() {
        _importProgress = 0;
        _importTotal = importTasks.length;
        _importStatus = skipped > 0
            ? 'Queuing ${importTasks.length} video(s) (skipped $skipped)...'
            : 'Queuing ${importTasks.length} video(s) for import...';
      });
    }

    await _backgroundImportService!.queueImports(importTasks);

    if (mounted) {
      setState(() {
        _isImporting = true;
        _importProgress = 0;
        _importTotal = importTasks.length;
        _importStatus = 'Queued ${importTasks.length} video(s) for import...';
      });
    }
  }
  
  Future<void> _initializeVault() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final authService = Provider.of<AuthService>(context, listen: false);
      final vaultService = Provider.of<VaultService>(context, listen: false);
      
      // Get master key
      final masterKey = authService.masterKey;
      
      // Get vault ID (null = primary vault)
      final vaultId = widget.vaultId ?? authService.currentVaultId;
      
      // Check if we need to reinitialize (switching vaults)
      final needsReinit = !vaultService.isInitialized ||
          vaultService.currentVaultId != vaultId;
      
      if (needsReinit) {
        // Initialize or reinitialize vault
        await vaultService.initialize(
          masterKey: masterKey,
          vaultId: vaultId,
          forceReinit: vaultService.isInitialized,
        );
        if (mounted) {
          setState(() {}); // Refresh UI after initialization
        }
      }
      
      // Initialize background import service after vault is ready
      _initBackgroundImportService();
    });
  }
  
  Future<void> _checkTutorialStatus() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final tutorialService = Provider.of<TutorialService>(context, listen: false);
      if (!tutorialService.vaultTutorialCompleted) {
        // Wait a bit for UI to render
        await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      setState(() {
            _showTutorial = true;
            _tutorialStep = 0;
          });
        }
      }
    });
  }
  
  void _checkTrialExpiration() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
      
      // Check if trial is expiring soon (1-2 days remaining)
      if (subscriptionService.isInTrial) {
        final daysRemaining = subscriptionService.trialDaysRemaining ?? 0;
        
        // Show reminder dialog if trial expires in 1-2 days
        if (daysRemaining <= 2 && daysRemaining > 0) {
          await Future.delayed(const Duration(seconds: 2)); // Wait for UI to load
          if (mounted) {
            _showTrialExpirationReminder(context, subscriptionService, daysRemaining);
          }
        }
      }
    });
  }
  
  void _showTrialExpirationReminder(
    BuildContext context,
    SubscriptionService subscriptionService,
    int daysRemaining,
  ) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Row(
          children: [
            Icon(
              daysRemaining == 1 ? Icons.warning_amber_rounded : Icons.timer_outlined,
              color: AppTheme.warning,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                daysRemaining == 1 ? 'Trial Ends Tomorrow!' : 'Trial Ending Soon',
                style: const TextStyle(
                  color: AppTheme.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              daysRemaining == 1
                  ? 'Your free trial expires in 1 day. Subscribe now to keep unlimited access to all premium features.'
                  : 'Your free trial expires in $daysRemaining days. Subscribe now to continue enjoying unlimited storage, browser access, and all premium features.',
              style: const TextStyle(
                color: AppTheme.text,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.accent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.star_rounded,
                    color: AppTheme.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Premium features include:\n• Unlimited storage\n• Browser with media downloads\n• WiFi file transfer\n• Media converter',
                      style: TextStyle(
                        color: AppTheme.text.withOpacity(0.9),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Maybe Later',
              style: TextStyle(
                color: AppTheme.text.withOpacity(0.6),
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const PaywallPage(showCloseButton: true),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent,
              foregroundColor: AppTheme.primary,
            ),
            child: const Text(
              'Subscribe Now',
              style: TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  List<TutorialStep> _getTutorialSteps() {
    return [
      TutorialStep(
        id: 'welcome',
        title: 'Welcome to Your Vault!',
        description: 'This is your secure vault where all your files are encrypted and protected. Let\'s take a quick tour to learn how to use all the features.',
        alignment: Alignment.center,
        showSkipButton: true,
        showPreviousButton: false,
      ),
      TutorialStep(
        id: 'add_files',
        title: 'Add Files to Your Vault',
        description: 'Tap the + button to add files. You can:\n• Take photos or record videos\n• Import from your gallery\n• Import any file type\n\nAll files are automatically encrypted!',
        targetKey: _fabKey,
        alignment: Alignment.bottomCenter,
      ),
      TutorialStep(
        id: 'albums',
        title: 'Organize with Albums',
        description: 'Use albums to filter and organize your files:\n• Recent: All items sorted by date\n• Photos: All your photos\n• Videos: All your videos\n• Audio: All audio files\n• Documents: PDFs and other files\n\nTap an album to filter your vault!',
        targetKey: _albumSelectorKey,
        alignment: Alignment.topCenter,
      ),
      TutorialStep(
        id: 'view_items',
        title: 'View Your Files',
        description: 'Your files are displayed here:\n• Grid view: See thumbnails in a grid\n• List view: See files in a list\n• Tap any file to open and view it\n• Long-press to select multiple files',
        targetKey: _gridViewKey,
        alignment: Alignment.center,
      ),
      TutorialStep(
        id: 'download',
        title: 'Download Files',
        description: 'Download files back to your device:\n• Download All: Export everything\n• Select files and download selected\n• Download entire albums\n• Files are saved to your photo library or downloads folder',
        targetKey: _downloadAllKey,
        alignment: Alignment.topRight,
      ),
      TutorialStep(
        id: 'browser',
        title: 'Built-in Private Browser',
        description: 'Access the private browser:\n• Download videos and audio from websites\n• Bookmark your favorite sites\n• Block spammy redirects\n• Browse privately with no history saved\n\nPerfect for downloading media!',
        targetKey: _browserKey,
        alignment: Alignment.topRight,
      ),
      TutorialStep(
        id: 'wifi_transfer',
        title: 'WiFi File Transfer',
        description: 'Transfer files wirelessly:\n• Share files between your computer and phone\n• Access via web browser\n• Scan QR code for quick access\n• Perfect for large files\n\nBoth devices must be on the same WiFi network.',
        targetKey: _wifiKey,
        alignment: Alignment.topRight,
      ),
      TutorialStep(
        id: 'view_toggle',
        title: 'Switch Views',
        description: 'Toggle between grid and list views:\n• Grid view: Visual thumbnails\n• List view: Detailed file information\n• Choose what works best for you!',
        targetKey: _viewToggleKey,
        alignment: Alignment.topRight,
      ),
      TutorialStep(
        id: 'folders',
        title: 'Organize with Folders',
        description: 'Create folders to organize your files:\n• Long-press files to select them\n• Tap "Move to Folder" to organize\n• Create new folders as needed\n• Navigate folders using breadcrumbs\n\nKeep your vault organized!',
        targetKey: _gridViewKey,
        alignment: Alignment.center,
      ),
      TutorialStep(
        id: 'media_playback',
        title: 'Play Media Files',
        description: 'View and play your media:\n• Tap any photo to view full screen\n• Tap videos to play them\n• Tap audio files to play\n• Swipe between files\n• Use media controls for playback\n\nAll media plays directly in your vault!',
        targetKey: _gridViewKey,
        alignment: Alignment.center,
      ),
      TutorialStep(
        id: 'media_converter',
        title: 'Media Converter',
        description: 'Convert videos to audio:\n• Open any video file\n• Tap the convert button\n• Extract audio from videos\n• Save as MP3 or other formats\n\nPerfect for creating audio files!',
        targetKey: _gridViewKey,
        alignment: Alignment.center,
      ),
      TutorialStep(
        id: 'downloads_page',
        title: 'Downloads Page',
        description: 'Track your downloads:\n• View all active downloads\n• See download progress\n• Pause or resume downloads\n• Access completed downloads\n• Manage download queue\n\nAll browser downloads appear here!',
        targetKey: _browserKey,
        alignment: Alignment.topRight,
      ),
      TutorialStep(
        id: 'settings',
        title: 'Vault Settings',
        description: 'Manage your vault settings:\n• Change your PIN\n• Update trigger code\n• Manage storage location\n• Configure panic switch\n• Create multiple vaults (Primary vault only)\n• Manage subscription\n\nAccess all settings from here!',
        targetKey: _settingsKey,
        alignment: Alignment.topRight,
      ),
      TutorialStep(
        id: 'lock_vault',
        title: 'Lock Your Vault',
        description: 'Lock your vault for security:\n• Tap the lock icon to lock immediately\n• Vault locks automatically when app goes to background\n• Requires PIN to unlock again\n• Returns to unlock screen\n\nKeep your vault secure!',
        targetKey: _lockKey,
        alignment: Alignment.topRight,
      ),
      TutorialStep(
        id: 'multiple_vaults',
        title: 'Multiple Vaults (Premium)',
        description: 'Create multiple vaults:\n• Primary vault manages all vaults\n• Create secondary vaults with different trigger codes\n• Each vault has its own PIN\n• Recover codes from primary vault\n• Access vaults via their unique trigger codes\n\nPerfect for organizing different types of content!',
        targetKey: _settingsKey,
        alignment: Alignment.topRight,
      ),
      TutorialStep(
        id: 'complete',
        title: 'You\'re All Set!',
        description: 'You now know how to:\n✓ Add files to your vault\n✓ Organize with albums and folders\n✓ View and play media files\n✓ Download files and manage downloads\n✓ Use the browser and WiFi transfer\n✓ Configure settings and security\n✓ Create multiple vaults (Premium)\n✓ Lock your vault for security\n\nYour vault is ready to protect your privacy!',
        alignment: Alignment.center,
        showNextButton: false,
      ),
    ];
  }
  
  void _onTutorialStepChanged(int step) {
    // Defer setState to avoid calling during build phase
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _tutorialStep = step;
        });
      }
    });
  }
  
  void _onTutorialComplete() {
    final tutorialService = Provider.of<TutorialService>(context, listen: false);
    tutorialService.markTutorialCompleted();
    // Defer setState to avoid calling during build phase
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _showTutorial = false;
          _tutorialStep = 0;
        });
      }
    });
  }
  
  void _onTutorialSkip() {
    final tutorialService = Provider.of<TutorialService>(context, listen: false);
    tutorialService.markTutorialCompleted();
    setState(() {
      _showTutorial = false;
      _tutorialStep = 0;
    });
  }
  
  List<VaultItem> _getDisplayItems() {
    final vaultService = Provider.of<VaultService>(context, listen: false);
    
    List<VaultItem> baseItems;
    
    // If in a folder, get folder items
    if (_currentFolderId != null) {
      baseItems = vaultService.getFolderItems(_currentFolderId!);
    } else {
      // At root level, show only root items (items not in any folder)
      // Files moved into folders should not appear in the Files category
      baseItems = vaultService.getRootItems();
    }
    
    // Apply album filter to the base items
    if (_selectedAlbumId.startsWith('smart_')) {
      final filtered = _applySmartAlbumFilter(baseItems, _selectedAlbumId);
      return _applyTagFilter(filtered);
    } else if (_selectedAlbumId != 'smart_recent') {
      // For user-created albums, filter by album item IDs
      final album = vaultService.albums.firstWhere(
        (a) => a.id == _selectedAlbumId,
        orElse: () => vaultService.albums.first,
      );
      final result = baseItems.where((item) => album.itemIds.contains(item.id)).toList();
      final tagFiltered = _applyTagFilter(result);
      tagFiltered.sort((a, b) => _chronologicalTimestampMs(a).compareTo(_chronologicalTimestampMs(b)));
      return tagFiltered;
    }
    
    // Default: show all items sorted by date (Recent)
    final result = List<VaultItem>.from(baseItems);
    final tagFiltered = _applyTagFilter(result);
    tagFiltered.sort((a, b) => _chronologicalTimestampMs(a).compareTo(_chronologicalTimestampMs(b)));
    return tagFiltered;
  }

  int _chronologicalTimestampMs(VaultItem item) {
    // Prefer metadata timestamp when available (capture/import time), fall back to dateAdded.
    final v = item.metadata?['timestampMs'];
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is String) {
      final parsed = int.tryParse(v);
      if (parsed != null) return parsed;
    }
    return item.dateAdded.millisecondsSinceEpoch;
  }

  List<String> _getItemTagIds(VaultItem item) {
    final raw = item.metadata?['tags'];
    if (raw is List) {
      return raw.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }
    if (raw is String) {
      final t = raw.trim();
      return t.isEmpty ? const [] : <String>[t];
    }
    return const [];
  }

  List<VaultItem> _applyTagFilter(List<VaultItem> items) {
    if (_selectedTagFilterIds.isEmpty) return items;
    return items.where((item) {
      final tags = _getItemTagIds(item);
      for (final t in tags) {
        if (_selectedTagFilterIds.contains(t)) return true;
      }
      return false;
    }).toList();
  }
  
  List<VaultItem> _applySmartAlbumFilter(List<VaultItem> items, String albumId) {
    switch (albumId) {
      case 'smart_photos':
        final result = items.where((i) => i.type == VaultItemType.photo).toList();
        result.sort((a, b) => _chronologicalTimestampMs(a).compareTo(_chronologicalTimestampMs(b)));
        return result;
      case 'smart_videos':
        final result = items.where((i) => i.type == VaultItemType.video).toList();
        result.sort((a, b) => _chronologicalTimestampMs(a).compareTo(_chronologicalTimestampMs(b)));
        return result;
      case 'smart_audio':
        final result = items.where((i) => i.type == VaultItemType.audio).toList();
        result.sort((a, b) => _chronologicalTimestampMs(a).compareTo(_chronologicalTimestampMs(b)));
        return result;
      case 'smart_documents':
        final result = items.where((i) => i.type == VaultItemType.document || i.type == VaultItemType.archive).toList();
        result.sort((a, b) => _chronologicalTimestampMs(a).compareTo(_chronologicalTimestampMs(b)));
        return result;
      case 'smart_downloads':
        final result = items.where((i) => i.source == VaultItemSource.browser).toList();
        result.sort((a, b) => _chronologicalTimestampMs(a).compareTo(_chronologicalTimestampMs(b)));
        return result;
      case 'smart_recent':
      default:
        final result = List<VaultItem>.from(items);
        result.sort((a, b) => _chronologicalTimestampMs(a).compareTo(_chronologicalTimestampMs(b)));
        return result;
    }
  }
  
  List<VaultFolder> _getDisplayFolders() {
    final vaultService = Provider.of<VaultService>(context, listen: false);
    return vaultService.folders.where((f) => f.parentFolderId == _currentFolderId).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }
  
  void _toggleSelectionMode() {
    // Defer setState to avoid calling during build phase
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _isSelectionMode = !_isSelectionMode;
          if (!_isSelectionMode) {
            _selectedItemIds.clear();
          }
        });
      }
    });
  }
  
  void _toggleItemSelection(String itemId) {
    // Defer setState to avoid calling during build phase
    Future.microtask(() {
      if (mounted) {
        setState(() {
          if (_selectedItemIds.contains(itemId)) {
            _selectedItemIds.remove(itemId);
          } else {
            _selectedItemIds.add(itemId);
          }
        });
      }
    });
  }

  void _selectAll() {
    setState(() {
      final items = _getDisplayItems();
      if (_selectedItemIds.length == items.length) {
        // Deselect all if all are selected
        _selectedItemIds.clear();
      } else {
        // Select all
        _selectedItemIds = items.map((item) => item.id).toSet();
      }
    });
  }
  
  Future<void> _lockVault() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    await authService.lockVault();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }
  
  void _navigateToBrowser(BuildContext context) {
    final navigator = Navigator.of(context);
    bool browserPageExists = false;
    
    // Check if BrowserPage is already in the navigation stack
    navigator.popUntil((route) {
      if (route.settings.name == '/browser') {
        browserPageExists = true;
        return true;
      }
      if (route.isFirst) {
        return true;
      }
      return false;
    });
    
    // If BrowserPage doesn't exist, push it
    if (!browserPageExists) {
      navigator.push(
          MaterialPageRoute(
          builder: (context) => const BrowserPage(),
          settings: const RouteSettings(name: '/browser'),
        ),
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final isImportBannerVisible = _isImporting || _importStatus != null;
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: Text(_isSelectionMode 
            ? '${_selectedItemIds.length} selected'
            : 'Vault'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _toggleSelectionMode,
                tooltip: 'Cancel Selection',
              )
            : null,
        actions: [
          if (_isSelectionMode) ...[
            IconButton(
              icon: const Icon(Icons.select_all),
              onPressed: _selectAll,
              tooltip: 'Select All',
            ),
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: _selectedItemIds.isEmpty ? null : _downloadSelected,
              tooltip: 'Download Selected',
            ),
            IconButton(
              icon: const Icon(Icons.folder_outlined),
              onPressed: _selectedItemIds.isEmpty ? null : _moveToFolder,
              tooltip: 'Move to Folder',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _selectedItemIds.isEmpty ? null : _deleteSelected,
              tooltip: 'Delete Selected',
            ),
          ],
          if (!_isSelectionMode)
            Selector<SubscriptionService, bool>(
              selector: (_, service) => service.currentTier.isUnlimited || service.isInTrial,
              builder: (context, hasPremium, _) {
                return IconButton(
                  key: _downloadAllKey,
                  icon: Icon(
                    Icons.download_outlined,
                    color: hasPremium ? null : AppTheme.text.withOpacity(0.4),
                  ),
                  onPressed: hasPremium ? _downloadAll : _showPaywall,
                  tooltip: hasPremium ? 'Download All' : 'Download All (Premium)',
                );
              },
            ),
          IconButton(
            key: _viewToggleKey,
            icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
            onPressed: () {
    setState(() {
                _isGridView = !_isGridView;
              });
            },
            tooltip: _isGridView ? 'List View' : 'Grid View',
          ),
          Selector<SubscriptionService, bool>(
            selector: (_, service) => service.currentTier.isUnlimited || service.isInTrial,
            builder: (context, hasPremium, _) {
              return IconButton(
                key: _browserKey,
                icon: Icon(
                  Icons.language,
                  color: hasPremium ? null : AppTheme.text.withOpacity(0.4),
                ),
                onPressed: hasPremium
                    ? () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (context) => const BrowserPage()),
                        );
                      }
                    : _showPaywall,
                tooltip: hasPremium ? 'Browser' : 'Browser (Premium)',
              );
            },
          ),
          Selector<SubscriptionService, bool>(
            selector: (_, service) => service.currentTier.isUnlimited || service.isInTrial,
            builder: (context, hasPremium, _) {
              return IconButton(
                key: _wifiKey,
                icon: Icon(
                  Icons.wifi,
                  color: hasPremium ? null : AppTheme.text.withOpacity(0.4),
                ),
                onPressed: hasPremium
                    ? () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (context) => const WiFiTransferPage()),
                        );
                      }
                    : _showPaywall,
                tooltip: hasPremium ? 'WiFi Transfer' : 'WiFi Transfer (Premium)',
              );
            },
          ),
          IconButton(
            key: _settingsKey,
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const VaultSettingsPage()),
              );
            },
            tooltip: 'Settings',
          ),
          IconButton(
            key: _lockKey,
            icon: const Icon(Icons.lock_outline),
            onPressed: _lockVault,
            tooltip: 'Lock Vault',
          ),
        ],
      ),
      body: Consumer<VaultService>(
        builder: (context, vaultService, _) {
          if (!vaultService.isInitialized) {
            return const Center(
              child: CircularProgressIndicator(color: AppTheme.accent),
            );
          }
          
          final folders = _getDisplayFolders();
          final items = _getDisplayItems();
          
          return Stack(
            children: [
              Column(
                children: [
                  // Trial countdown banner
                  Selector<SubscriptionService, bool>(
                    selector: (_, service) => service.isInTrial,
                    builder: (context, isInTrial, child) {
                      if (isInTrial) {
                        final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
                        return _buildTrialBanner(context, subscriptionService);
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                  // Breadcrumb navigation
                  if (_currentFolderId != null)
                    _buildBreadcrumb(vaultService),
                  Container(
                    key: _albumSelectorKey,
                    child: _buildAlbumSelector(vaultService),
                  ),
                  _buildTagFilterBar(),
                  Expanded(
                    child: _currentFolderId == null
                        ? (folders.isNotEmpty || items.isNotEmpty
                            ? _buildRootView(folders, items, vaultService)
                            : _buildEmptyStateWithFolderOption(vaultService))
                        : (items.isEmpty
                            ? _buildEmptyState(vaultService)
                            : (_isGridView
                                ? _buildGridView(items)
                                : _buildListView(items))),
                  ),
                ],
              ),
              // Import progress indicator
              if (_isImporting || _importStatus != null)
                _buildImportProgressIndicator(),
              // Tutorial overlay
              if (_showTutorial)
                TutorialOverlay(
                  steps: _getTutorialSteps(),
                  currentStep: _tutorialStep,
                  onStepChanged: _onTutorialStepChanged,
                  onComplete: _onTutorialComplete,
                  onSkip: _onTutorialSkip,
                ),
            ],
          );
        },
      ),
      floatingActionButton: Padding(
        // Keep the + button from covering the bottom import banner.
        padding: EdgeInsets.only(bottom: isImportBannerVisible ? 96.0 : 0.0),
        child: Stack(
          children: [
            Container(
              key: _fabKey,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppTheme.accent,
                    AppTheme.accentVariant,
                  ],
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.accent.withOpacity(0.5),
                    blurRadius: 20,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: FloatingActionButton(
                onPressed: _showAddMenu,
                backgroundColor: Colors.transparent,
                elevation: 0,
                child: const Icon(Icons.add, color: AppTheme.primary, size: 28),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildTrialBanner(BuildContext context, SubscriptionService subscriptionService) {
    final daysRemaining = subscriptionService.trialDaysRemaining ?? 0;
    final isExpiringSoon = daysRemaining <= 2;
    
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isExpiringSoon
              ? [
                  AppTheme.warning.withOpacity(0.2),
                  AppTheme.warning.withOpacity(0.1),
                ]
              : [
                  AppTheme.accent.withOpacity(0.2),
                  AppTheme.accent.withOpacity(0.1),
                ],
        ),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(
          color: isExpiringSoon
              ? AppTheme.warning.withOpacity(0.3)
              : AppTheme.accent.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isExpiringSoon ? Icons.warning_amber_rounded : Icons.star_rounded,
            color: isExpiringSoon ? AppTheme.warning : AppTheme.accent,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  daysRemaining == 1
                      ? 'Trial ends tomorrow!'
                      : isExpiringSoon
                          ? 'Trial ending soon'
                          : 'Free Trial Active',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isExpiringSoon ? AppTheme.warning : AppTheme.accent,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  daysRemaining == 1
                      ? 'Your trial expires in 1 day. Subscribe to keep unlimited access.'
                      : '$daysRemaining days remaining in your free trial',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.text.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            color: AppTheme.text.withOpacity(0.6),
            onPressed: () {
              // Banner can be dismissed, but will show again on next app launch
              // For now, we'll keep it visible to remind users
            },
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
  
  Widget _buildEmptyState(VaultService vaultService) {
    // Check if a filter is active (not the default "Recent")
    final isFilterActive = _selectedAlbumId != 'smart_recent' || _selectedTagFilterIds.isNotEmpty;
    final selectedAlbum = vaultService.albums.firstWhere(
      (album) => album.id == _selectedAlbumId,
      orElse: () => vaultService.albums.first,
    );
    final totalItems = vaultService.items.length;
    
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Make the entire empty state tappable (only when vault is truly empty, not filtered)
            GestureDetector(
              onTap: (!isFilterActive || totalItems == 0) ? _showAddMenu : null,
              behavior: HitTestBehavior.opaque,
              child: InkWell(
                onTap: (!isFilterActive || totalItems == 0) ? _showAddMenu : null,
                splashColor: AppTheme.accent.withOpacity(0.1),
                highlightColor: AppTheme.accent.withOpacity(0.05),
                borderRadius: BorderRadius.circular(AppTheme.radius),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(minHeight: 300),
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Vibrant icon with gradient background
                      Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppTheme.accent.withOpacity(0.2),
                          AppTheme.accent.withOpacity(0.1),
                        ],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.accent.withOpacity(0.2),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: Icon(
                      isFilterActive ? Icons.filter_alt_outlined : Icons.lock_outline,
                      size: 60,
                      color: AppTheme.accent,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    isFilterActive
                        ? 'No ${selectedAlbum.name.toLowerCase()} found'
                        : 'Your vault is empty',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.text,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (isFilterActive && totalItems > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Text(
                        'Try selecting a different filter or clear the filter to see all items',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          color: AppTheme.text.withOpacity(0.6),
                          height: 1.5,
                        ),
                      ),
                    )
                  else if (isFilterActive && totalItems == 0)
                    Text(
                      'Your vault is empty',
                      style: TextStyle(
                        fontSize: 15,
                        color: AppTheme.text.withOpacity(0.6),
                      ),
                    )
                  else
                    Column(
                      children: [
                        Text(
                          'Start protecting your files',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            color: AppTheme.text.withOpacity(0.6),
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                AppTheme.accent.withOpacity(0.2),
                                AppTheme.accent.withOpacity(0.1),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: AppTheme.accent.withOpacity(0.3),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_circle_outline, color: AppTheme.accent, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                'Tap here to add files',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    ],
                  ),
                ),
              ),
            ),
            if (isFilterActive) ...[
              const SizedBox(height: 32),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppTheme.accent,
                      AppTheme.accentVariant,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.accent.withOpacity(0.4),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ElevatedButton.icon(
                  onPressed: () {
                    // Defer setState to avoid calling during build phase
                    Future.microtask(() {
                      if (mounted) {
                        setState(() {
                          _selectedAlbumId = 'smart_recent';
                          _selectedTagFilterIds.clear();
                          _selectedItemIds.clear();
                          _isSelectionMode = false;
                        });
                      }
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: const Icon(Icons.clear, color: AppTheme.primary),
                  label: const Text(
                    'Clear Filter',
                    style: TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
  
  Widget _buildAlbumSelector(VaultService vaultService) {
    final albums = vaultService.albums;
    
    return Container(
      height: 80,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppTheme.surface,
            AppTheme.surface.withOpacity(0.95),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: AppTheme.divider.withOpacity(0.5),
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: albums.length + 1, // +1 for create button
        cacheExtent: 100, // Limit off-screen rendering for horizontal list
        addAutomaticKeepAlives: false, // Don't keep items alive when scrolled away
        addRepaintBoundaries: true, // Isolate repaints for better performance
        itemBuilder: (context, index) {
          // Show create button at the end
          if (index == albums.length) {
            return _buildCreateAlbumButton(vaultService);
          }
          final album = albums[index];
          final isSelected = album.id == _selectedAlbumId;
          final itemCount = album.id.startsWith('smart_')
              ? vaultService.getSmartAlbumItems(album.id).length
              : album.itemIds.length;
          
          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _selectedAlbumId = 'smart_recent';
      } else {
                        _selectedAlbumId = album.id;
                      }
                      _selectedItemIds.clear();
                      _isSelectionMode = false;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: isSelected
                          ? LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                AppTheme.accent.withOpacity(0.3),
                                AppTheme.accent.withOpacity(0.15),
                              ],
                            )
                          : null,
                      color: isSelected ? null : AppTheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(20),
                      border: isSelected
                          ? Border.all(
                              color: AppTheme.accent,
                              width: 2,
                            )
                          : Border.all(
                              color: AppTheme.divider.withOpacity(0.3),
                              width: 1,
                            ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: AppTheme.accent.withOpacity(0.3),
                                blurRadius: 12,
                                spreadRadius: 0,
                              ),
                            ]
                          : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isSelected)
                          Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: AppTheme.accent,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check,
                              color: AppTheme.primary,
                              size: 12,
                            ),
                          ),
                        Text(
                          album.name,
                          style: TextStyle(
                            color: isSelected ? AppTheme.accent : AppTheme.text,
                            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                            fontSize: 14,
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppTheme.accent.withOpacity(0.2)
                                : AppTheme.text.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$itemCount',
                            style: TextStyle(
                              color: isSelected ? AppTheme.accent : AppTheme.text.withOpacity(0.7),
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (isSelected && !album.id.startsWith('smart_')) ...[
                          const SizedBox(width: 8),
                          // Delete button for user-created albums
                          GestureDetector(
                            onTap: () => _deleteAlbum(album.id),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: AppTheme.warning.withOpacity(0.2),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.delete_outline,
                                size: 14,
                                color: AppTheme.warning,
                              ),
                            ),
                          ),
                        ],
                        if (isSelected && itemCount > 0) ...[
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () => _downloadAlbum(album.id),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: AppTheme.accent.withOpacity(0.2),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.download,
                                size: 14,
                                color: AppTheme.accent,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTagFilterBar() {
    // Keep small + fast: just color dots that toggle filtering.
    const height = 52.0;
    final tagIds = _tagColorById.keys.toList(growable: false);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          bottom: BorderSide(
            color: AppTheme.divider.withOpacity(0.5),
            width: 1,
          ),
        ),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        itemCount: tagIds.length + 1, // +1 for "All" (clear)
        itemBuilder: (context, index) {
          if (index == 0) {
            final isSelected = _selectedTagFilterIds.isEmpty;
            return Padding(
              padding: const EdgeInsets.only(right: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () {
                  if (_selectedTagFilterIds.isEmpty) return;
                  setState(() {
                    _selectedTagFilterIds.clear();
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.accent.withOpacity(0.2) : AppTheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: isSelected ? AppTheme.accent : AppTheme.divider.withOpacity(0.3),
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.local_offer_outlined,
                        size: 16,
                        color: isSelected ? AppTheme.accent : AppTheme.text.withOpacity(0.7),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'All',
                        style: TextStyle(
                          color: isSelected ? AppTheme.accent : AppTheme.text.withOpacity(0.8),
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          final tagId = tagIds[index - 1];
          final color = _tagColorById[tagId]!;
          final isSelected = _selectedTagFilterIds.contains(tagId);

          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () {
                setState(() {
                  if (isSelected) {
                    _selectedTagFilterIds.remove(tagId);
                  } else {
                    _selectedTagFilterIds.add(tagId);
                  }
                });
              },
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? AppTheme.accent : Colors.white.withOpacity(0.85),
                    width: isSelected ? 3 : 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withOpacity(0.35),
                      blurRadius: 8,
                      spreadRadius: 0,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
  
  Widget _buildFilesViewWithFolderOption(List<VaultItem> items, VaultService vaultService) {
    return Column(
      children: [
        // Add folder button at top
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _showCreateFolderDialog(vaultService),
              icon: const Icon(Icons.create_new_folder),
              label: const Text('Create Folder'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: AppTheme.primary,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
        ),
        // Files view
        Expanded(
          child: _isGridView ? _buildGridView(items) : _buildListView(items),
        ),
      ],
    );
  }
  
  Widget _buildEmptyStateWithFolderOption(VaultService vaultService) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.folder_outlined,
          size: 80,
          color: AppTheme.text.withOpacity(0.3),
        ),
        const SizedBox(height: 24),
        Text(
          'No files or folders yet',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppTheme.text.withOpacity(0.7),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Create a folder to organize your files',
          style: TextStyle(
            fontSize: 14,
            color: AppTheme.text.withOpacity(0.5),
          ),
        ),
        const SizedBox(height: 32),
        ElevatedButton.icon(
          onPressed: () => _showCreateFolderDialog(vaultService),
          icon: const Icon(Icons.create_new_folder),
          label: const Text('Create Folder'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accent,
            foregroundColor: AppTheme.primary,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          ),
        ),
      ],
    );
  }

  Widget _buildGridView(List<VaultItem> items) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      // Use lazy loading - only build visible items
      cacheExtent: 200, // Reduced from 500 to minimize off-screen rendering
      addAutomaticKeepAlives: false, // Don't keep items alive when scrolled away
      addRepaintBoundaries: true, // Isolate repaints for better performance
      itemBuilder: (context, index) {
        final item = items[index];
        // Preload adjacent thumbnails for smoother scrolling
        if (index < items.length - 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _preloadThumbnail(items[index + 1]);
          });
        }
        // Wrap in RepaintBoundary to isolate repaints and improve performance
        return RepaintBoundary(
          child: _buildGridItem(item),
        );
      },
    );
  }
  
  Widget _buildBreadcrumb(VaultService vaultService) {
    final folder = vaultService.folders.firstWhere(
      (f) => f.id == _currentFolderId,
      orElse: () => throw StateError('Folder not found'),
    );
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          bottom: BorderSide(
            color: AppTheme.divider.withOpacity(0.5),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              setState(() {
                _currentFolderId = null;
              });
            },
            tooltip: 'Back',
          ),
          Expanded(
            child: Text(
              folder.name,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildRootView(List<VaultFolder> folders, List<VaultItem> items, VaultService vaultService) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Folders section
        if (folders.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Folders',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.text,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          _foldersMinimized ? Icons.expand_more : Icons.expand_less,
                          size: 20,
                        ),
                        onPressed: () {
                          setState(() {
                            _foldersMinimized = !_foldersMinimized;
                          });
                          _saveFoldersMinimized(_foldersMinimized);
                        },
                        tooltip: _foldersMinimized ? 'Expand folders' : 'Minimize folders',
                        color: AppTheme.text.withOpacity(0.7),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _showCreateFolderDialog(vaultService),
                  icon: const Icon(Icons.create_new_folder, size: 18),
                  label: const Text('New'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accent,
                  ),
                ),
              ],
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            height: _foldersMinimized ? 0 : 200,
            child: _foldersMinimized
                ? const SizedBox.shrink()
                : ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: folders.length + 1, // +1 for create folder button
              itemBuilder: (context, index) {
                if (index == folders.length) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: SizedBox(
                      width: 150,
                      child: _buildCreateFolderButton(vaultService),
                    ),
                  );
                }
                final folder = folders[index];
                final itemCount = folder.itemIds.length;
                
                return Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: SizedBox(
                    width: 150,
                    child: Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            _currentFolderId = folder.id;
                          });
                        },
                        onLongPress: () {
                          _showFolderOptionsDialog(context, folder, vaultService);
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.folder,
                                    size: 48,
                                    color: AppTheme.accent,
                                  ),
                                  const SizedBox(height: 8),
                                  Flexible(
                                    child: Text(
                                      folder.name,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.text,
                                      ),
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '$itemCount ${itemCount == 1 ? 'item' : 'items'}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.text.withOpacity(0.6),
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            // Delete button in top right corner
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Tooltip(
                                message: 'Folder options',
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: () {
                                      _showFolderOptionsDialog(context, folder, vaultService);
                                    },
                                    borderRadius: BorderRadius.circular(20),
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: AppTheme.surface.withOpacity(0.9),
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.1),
                                            blurRadius: 4,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: Icon(
                                        Icons.more_vert,
                                        size: 20,
                                        color: AppTheme.text,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (!_foldersMinimized) const SizedBox(height: 16),
        ],
        // Files section
        if (items.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(16, folders.isNotEmpty ? 0.0 : 16.0, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Text(
                      'Files',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.text,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        _filesMinimized ? Icons.expand_more : Icons.expand_less,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() {
                          _filesMinimized = !_filesMinimized;
                        });
                        _saveFilesMinimized(_filesMinimized);
                      },
                      tooltip: _filesMinimized ? 'Expand files' : 'Minimize files',
                      color: AppTheme.text.withOpacity(0.7),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                if (folders.isEmpty)
                  TextButton.icon(
                    onPressed: () => _showCreateFolderDialog(vaultService),
                    icon: const Icon(Icons.create_new_folder, size: 18),
                    label: const Text('Create Folder'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.accent,
                    ),
                  ),
              ],
            ),
          ),
          if (!_filesMinimized)
            Expanded(
              child: _isGridView ? _buildGridView(items) : _buildListView(items),
            ),
        ] else if (folders.isEmpty) ...[
          Expanded(
            child: _buildEmptyStateWithFolderOption(vaultService),
          ),
        ],
      ],
    );
  }
  
  Widget _buildFoldersView(List<VaultFolder> folders, VaultService vaultService) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 1.2,
      ),
      itemCount: folders.length + 1, // +1 for create folder button
      itemBuilder: (context, index) {
        if (index == folders.length) {
          return _buildCreateFolderButton(vaultService);
        }
        final folder = folders[index];
        final itemCount = folder.itemIds.length;
        
        return Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            onTap: () {
              setState(() {
                _currentFolderId = folder.id;
              });
            },
            onLongPress: () {
              _showFolderOptionsDialog(context, folder, vaultService);
            },
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.folder,
                            size: 48,
                            color: AppTheme.accent,
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: constraints.maxWidth,
                            child: Text(
                              folder.name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.text,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            width: constraints.maxWidth,
                            child: Text(
                              '$itemCount ${itemCount == 1 ? 'item' : 'items'}',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.text.withOpacity(0.6),
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                // Delete button in top right corner
                Positioned(
                  top: 4,
                  right: 4,
                  child: Tooltip(
                    message: 'Folder options',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          _showFolderOptionsDialog(context, folder, vaultService);
                        },
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppTheme.surface.withOpacity(0.9),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.more_vert,
                            size: 20,
                            color: AppTheme.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  
  Widget _buildCreateFolderButton(VaultService vaultService) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppTheme.accent.withOpacity(0.5),
          width: 2,
          style: BorderStyle.solid,
        ),
      ),
      child: InkWell(
        onTap: () => _showCreateFolderDialog(vaultService),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.create_new_folder,
                size: 48,
                color: AppTheme.accent,
              ),
              const SizedBox(height: 8),
              const Flexible(
                child: Text(
                  'New Folder',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Future<void> _showCreateFolderDialog(VaultService vaultService) async {
    final nameController = TextEditingController();
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text(
          'Create Folder',
          style: TextStyle(color: AppTheme.text),
        ),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: 'Folder Name',
            labelStyle: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            hintText: 'Enter folder name',
            hintStyle: TextStyle(color: AppTheme.text.withOpacity(0.5)),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.divider),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.accent),
            ),
          ),
          style: const TextStyle(color: AppTheme.text),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.trim().isNotEmpty) {
                Navigator.of(context).pop(nameController.text.trim());
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent,
              foregroundColor: AppTheme.primary,
            ),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty) {
      try {
        await vaultService.createFolder(result, parentFolderId: _currentFolderId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Folder "$result" created'),
              backgroundColor: AppTheme.accent,
            ),
          );
        }
      } catch (e) {
          if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error creating folder: $e'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
    }
  }
  
  Future<void> _showRenameFolderDialog(BuildContext context, VaultFolder folder, VaultService vaultService) async {
    final nameController = TextEditingController(text: folder.name);
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text(
          'Rename Folder',
          style: TextStyle(color: AppTheme.text),
        ),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: 'Folder Name',
            labelStyle: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            hintText: 'Enter folder name',
            hintStyle: TextStyle(color: AppTheme.text.withOpacity(0.5)),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.divider),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.accent),
            ),
          ),
          style: const TextStyle(color: AppTheme.text),
          autofocus: true,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty && value.trim() != folder.name) {
              Navigator.of(context).pop(value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final newName = nameController.text.trim();
              if (newName.isNotEmpty && newName != folder.name) {
                Navigator.of(context).pop(newName);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent,
              foregroundColor: AppTheme.primary,
            ),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty && result != folder.name) {
      try {
        final success = await vaultService.renameFolder(folder.id, result);
        if (success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Folder renamed to "$result"'),
              backgroundColor: AppTheme.accent,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error renaming folder: $e'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
    }
  }
  
  /// Show rename item dialog
  Future<void> _showRenameItemDialog(BuildContext context, VaultItem item, VaultService vaultService) async {
    final nameController = TextEditingController(text: item.displayName);
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text(
          'Rename File',
          style: TextStyle(color: AppTheme.text),
        ),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: 'File Name',
            labelStyle: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            hintText: 'Enter file name',
            hintStyle: TextStyle(color: AppTheme.text.withOpacity(0.5)),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.divider),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.accent),
            ),
          ),
          style: const TextStyle(color: AppTheme.text),
          autofocus: true,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty && value.trim() != item.displayName) {
              Navigator.of(context).pop(value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final newName = nameController.text.trim();
              if (newName.isNotEmpty && newName != item.displayName) {
                Navigator.of(context).pop(newName);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent,
              foregroundColor: AppTheme.primary,
            ),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty && result != item.displayName) {
      try {
        final success = await vaultService.renameItem(item.id, result);
        if (success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File renamed to "$result"'),
              backgroundColor: AppTheme.accent,
            ),
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to rename file'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      } catch (e) {
        debugPrint('[VaultHomePage] Error renaming item: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: $e'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
    }
  }
  
  /// Show item options dialog (rename, delete, etc.)
  Future<void> _showItemOptionsDialog(BuildContext context, VaultItem item, VaultService vaultService) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Text(
          item.displayName,
          style: const TextStyle(
            color: AppTheme.text,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: AppTheme.accent),
              title: const Text(
                'Rename',
                style: TextStyle(color: AppTheme.text),
              ),
              onTap: () => Navigator.of(context).pop('rename'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.local_offer_outlined, color: AppTheme.accent),
              title: const Text(
                'Tags',
                style: TextStyle(color: AppTheme.text),
              ),
              subtitle: Text(
                _formatTagSummary(vaultService.getItemTagIds(item.id)),
                style: TextStyle(color: AppTheme.text.withOpacity(0.6), fontSize: 12),
              ),
              onTap: () => Navigator.of(context).pop('tags'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppTheme.warning),
              title: const Text(
                'Delete',
                style: TextStyle(color: AppTheme.warning),
              ),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            ),
          ),
        ],
      ),
    );
    
    if (result == 'rename') {
      // Show rename dialog
      await _showRenameItemDialog(context, item, vaultService);
    } else if (result == 'tags') {
      await _showTagsDialog(context, item, vaultService);
    } else if (result == 'delete') {
      // Show confirmation dialog
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          ),
          title: const Text(
            'Delete File?',
            style: TextStyle(
              color: AppTheme.text,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            'Are you sure you want to delete "${item.displayName}"?',
            style: const TextStyle(
              color: AppTheme.text,
              fontSize: 14,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                'Cancel',
                style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.warning,
                foregroundColor: AppTheme.primary,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      
      if (confirm == true && mounted) {
        try {
          final success = await vaultService.deleteItem(item.id);
          if (success && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Deleted "${item.displayName}"'),
                backgroundColor: AppTheme.accent,
              ),
            );
          } else if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Failed to delete file'),
                backgroundColor: AppTheme.warning,
              ),
            );
          }
        } catch (e) {
          debugPrint('[VaultHomePage] Error deleting item: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error: $e'),
                backgroundColor: AppTheme.warning,
              ),
            );
          }
        }
      }
    }
  }
  
  Future<void> _showFolderOptionsDialog(BuildContext context, VaultFolder folder, VaultService vaultService) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Text(
          folder.name,
          style: const TextStyle(
            color: AppTheme.text,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${folder.itemIds.length} ${folder.itemIds.length == 1 ? 'item' : 'items'}',
              style: TextStyle(
                color: AppTheme.text.withOpacity(0.7),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: AppTheme.accent),
              title: const Text(
                'Rename Folder',
                style: TextStyle(color: AppTheme.text),
              ),
              onTap: () => Navigator.of(context).pop('rename'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppTheme.warning),
              title: const Text(
                'Delete Folder',
                style: TextStyle(color: AppTheme.warning),
              ),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            ),
          ),
        ],
      ),
    );
    
    if (result == 'rename') {
      // Show rename dialog
      await _showRenameFolderDialog(context, folder, vaultService);
    } else if (result == 'delete') {
      // Show confirmation dialog
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          ),
          title: const Text(
            'Delete Folder?',
            style: TextStyle(
              color: AppTheme.text,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            folder.itemIds.isEmpty
                ? 'Are you sure you want to delete "${folder.name}"?'
                : 'Are you sure you want to delete "${folder.name}"?\n\nThis folder contains ${folder.itemIds.length} ${folder.itemIds.length == 1 ? 'item' : 'items'}. The items will be moved back to the root level.',
            style: const TextStyle(
              color: AppTheme.text,
              fontSize: 14,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                'Cancel',
                style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.warning,
                foregroundColor: AppTheme.primary,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      
      if (confirm == true && mounted) {
        try {
          final success = await vaultService.deleteFolder(folder.id);
          if (success) {
            // If we're currently viewing this folder, go back to root
            if (_currentFolderId == folder.id) {
              setState(() {
                _currentFolderId = null;
              });
            }
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Folder "${folder.name}" deleted'),
                  backgroundColor: AppTheme.accent,
                ),
              );
            }
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Failed to delete folder'),
                  backgroundColor: AppTheme.warning,
                ),
              );
            }
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error deleting folder: $e'),
                backgroundColor: AppTheme.warning,
              ),
            );
          }
        }
      }
    }
  }

  String _formatTagSummary(List<String> tagIds) {
    final ids = tagIds.where((t) => _tagColorById.containsKey(t)).toList();
    if (ids.isEmpty) return 'None';
    if (ids.length == 1) return ids.first;
    return '${ids.length} tags';
  }

  Future<void> _showTagsDialog(BuildContext context, VaultItem item, VaultService vaultService) async {
    final selected = vaultService.getItemTagIds(item.id).toSet();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              backgroundColor: AppTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
              ),
              title: const Text(
                'Tags',
                style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w700),
              ),
              content: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _tagColorById.entries.map((entry) {
                  final tagId = entry.key;
                  final color = entry.value;
                  final isSelected = selected.contains(tagId);
                  return InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () {
                      setLocalState(() {
                        if (isSelected) {
                          selected.remove(tagId);
                        } else {
                          selected.add(tagId);
                        }
                      });
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? AppTheme.accent : Colors.white.withOpacity(0.9),
                          width: isSelected ? 4 : 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: color.withOpacity(0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: isSelected
                          ? const Icon(Icons.check, color: Colors.white, size: 18)
                          : null,
                    ),
                  );
                }).toList(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Cancel',
                    style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final ok = await vaultService.setItemTagIds(item.id, selected.toList());
                    if (mounted && ok) {
                      Navigator.of(context).pop();
                      setState(() {}); // refresh tag dots without waiting on listeners
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    foregroundColor: AppTheme.primary,
                  ),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildListView(List<VaultItem> items) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      cacheExtent: 200, // Reduced cache extent for better performance
      addAutomaticKeepAlives: false, // Don't keep items alive when scrolled away
      addRepaintBoundaries: true, // Isolate repaints for better performance
      itemBuilder: (context, index) {
        final item = items[index];
        // Preload adjacent thumbnails for smoother scrolling
        if (index < items.length - 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _preloadThumbnail(items[index + 1]);
          });
        }
        // Wrap in RepaintBoundary to isolate repaints and improve performance
        return RepaintBoundary(
          child: _buildListItem(item),
        );
      },
    );
  }
  
  Widget _buildGridItem(VaultItem item) {
    final isSelected = _selectedItemIds.contains(item.id);
    final tagIds = _getItemTagIds(item);
    
    return GestureDetector(
      onTap: () {
        if (_isSelectionMode) {
          _toggleItemSelection(item.id);
          } else {
          _openItem(item);
        }
      },
      onLongPress: () {
        if (!_isSelectionMode) {
          // Defer setState to avoid calling during build phase
          Future.microtask(() {
            if (mounted) {
              setState(() {
                _isSelectionMode = true;
                _selectedItemIds.add(item.id);
              });
            }
          });
        }
      },
      child: Container(
        // Removed AnimatedContainer for better performance - causes stuttering with many items
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Main thumbnail with vibrant border
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _getTypeColor(item.type).withOpacity(0.3),
                    _getTypeColor(item.type).withOpacity(0.1),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: _getTypeColor(item.type).withOpacity(0.2),
                    blurRadius: 8,
                    spreadRadius: 0,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildItemThumbnail(item),
              ),
            ),
            // Selection overlay with vibrant gradient
            if (isSelected)
              Container(
                // Removed AnimatedContainer for better performance
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppTheme.accent.withOpacity(0.4),
                      AppTheme.accent.withOpacity(0.2),
                    ],
                  ),
                  border: Border.all(
                    color: AppTheme.accent,
                    width: 3,
                  ),
                ),
              ),
            // Selection checkmark with vibrant background
            if (isSelected)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppTheme.accent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.accent.withOpacity(0.5),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check,
                    color: AppTheme.primary,
                    size: 16,
                  ),
                ),
              ),
            // Tag dots (top-left)
            if (tagIds.isNotEmpty)
              Positioned(
                top: 6,
                left: 6,
                child: IgnorePointer(
                  child: _buildTagDots(tagIds, dotSize: 8),
                ),
              ),
            // Video duration badge on thumbnail
            if (item.type == VaultItemType.video)
              Positioned(
                bottom: 6,
                right: 6,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.black.withOpacity(0.8),
                          Colors.black.withOpacity(0.6),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.play_arrow, color: Colors.white, size: 12),
                        const SizedBox(width: 2),
                        Text(
                          _formatDuration(item.durationMs),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Photo indicator (so pictures have an icon too)
            if (item.type == VaultItemType.photo)
              Positioned(
                bottom: 6,
                left: 6,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.blue.withOpacity(0.9),
                          Colors.blue.withOpacity(0.7),
                        ],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.blue.withOpacity(0.35),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.image, color: Colors.white, size: 12),
                  ),
                ),
              ),
            // Audio indicator
            if (item.type == VaultItemType.audio)
              Positioned(
                bottom: 6,
                left: 6,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.purple.withOpacity(0.9),
                          Colors.purple.withOpacity(0.7),
                        ],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.purple.withOpacity(0.4),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.music_note, color: Colors.white, size: 12),
                  ),
                ),
              ),
            // Options menu button (top-right corner)
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: () {
                  final vaultService = Provider.of<VaultService>(context, listen: false);
                  _showItemOptionsDialog(context, item, vaultService);
                },
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppTheme.surface.withOpacity(0.9),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 4,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.more_vert,
                    color: AppTheme.text,
                    size: 16,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  // Cache type colors to avoid repeated lookups
  static final Map<VaultItemType, Color> _typeColorCache = {
    VaultItemType.photo: Colors.blue,
    VaultItemType.video: Colors.red,
    VaultItemType.audio: Colors.purple,
    VaultItemType.document: Colors.orange,
    VaultItemType.archive: Colors.brown,
  };
  
  Color _getTypeColor(VaultItemType type) {
    return _typeColorCache[type] ?? AppTheme.accent;
  }
  
  Widget _buildListItem(VaultItem item) {
    final isSelected = _selectedItemIds.contains(item.id);
    final tagIds = _getItemTagIds(item);
    
    // Build the child widget once
    final child = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (_isSelectionMode) {
            _toggleItemSelection(item.id);
          } else {
            _openItem(item);
          }
        },
        onLongPress: () {
          if (!_isSelectionMode) {
            // Defer setState to avoid calling during build phase
            Future.microtask(() {
              if (mounted) {
                setState(() {
                  _isSelectionMode = true;
                  _selectedItemIds.add(item.id);
                });
              }
            });
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
            child: Row(
            children: [
              // Thumbnail with vibrant border (and video duration overlay)
              SizedBox(
                width: 70,
                height: 70,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            _getTypeColor(item.type).withOpacity(0.3),
                            _getTypeColor(item.type).withOpacity(0.1),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _getTypeColor(item.type).withOpacity(0.2),
                            blurRadius: 6,
                            spreadRadius: 0,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _buildItemThumbnail(item),
                      ),
                    ),
                    if (item.type == VaultItemType.video)
                      Positioned(
                        bottom: 4,
                        right: 4,
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.75),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.play_arrow, color: Colors.white, size: 10),
                                const SizedBox(width: 2),
                                Text(
                                  _formatDuration(item.durationMs),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (item.type == VaultItemType.photo)
                      Positioned(
                        bottom: 4,
                        left: 4,
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.85),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.image, color: Colors.white, size: 10),
                          ),
                        ),
                      ),
                    if (tagIds.isNotEmpty)
                      Positioned(
                        top: 4,
                        left: 4,
                        child: IgnorePointer(
                          child: _buildTagDots(tagIds, dotSize: 7),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      style: TextStyle(
                        color: AppTheme.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: _getTypeColor(item.type).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _getTypeLabel(item.type),
                            style: TextStyle(
                              color: _getTypeColor(item.type),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatFileSize(item.sizeBytes),
                          style: TextStyle(
                            color: AppTheme.text.withOpacity(0.6),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Trailing icon
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: isSelected
                    ? Container(
                        key: const ValueKey('selected'),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppTheme.accent,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.accent.withOpacity(0.4),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.check,
                          color: AppTheme.primary,
                          size: 20,
                        ),
                      )
                    : _isSelectionMode
                        ? Icon(
                            Icons.chevron_right,
                            key: const ValueKey('selection_mode'),
                            color: AppTheme.text.withOpacity(0.3),
                            size: 24,
                          )
                        : IconButton(
                            key: const ValueKey('options'),
                            icon: Icon(
                              Icons.more_vert,
                              color: AppTheme.text.withOpacity(0.7),
                              size: 20,
                            ),
                            onPressed: () {
                              final vaultService = Provider.of<VaultService>(context, listen: false);
                              _showItemOptionsDialog(context, item, vaultService);
                            },
                            tooltip: 'More options',
                          ),
              ),
            ],
          ),
        ),
      ),
    );
    
    // Use regular Container when not selected for better performance
    if (isSelected) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              AppTheme.accent.withOpacity(0.15),
              AppTheme.accent.withOpacity(0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.accent.withOpacity(0.5), width: 2),
          boxShadow: [
            BoxShadow(
              color: AppTheme.accent.withOpacity(0.2),
              blurRadius: 12,
              spreadRadius: 2,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: child,
      );
    } else {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 4,
              spreadRadius: 0,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: child,
      );
    }
  }
  
  // Cache type labels to avoid repeated lookups
  static const Map<VaultItemType, String> _typeLabelCache = {
    VaultItemType.photo: 'PHOTO',
    VaultItemType.video: 'VIDEO',
    VaultItemType.audio: 'AUDIO',
    VaultItemType.document: 'DOC',
    VaultItemType.archive: 'ZIP',
  };
  
  String _getTypeLabel(VaultItemType type) {
    return _typeLabelCache[type] ?? 'FILE';
  }
  
  Widget _buildItemThumbnail(VaultItem item) {
    // For all types including videos, use static thumbnail with caching
    // Videos will have thumbnails generated automatically when stored
    // Check for thumbnail using effectiveThumbnailPath (handles both new and legacy)
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final thumbnailPath = vaultService.getThumbnailPath(item.id);
    
    if (thumbnailPath != null) {
      final thumbnailFile = File(thumbnailPath);
      if (thumbnailFile.existsSync()) {
        return Image.file(
          thumbnailFile,
          fit: BoxFit.cover,
          cacheWidth: 200,
          cacheHeight: 200,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) {
              return child;
            }
            return _buildPlaceholder(item);
          },
          errorBuilder: (context, error, stackTrace) {
            debugPrint('[VaultHomePage] Error loading thumbnail for ${item.id}: $error');
            return _buildPlaceholder(item);
          },
        );
      }
    }

    // PHOTO: If thumbnail is missing, show a real preview from the vault file path (downscaled).
    // This ensures picture thumbnails are always actual image previews.
    if (item.type == VaultItemType.photo) {
      final filePath = vaultService.getFilePath(item.id);
      if (filePath != null) {
        final photoFile = File(filePath);
        if (photoFile.existsSync()) {
          _queueThumbnailGenerationIfNeeded(vaultService, item.id);
          return Image.file(
            photoFile,
            fit: BoxFit.cover,
            cacheWidth: 200,
            cacheHeight: 200,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) return child;
              return _buildPlaceholder(item);
            },
            errorBuilder: (context, error, stackTrace) {
              debugPrint('[VaultHomePage] Error loading photo preview for ${item.id}: $error');
              return _buildPlaceholder(item);
            },
          );
        }
      }
    }
    
    // If no thumbnail exists yet, show placeholder
    // Thumbnails will be generated in the background
    if (item.type == VaultItemType.photo) {
      _queueThumbnailGenerationIfNeeded(vaultService, item.id);
    }
    return _buildPlaceholder(item);
  }

  void _queueThumbnailGenerationIfNeeded(VaultService vaultService, String itemId) {
    if (_requestedMissingThumbnails.contains(itemId)) return;
    _requestedMissingThumbnails.add(itemId);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await vaultService.generateThumbnailForItem(itemId);
      } catch (e) {
        debugPrint('[VaultHomePage] Thumbnail generation failed for $itemId: $e');
      }
      if (mounted) setState(() {});
    });
  }
  
  Widget _buildPlaceholder(VaultItem item) {
    IconData icon;
    Color color;
    
    switch (item.type) {
      case VaultItemType.photo:
        icon = Icons.image;
        color = Colors.blue;
        break;
      case VaultItemType.video:
        icon = Icons.videocam;
        color = Colors.red;
        break;
      case VaultItemType.audio:
        icon = Icons.audiotrack;
        color = Colors.purple;
        break;
      case VaultItemType.document:
        icon = Icons.description;
        color = Colors.orange;
        break;
      case VaultItemType.archive:
        icon = Icons.archive;
        color = Colors.brown;
        break;
      default:
        icon = Icons.insert_drive_file;
        color = AppTheme.text.withOpacity(0.5);
    }
    
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withOpacity(0.2),
            color.withOpacity(0.1),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          icon,
          color: color.withOpacity(0.8),
          size: 36,
        ),
      ),
    );
  }

  Widget _buildTagDots(List<String> tagIds, {required double dotSize}) {
    final unique = <String>{};
    final colors = <Color>[];
    for (final id in tagIds) {
      if (unique.contains(id)) continue;
      final c = _tagColorById[id];
      if (c == null) continue;
      unique.add(id);
      colors.add(c);
      if (colors.length >= 4) break; // keep overlay tiny
    }
    if (colors.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List<Widget>.generate(colors.length, (i) {
          final c = colors[i];
          return Container(
            width: dotSize,
            height: dotSize,
            margin: EdgeInsets.only(right: i == colors.length - 1 ? 0 : 4),
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.9), width: 1),
            ),
          );
        }),
      ),
    );
  }
  
  /// Preload thumbnail for adjacent items to improve scroll performance
  /// Uses path-based precaching (no memory loading)
  void _preloadThumbnail(VaultItem item) {
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final thumbnailPath = vaultService.getThumbnailPath(item.id);
    
    if (thumbnailPath != null) {
      final thumbnailFile = File(thumbnailPath);
      if (thumbnailFile.existsSync()) {
        // Precache image file for instant display
        precacheImage(FileImage(thumbnailFile), context).catchError((_) {
          debugPrint('[VaultHomePage] Error precaching thumbnail: ${item.id}');
        });
      }
    }
  }
  
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Format duration in ms to M:SS or H:MM:SS for display on video thumbnails.
  String _formatDuration(int? durationMs) {
    if (durationMs == null || durationMs < 0) return '–:––';
    final sec = durationMs ~/ 1000;
    final m = sec ~/ 60;
    final s = sec % 60;
    final h = m ~/ 60;
    final mm = m % 60;
    if (h > 0) {
      return '$h:${mm.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
  
  void _openItem(VaultItem item) {
    final items = _getDisplayItems();
    final index = items.indexWhere((i) => i.id == item.id);
    
    Navigator.of(context).push(
        MaterialPageRoute(
        builder: (context) => VaultItemDetailPage(
          item: item,
          allItems: items,
          initialIndex: index >= 0 ? index : null,
        ),
      ),
    );
  }
  
  Future<void> _downloadAlbum(String albumId) async {
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final albumItems = albumId.startsWith('smart_')
        ? vaultService.getSmartAlbumItems(albumId)
        : vaultService.getAlbumItems(albumId);
    
    if (albumItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Album is empty'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
        return;
      }
    
    await _downloadItems(albumItems.map((item) => item.id).toSet());
  }
  
  Widget _buildImportProgressIndicator() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Status text
              if (_importStatus != null)
                Text(
                  _importStatus!,
                  style: TextStyle(
                    color: AppTheme.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(height: 8),
              // Progress bar
              if (_importTotal > 0)
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          // If we're still starting up (queued but first file hasn't reported yet),
                          // show an indeterminate animation so the user sees activity immediately.
                          value: _importProgress > 0 ? (_importProgress / _importTotal) : null,
                          backgroundColor: AppTheme.divider,
                          valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
                          minHeight: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '$_importProgress / $_importTotal',
                      style: TextStyle(
                        color: AppTheme.text.withOpacity(0.7),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _importStatus ?? 'Importing...',
                        style: TextStyle(
                          color: AppTheme.text,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildCreateAlbumButton(VaultService vaultService) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _showCreateAlbumDialog(vaultService),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.accent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppTheme.accent.withOpacity(0.3),
                width: 1.5,
                style: BorderStyle.solid,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.add,
                  color: AppTheme.accent,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(
                  'New Album',
                  style: TextStyle(
                    color: AppTheme.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  void _showCreateAlbumDialog(VaultService vaultService) {
    final TextEditingController nameController = TextEditingController();
    
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Row(
          children: [
            Icon(Icons.create_new_folder, color: AppTheme.accent, size: 28),
            const SizedBox(width: 12),
            const Text(
              'Create Album',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
          ],
        ),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Album Name',
            hintText: 'Enter album name',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radius),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radius),
              borderSide: BorderSide(color: AppTheme.accent, width: 2),
            ),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              _createAlbum(vaultService, value.trim());
              Navigator.of(context).pop();
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: AppTheme.text.withOpacity(0.6),
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isNotEmpty) {
                _createAlbum(vaultService, name);
                Navigator.of(context).pop();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent,
              foregroundColor: AppTheme.primary,
            ),
            child: const Text(
              'Create',
              style: TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Future<void> _createAlbum(VaultService vaultService, String name) async {
    try {
      // Check if album name already exists
      final existingAlbum = vaultService.albums.firstWhere(
        (album) => album.name.toLowerCase() == name.toLowerCase(),
        orElse: () => Album(id: '', name: '', createdAt: DateTime.now()),
      );
      
      if (existingAlbum.id.isNotEmpty) {
        if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
              content: Text('Album "$name" already exists'),
        backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }
      
      final album = await vaultService.createAlbum(name);
      
      if (mounted) {
        setState(() {
          _selectedAlbumId = album.id;
        });
        
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
            content: Text('Album "$name" created'),
        backgroundColor: AppTheme.accent,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[VaultHomePage] Error creating album: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating album: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }
  
  Future<void> _deleteAlbum(String albumId) async {
    // Don't delete smart albums
    if (albumId.startsWith('smart_')) return;
    
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final album = vaultService.albums.firstWhere(
      (a) => a.id == albumId,
      orElse: () => Album(id: '', name: '', createdAt: DateTime.now()),
    );
    
    if (album.id.isEmpty) return;
    
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppTheme.warning, size: 28),
            const SizedBox(width: 12),
            const Text(
              'Delete Album',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to delete "${album.name}"?\n\nThis will not delete the files, only remove them from this album.',
          style: TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: AppTheme.text.withOpacity(0.6),
          ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.warning,
              foregroundColor: Colors.white,
            ),
            child: const Text(
              'Delete',
              style: TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      final deleted = await vaultService.deleteAlbum(albumId);
      
      if (mounted) {
        if (deleted) {
          setState(() {
            // Switch to Recent album if deleted album was selected
            if (_selectedAlbumId == albumId) {
              _selectedAlbumId = 'smart_recent';
            }
          });
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Album "${album.name}" deleted'),
              backgroundColor: AppTheme.accent,
              duration: const Duration(seconds: 2),
            ),
          );
      } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting album'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
    }
  }
  
  void _showPaywall() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const PaywallPage(showCloseButton: true),
      ),
    );
  }
  
  Future<void> _downloadAll() async {
    final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
    final hasPremium = subscriptionService.currentTier.isUnlimited || subscriptionService.isInTrial;
    
    if (!hasPremium) {
      _showPaywall();
      return;
    }
    
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final allItems = vaultService.items;
    
    if (allItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Vault is empty'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }
    
    // Show confirmation dialog
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: const Text(
          'Download All Items',
          style: TextStyle(color: AppTheme.text),
        ),
        content: Text(
          'This will download all ${allItems.length} item(s) from your vault. This may take a while.',
          style: const TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.accent,
            ),
            child: const Text('Download All'),
          ),
        ],
      ),
    );
    
    if (shouldDownload != true) return;

    // Use the same download logic as _downloadSelected but with all items
    await _downloadItems(allItems.map((item) => item.id).toSet());
  }

  Future<void> _downloadSelected() async {
    if (_selectedItemIds.isEmpty) return;
    await _downloadItems(_selectedItemIds, clearSelection: true);
  }

  Future<void> _downloadItems(Set<String> itemIds, {bool clearSelection = false}) async {
    if (itemIds.isEmpty) return;

    final vaultService = Provider.of<VaultService>(context, listen: false);
    final authService = Provider.of<AuthService>(context, listen: false);
    final masterKey = authService.masterKey;
    
    if (masterKey == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Vault must be unlocked to download files'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }
    
    // Show progress dialog
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: AppTheme.accent),
              const SizedBox(height: 16),
              Text(
                'Downloading ${itemIds.length} item(s)...',
                style: const TextStyle(color: AppTheme.text),
              ),
            ],
          ),
        ),
      );
    }

    try {
      int successCount = 0;
      int failCount = 0;
      final List<VaultItem> photos = [];
      final List<VaultItem> videos = [];
      final List<VaultItem> otherFiles = [];

      // Categorize items
      for (final itemId in itemIds) {
        final item = vaultService.items.firstWhere(
          (i) => i.id == itemId,
          orElse: () => throw Exception('Item not found'),
        );
        
        if (item.type == VaultItemType.photo) {
          photos.add(item);
        } else if (item.type == VaultItemType.video) {
          videos.add(item);
      } else {
          otherFiles.add(item);
        }
      }

      // Request photo library add permission ONLY for photos/videos
      // Skip permission check if only other files (audio, documents, etc.)
      // Note: We'll check actual save results instead of pre-checking permissions
      // to avoid false error messages when permission is actually granted
      if ((photos.isNotEmpty || videos.isNotEmpty) && Platform.isIOS) {
        // Try to request permission, but don't block or show errors based on this check
        // We'll check the actual save result instead to determine if permission is really denied
        await _permissionService.requestPhotoLibraryAddPermission();
      } else if ((photos.isNotEmpty || videos.isNotEmpty) && Platform.isAndroid) {
        // Android: Request storage permission
        final isPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.storage);
        
        if (isPermanentlyDenied) {
          if (mounted) {
            Navigator.pop(context); // Close progress dialog
            final shouldOpen = await _showPermissionDialog(
              title: 'Storage Access Needed',
              message: 'To save photos and videos, Nyx needs storage access.\n\nPlease enable storage access in Settings.',
            );
            
            if (shouldOpen == true) {
              await _permissionService.openSettings();
            }
          }
          return;
        }
        
        final granted = await _permissionService.isPhotoLibraryAddGranted() || await _permissionService.requestPhotoLibraryAddPermission();
        
        if (!granted) {
          final isNowPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.storage);
          
          if (isNowPermanentlyDenied && mounted) {
            Navigator.pop(context); // Close progress dialog
            final shouldOpen = await _showPermissionDialog(
              title: 'Storage Access Needed',
              message: 'To save photos and videos, Nyx needs storage access.\n\nPlease enable storage access in Settings.',
            );
            
            if (shouldOpen == true) {
              await _permissionService.openSettings();
            }
          } else if (mounted) {
            Navigator.pop(context); // Close progress dialog
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Storage permission is required to save photos/videos'),
                backgroundColor: AppTheme.warning,
              ),
            );
          }
          return;
        }
      }

      // Download photos
      int photoFailures = 0;
      for (final item in photos) {
        try {
          final fileData = await vaultService.getFileData(item.id, masterKey: masterKey);
          if (fileData != null) {
            final tempDir = await getTemporaryDirectory();
            final extension = item.extension ?? 'jpg';
            final tempFile = File('${tempDir.path}/download_${item.id}_${DateTime.now().millisecondsSinceEpoch}.$extension');
            await tempFile.writeAsBytes(fileData);
            
            final result = await PhotoManager.editor.saveImageWithPath(
              tempFile.path,
              title: item.displayName,
            );
            
            if (result != null) {
              successCount++;
          } else {
          failCount++;
          photoFailures++;
          }
          
            tempFile.delete().catchError((_) async => tempFile);
          } else {
            failCount++;
            photoFailures++;
          }
        } catch (e) {
          debugPrint('[VaultHomePage] Error downloading photo: $e');
          failCount++;
          photoFailures++;
        }
      }

      // Download videos
      int videoFailures = 0;
      for (final item in videos) {
        try {
          final fileData = await vaultService.getFileData(item.id, masterKey: masterKey);
          if (fileData != null) {
            final tempDir = await getTemporaryDirectory();
            final extension = item.extension ?? 'mp4';
            final tempFile = File('${tempDir.path}/download_${item.id}_${DateTime.now().millisecondsSinceEpoch}.$extension');
            await tempFile.writeAsBytes(fileData);
            
            final result = await PhotoManager.editor.saveVideo(
              tempFile,
              title: item.displayName,
            );
            
            if (result != null) {
        successCount++;
          } else {
              failCount++;
              videoFailures++;
          }
          
            tempFile.delete().catchError((_) async => tempFile);
          } else {
            failCount++;
            videoFailures++;
          }
        } catch (e) {
          debugPrint('[VaultHomePage] Error downloading video: $e');
        failCount++;
        videoFailures++;
        }
      }
      
      // Only show permission error if photos/videos actually failed to save
      // and we have failures that might be due to permissions
      // IMPORTANT: Only show if saves actually failed AND permission is actually denied
      // AND we have photos/videos that failed (not just other files)
      if ((photoFailures > 0 || videoFailures > 0) && Platform.isIOS && mounted && (photos.isNotEmpty || videos.isNotEmpty)) {
        // First check if permission is actually granted - if it is, don't show the dialog
        // This prevents false positives when permission is actually granted
        final isGranted = await _permissionService.isPhotoLibraryAddGranted();
        debugPrint('[VaultHomePage] Permission check after download - granted: $isGranted, photoFailures: $photoFailures, videoFailures: $videoFailures');
        
        if (!isGranted) {
          // Only then check if it's permanently denied
          final isPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.photosAddOnly);
          debugPrint('[VaultHomePage] Permission permanently denied: $isPermanentlyDenied');
          
          if (isPermanentlyDenied) {
            // Show permission dialog only if saves actually failed AND permission is actually denied
            final shouldOpen = await _showPermissionDialog(
              title: 'Photo Library Access Needed',
              message: 'Some photos or videos could not be saved. Nyx needs access to your photo library.\n\nPlease enable photo library access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Tap "Photos"\n4. Select "All Photos" or "Selected Photos"\n\nThen return to the app to continue.',
            );
            
            if (shouldOpen == true) {
              await _permissionService.openSettings();
            }
          }
        } else {
          // Permission is granted - don't show dialog even if there were failures
          // Failures might be due to other reasons (file corruption, disk space, etc.)
          debugPrint('[VaultHomePage] Permission is granted, not showing permission dialog. Failures may be due to other reasons.');
        }
      }

      // Download other files
      if (otherFiles.isNotEmpty) {
        Directory? targetDir;
        if (Platform.isAndroid) {
          final downloadsDir = Directory('/storage/emulated/0/Download');
          if (await downloadsDir.exists()) {
            targetDir = downloadsDir;
          } else {
            targetDir = await getApplicationDocumentsDirectory();
          }
        } else {
          targetDir = await getApplicationDocumentsDirectory();
        }

        for (final item in otherFiles) {
          try {
            final fileData = await vaultService.getFileData(item.id, masterKey: masterKey);
            if (fileData != null && targetDir != null) {
              final file = File('${targetDir.path}/${item.displayName}');
              await file.writeAsBytes(fileData);
        successCount++;
            } else {
              failCount++;
            }
      } catch (e) {
            debugPrint('[VaultHomePage] Error downloading file: $e');
        failCount++;
          }
        }
      }

    if (mounted) {
        Navigator.pop(context); // Close progress dialog
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              failCount > 0
                  ? 'Downloaded $successCount item(s), $failCount failed'
                  : 'Downloaded $successCount item(s) successfully',
            ),
            backgroundColor: failCount > 0 ? AppTheme.warning : AppTheme.accent,
          ),
        );

        if (clearSelection) {
          setState(() {
            _selectedItemIds.clear();
            _isSelectionMode = false;
          });
        }
      }
    } catch (e) {
      debugPrint('[VaultHomePage] Error downloading selected items: $e');
      if (mounted) {
        Navigator.pop(context); // Close progress dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error downloading items: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }
  
  Future<void> _moveToFolder() async {
    if (_selectedItemIds.isEmpty) return;
    
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final folders = vaultService.folders;
    
    if (folders.isEmpty) {
      // If no folders exist, ask to create one
      final createFolder = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text('No Folders'),
          content: const Text(
            'You need to create a folder first. Would you like to create one now?',
            style: TextStyle(color: AppTheme.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: AppTheme.primary,
              ),
              child: const Text('Create Folder'),
            ),
          ],
        ),
      );
      
      if (createFolder == true) {
        await _showCreateFolderDialog(vaultService);
        // Retry after creating folder
        if (vaultService.folders.isNotEmpty && mounted) {
          _moveToFolder();
        }
      }
      return;
    }
    
    // Show folder selection dialog
    String? selectedFolderId;
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text(
            'Move ${_selectedItemIds.length} item(s) to folder',
            style: const TextStyle(color: AppTheme.text),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: folders.length + 1, // +1 for "None" option
              itemBuilder: (context, index) {
                if (index == 0) {
                  // "None" option to remove from folder
                  return RadioListTile<String?>(
                    title: const Text('None (Remove from folder)'),
                    value: null,
                    groupValue: selectedFolderId,
                    onChanged: (value) {
                      setDialogState(() {
                        selectedFolderId = value;
                      });
                    },
                    activeColor: AppTheme.accent,
                  );
                }
                
                final folder = folders[index - 1];
                return RadioListTile<String>(
                  title: Text(folder.name),
                  subtitle: Text('${folder.itemIds.length} items'),
                  value: folder.id,
                  groupValue: selectedFolderId,
                  onChanged: (value) {
                    setDialogState(() {
                      selectedFolderId = value;
                    });
                  },
                  activeColor: AppTheme.accent,
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: AppTheme.primary,
              ),
              child: const Text('Move'),
            ),
          ],
        ),
      ),
    );
    
    if (result != true) return;
    
    try {
      // Move each selected item
      for (final itemId in _selectedItemIds) {
        // First, remove from current folder if any
        for (final folder in folders) {
          if (folder.itemIds.contains(itemId)) {
            await vaultService.removeItemFromFolder(itemId, folder.id);
          }
        }
        
        // Then add to selected folder (or leave in root if null)
        if (selectedFolderId != null) {
          await vaultService.addItemToFolder(itemId, selectedFolderId!);
        }
      }
      
    if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              selectedFolderId == null
                  ? 'Removed ${_selectedItemIds.length} item(s) from folder'
                  : 'Moved ${_selectedItemIds.length} item(s) to folder',
            ),
            backgroundColor: AppTheme.accent,
          ),
        );
      }
      
      setState(() {
        _selectedItemIds.clear();
        _isSelectionMode = false;
      });
    } catch (e) {
      debugPrint('[VaultHomePage] Error moving items: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error moving items: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }
  
  void _deleteSelected() async {
    if (_selectedItemIds.isEmpty) return;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
      backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: const Text(
          'Delete Items',
          style: TextStyle(color: AppTheme.text),
        ),
        content: Text(
          'Delete ${_selectedItemIds.length} item(s)? This cannot be undone.',
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
    
    if (confirmed == true) {
      final vaultService = Provider.of<VaultService>(context, listen: false);
      for (final itemId in _selectedItemIds) {
        await vaultService.deleteItem(itemId);
      }
      
      setState(() {
        _selectedItemIds.clear();
        _isSelectionMode = false;
      });
    }
  }
  
  void _showAddMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLarge)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
              ListTile(
                leading: const Icon(Icons.camera_alt, color: AppTheme.accent),
                title: const Text('Take Photo'),
                onTap: () {
                  Navigator.pop(context);
                  _capturePhoto();
                },
              ),
              ListTile(
              leading: const Icon(Icons.photo_library, color: AppTheme.accent),
              title: const Text('Import Photos'),
                onTap: () {
                  Navigator.pop(context);
                _importPhotos();
              },
            ),
              ListTile(
              leading: const Icon(Icons.videocam, color: AppTheme.accent),
              title: const Text('Record Video'),
                onTap: () {
                  Navigator.pop(context);
                _recordVideo();
                },
              ),
              ListTile(
              leading: const Icon(Icons.video_library, color: AppTheme.accent),
              title: const Text('Import Videos'),
                onTap: () {
                  Navigator.pop(context);
                _importVideos();
                },
              ),
              ListTile(
              leading: const Icon(Icons.folder, color: AppTheme.accent),
              title: const Text('Import Files'),
                onTap: () {
                  Navigator.pop(context);
                _importFiles();
                },
              ),
              ListTile(
                leading: const Icon(Icons.auto_fix_high, color: AppTheme.accent),
                title: const Text('Remove duplicates'),
                subtitle: const Text('Detect and delete duplicate files'),
                onTap: () async {
                  Navigator.pop(context);
                  final vaultService = Provider.of<VaultService>(context, listen: false);
                  if (!mounted) return;
                  setState(() {
                    _isImporting = true;
                    _importProgress = 0;
                    _importTotal = 0;
                    _importStatus = 'Scanning for duplicates...';
                  });
                  final removed = await vaultService.removeDuplicates(onProgress: (current, total, status) {
                    if (!mounted) return;
                    setState(() {
                      _isImporting = true;
                      _importProgress = 0;
                      _importTotal = 0;
                      _importStatus = status;
                    });
                  });
                  if (!mounted) return;
                  setState(() {
                    _isImporting = false;
                    _importProgress = 0;
                    _importTotal = 0;
                    _importStatus = null;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Removed $removed duplicate(s)'),
                      backgroundColor: AppTheme.accent,
                      duration: const Duration(seconds: 3),
                    ),
                  );
                },
              ),
            ],
        ),
      ),
    );
  }
  
  Future<void> _capturePhoto() async {
    try {
      debugPrint('[VaultHomePage] === Starting camera photo capture ===');
      
      // Check current permission status first
      final currentStatus = await Permission.camera.status;
      debugPrint('[VaultHomePage] Camera permission current status: $currentStatus');
      
      // Check if permission is permanently denied
      final isPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.camera);
      debugPrint('[VaultHomePage] Camera permission permanently denied: $isPermanentlyDenied');
      
      if (isPermanentlyDenied) {
        if (mounted) {
          final shouldOpen = await _showPermissionDialog(
            title: 'Camera Access Needed',
            message: 'To capture photos, Nyx needs access to your camera.\n\nPlease enable camera access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Turn on "Camera"\n\nThen return to the app to continue.',
          );
          
          if (shouldOpen == true) {
            await _permissionService.openSettings();
          }
        }
        return;
      }
      
      // Request camera permission
      debugPrint('[VaultHomePage] Requesting camera permission...');
      final granted = await _permissionService.requestCameraPermission();
      debugPrint('[VaultHomePage] Camera permission granted: $granted');
      
      // Check final status to determine if it's permanently denied or just denied
      final finalStatus = await Permission.camera.status;
      debugPrint('[VaultHomePage] Camera permission final status: $finalStatus');
      debugPrint('[VaultHomePage] Camera permission final - granted: ${finalStatus.isGranted}, denied: ${finalStatus.isDenied}, permanentlyDenied: ${finalStatus.isPermanentlyDenied}');
      
      if (!granted && !finalStatus.isGranted) {
        // Check if it's actually permanently denied (trust final status)
        final isNowPermanentlyDenied = finalStatus.isPermanentlyDenied;
        debugPrint('[VaultHomePage] Camera permission now permanently denied: $isNowPermanentlyDenied');
        
        if (isNowPermanentlyDenied && mounted) {
          final shouldOpen = await _showPermissionDialog(
            title: 'Camera Access Needed',
            message: 'To capture photos, Nyx needs access to your camera.\n\nPlease enable camera access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Turn on "Camera"\n\nThen return to the app to continue.',
          );
          
          if (shouldOpen == true) {
            await _permissionService.openSettings();
          }
    } else {
          // Permission is just denied (not permanently), let image_picker try to request it
          // image_picker has its own permission handling that might work better
          debugPrint('[VaultHomePage] Camera permission denied but not permanently - letting image_picker handle permission request...');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Camera permission is required. Please grant permission when prompted.'),
                backgroundColor: AppTheme.warning,
                duration: Duration(seconds: 2),
              ),
            );
          }
        }
      }
      
      // Try to proceed with camera - image_picker will handle permission request if needed
      debugPrint('[VaultHomePage] Proceeding with image picker (will handle permissions if needed)...');
      
      try {
        final image = await _imagePicker.pickImage(
          source: ImageSource.camera,
          imageQuality: 100,
        );
        
        if (image != null && mounted) {
          debugPrint('[VaultHomePage] Image captured successfully: ${image.path}');
          // Show importing status for camera captures
                  setState(() {
            _isImporting = true;
            _importStatus = 'Saving photo...';
            _importProgress = 0;
            _importTotal = 1;
          });
          
          await _importFileToVault(
            File(image.path),
            VaultItemSource.camera,
          );
          
                setState(() {
            _isImporting = false;
            _importProgress = 0;
            _importTotal = 0;
            _importStatus = null;
          });
        } else {
          debugPrint('[VaultHomePage] No image captured - image_picker returned null');
          // Check permission status again after image_picker attempt
          final postPickerStatus = await Permission.camera.status;
          debugPrint('[VaultHomePage] Camera permission after image_picker: $postPickerStatus');
          debugPrint('[VaultHomePage] Camera permission - granted: ${postPickerStatus.isGranted}, denied: ${postPickerStatus.isDenied}, permanentlyDenied: ${postPickerStatus.isPermanentlyDenied}');
          
          if (!postPickerStatus.isGranted && mounted) {
            // Permission still not granted - might need to show a message
            if (postPickerStatus.isPermanentlyDenied) {
              final shouldOpen = await _showPermissionDialog(
                title: 'Camera Access Needed',
                message: 'To capture photos, Nyx needs access to your camera.\n\nPlease enable camera access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Turn on "Camera"\n\nThen return to the app to continue.',
              );
              
              if (shouldOpen == true) {
                await _permissionService.openSettings();
              }
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Camera permission was not granted. Please try again and allow camera access when prompted.'),
                  backgroundColor: AppTheme.warning,
                  duration: Duration(seconds: 3),
                ),
              );
            }
          }
        }
      } catch (e, stackTrace) {
        debugPrint('[VaultHomePage] Error from image_picker: $e');
        debugPrint('[VaultHomePage] Stack trace: $stackTrace');
        
        // Check permission status after error
        final errorStatus = await Permission.camera.status;
        debugPrint('[VaultHomePage] Camera permission after error: $errorStatus');
        
        if (mounted) {
          final errorMessage = e.toString().toLowerCase();
          
          // Check if error is about camera not being available (common on simulator)
          if (errorMessage.contains('camera not available') || 
              errorMessage.contains('camera unavailable') ||
              errorMessage.contains('no camera')) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'Camera is not available. If you\'re using a simulator, please test on a physical device. Otherwise, ensure your device has a working camera.',
                ),
                backgroundColor: AppTheme.warning,
                duration: const Duration(seconds: 4),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error accessing camera: ${e.toString()}'),
                backgroundColor: AppTheme.warning,
                duration: const Duration(seconds: 3),
              ),
            );
          }
        }
      }
    } catch (e, stackTrace) {
      debugPrint('[VaultHomePage] Error capturing photo: $e');
      debugPrint('[VaultHomePage] Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error capturing photo: ${e.toString()}'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }
  
  Future<void> _recordVideo() async {
    try {
      debugPrint('[VaultHomePage] === Starting video recording ===');
      
      // Check current permission status
      final cameraStatus = await Permission.camera.status;
      debugPrint('[VaultHomePage] Camera permission status: $cameraStatus');
      
      // Check if permission is permanently denied
      final cameraPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.camera);
      debugPrint('[VaultHomePage] Camera permanently denied: $cameraPermanentlyDenied');
      
      if (cameraPermanentlyDenied) {
        if (mounted) {
          final message = 'To record videos, Nyx needs access to your camera.\n\nPlease enable camera access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Turn on "Camera"\n\nThen return to the app to continue.';
          
          final shouldOpen = await _showPermissionDialog(
            title: 'Permissions Needed',
            message: message,
          );
          
          if (shouldOpen == true) {
            await _permissionService.openSettings();
          }
        }
        return;
      }
      
      // Request permission
      debugPrint('[VaultHomePage] Requesting camera permission...');
      final cameraGranted = await _permissionService.requestCameraPermission();
      debugPrint('[VaultHomePage] Camera permission granted: $cameraGranted');
      
      // Check final status after request
      final finalCameraStatus = await Permission.camera.status;
      debugPrint('[VaultHomePage] Final camera status: $finalCameraStatus');
      
      // Check if permission became permanently denied after request
      final cameraNowPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.camera);
      
      if (cameraNowPermanentlyDenied) {
        if (mounted) {
          final message = 'To record videos, Nyx needs access to your camera.\n\nPlease enable camera access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Turn on "Camera"\n\nThen return to the app to continue.';
          
          final shouldOpen = await _showPermissionDialog(
            title: 'Permissions Needed',
            message: message,
          );
          
          if (shouldOpen == true) {
            await _permissionService.openSettings();
          }
        }
        return;
      }
      
      // Check if permission is granted (use final status as well)
      final finalCameraGranted = cameraGranted || finalCameraStatus.isGranted;
      
      // Check if permission is permanently denied (trust final status)
      final cameraIsPermanentlyDenied = finalCameraStatus.isPermanentlyDenied;
      
      if (!finalCameraGranted) {
        if (cameraIsPermanentlyDenied) {
          // Show settings dialog if permanently denied
          if (mounted) {
            final message = 'To record videos, Nyx needs access to your camera.\n\nPlease enable camera access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Turn on "Camera"\n\nThen return to the app to continue.';
            
            final shouldOpen = await _showPermissionDialog(
              title: 'Permissions Needed',
              message: message,
            );
            
            if (shouldOpen == true) {
              await _permissionService.openSettings();
            }
          }
          return;
        } else {
          // Permission is just denied (not permanently), let image_picker try
          debugPrint('[VaultHomePage] Permission denied but not permanently - letting image_picker handle permission request...');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Camera permission is required. Please grant permission when prompted.'),
                backgroundColor: AppTheme.warning,
                duration: Duration(seconds: 2),
              ),
            );
          }
        }
      }
      
      // Try to proceed with video recording - image_picker will handle permission request if needed
      debugPrint('[VaultHomePage] Proceeding with video picker (will handle permissions if needed)...');
      
      try {
        final video = await _imagePicker.pickVideo(
          source: ImageSource.camera,
        );
        
        if (video != null && mounted) {
          debugPrint('[VaultHomePage] Video recorded successfully: ${video.path}');
          // Show importing status for camera recordings
              setState(() {
            _isImporting = true;
            _importStatus = 'Saving video...';
            _importProgress = 0;
            _importTotal = 1;
          });
          
          await _importFileToVault(
            File(video.path),
            VaultItemSource.camera,
          );
          
          setState(() {
            _isImporting = false;
            _importProgress = 0;
            _importTotal = 0;
            _importStatus = null;
          });
        } else {
          debugPrint('[VaultHomePage] No video recorded - image_picker returned null');
          // Check permission status again after image_picker attempt
          final postPickerCameraStatus = await Permission.camera.status;
          debugPrint('[VaultHomePage] Camera permission after image_picker: $postPickerCameraStatus');
          
          if (!postPickerCameraStatus.isGranted && mounted) {
            if (postPickerCameraStatus.isPermanentlyDenied) {
              final message = 'To record videos, Nyx needs access to your camera.\n\nPlease enable camera access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Turn on "Camera"\n\nThen return to the app to continue.';
              
              final shouldOpen = await _showPermissionDialog(
                title: 'Permissions Needed',
                message: message,
              );
              
              if (shouldOpen == true) {
                await _permissionService.openSettings();
              }
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Camera permission was not granted. Please try again and allow camera access when prompted.'),
                  backgroundColor: AppTheme.warning,
                  duration: Duration(seconds: 3),
                ),
              );
            }
          }
        }
      } catch (e, stackTrace) {
        debugPrint('[VaultHomePage] Error from image_picker: $e');
        debugPrint('[VaultHomePage] Stack trace: $stackTrace');
        
        // Check permission status after error
        final errorCameraStatus = await Permission.camera.status;
        debugPrint('[VaultHomePage] Camera permission after error: $errorCameraStatus');
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error accessing camera: ${e.toString()}'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
    } catch (e, stackTrace) {
      debugPrint('[VaultHomePage] Error recording video: $e');
      debugPrint('[VaultHomePage] Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error recording video: ${e.toString()}'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }
  
  Future<void> _importPhotos() async {
    try {
      debugPrint('[VaultHomePage] === Starting photo import ===');
      bool queuedImports = false;
      
      // Check if permission is permanently denied
      final isPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.photos);
      debugPrint('[VaultHomePage] Photo library permission permanently denied: $isPermanentlyDenied');
      
      if (isPermanentlyDenied) {
        if (mounted) {
          final shouldOpen = await _showPermissionDialog(
            title: 'Photo Library Access Needed',
            message: 'To import photos, Nyx needs access to your photo library.\n\nPlease enable photo library access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Tap "Photos"\n4. Select "All Photos" or "Selected Photos"\n\nThen return to the app to continue.',
          );
          
          if (shouldOpen == true) {
            await _permissionService.openSettings();
          }
        }
        return;
      }
      
      // Request photo library permission
      debugPrint('[VaultHomePage] Requesting photo library permission...');
      final granted = await _permissionService.requestPhotoLibraryPermission();
      debugPrint('[VaultHomePage] Photo library permission granted: $granted');
      
      if (!granted) {
        // Check if it became permanently denied after request
        final isNowPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.photos);
        debugPrint('[VaultHomePage] Photo library permission now permanently denied: $isNowPermanentlyDenied');
        
        if (isNowPermanentlyDenied && mounted) {
          final shouldOpen = await _showPermissionDialog(
            title: 'Photo Library Access Needed',
            message: 'To import photos, Nyx needs access to your photo library.\n\nPlease enable photo library access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Tap "Photos"\n4. Select "All Photos" or "Selected Photos"\n\nThen return to the app to continue.',
          );
          
          if (shouldOpen == true) {
            await _permissionService.openSettings();
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Photo library permission is required'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }
      
      setState(() {
        _isImporting = true;
        _importProgress = 0;
        _importTotal = 0;
        _importStatus = 'Selecting photos...';
      });

      // Yield to UI thread before opening file picker
      await Future.delayed(const Duration(milliseconds: 100));

      // Pick multiple photos from gallery
      // Note: image_picker doesn't support multi-photo pick, so we use file picker
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
      );
      
      // Yield after file picker closes
      await Future.delayed(const Duration(milliseconds: 50));

      if (result != null && result.files.isNotEmpty) {
        final photoFiles = result.files.where((f) => f.path != null).toList();
        
        // Initialize background import service
        _initBackgroundImportService();
        
        // Check subscription limits before queuing
        final vaultService = Provider.of<VaultService>(context, listen: false);
        final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
        final hasPremium = subscriptionService.currentTier.isUnlimited || subscriptionService.isInTrial;
        
        if (!hasPremium) {
          final currentItemCount = vaultService.items.length;
          final maxItems = subscriptionService.currentTier.maxItems;
          
          if (currentItemCount + photoFiles.length > maxItems) {
            if (mounted) {
              _showPaywall();
            }
            return;
          }
        }
        
        // Create import tasks
        final importTasks = photoFiles.map((platformFile) {
          return ImportTask(
            filePath: platformFile.path!,
            filename: platformFile.path!.split('/').last,
            mimeType: 'image/${platformFile.extension ?? 'jpg'}',
            source: VaultItemSource.import,
            deleteOriginal: false,
            folderId: _currentFolderId, // Store in current folder if inside a folder
          );
        }).toList();
        
        // Queue imports for background processing
        await _backgroundImportService!.queueImports(importTasks);
        queuedImports = true;
        
        // Update UI to show import started
        if (mounted) {
          setState(() {
            _isImporting = true;
            _importTotal = photoFiles.length;
            _importProgress = 0;
            _importStatus = 'Queued ${photoFiles.length} photo(s) for import...';
          });
        }
      }
      
      // IMPORTANT: Don't clear importing state after queuing.
      // The background import progress stream drives the progress UI until completion.
      if (!queuedImports && mounted) {
        setState(() {
          _isImporting = false;
          _importProgress = 0;
          _importTotal = 0;
          _importStatus = null;
        });
      }
    } catch (e) {
      debugPrint('[VaultHomePage] Error importing photos: $e');
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importProgress = 0;
          _importTotal = 0;
          _importStatus = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error importing photos: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }

  Future<void> _importVideos() async {
    try {
      // Check if permission is permanently denied
      final isPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.photos);
      
      if (isPermanentlyDenied) {
        if (mounted) {
          final shouldOpen = await _showPermissionDialog(
            title: 'Photo Library Access Needed',
            message: 'To import videos, Nyx needs access to your photo library.\n\nPlease enable photo library access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Tap "Photos"\n4. Select "All Photos" or "Selected Photos"\n\nThen return to the app to continue.',
          );
          
          if (shouldOpen == true) {
            await _permissionService.openSettings();
          }
        }
        return;
      }
      
      // Request photo library permission
      final granted = await _permissionService.requestPhotoLibraryPermission();
      
      if (!granted) {
        // Check if it became permanently denied after request
        final isNowPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.photos);
        if (isNowPermanentlyDenied && mounted) {
          final shouldOpen = await _showPermissionDialog(
            title: 'Photo Library Access Needed',
            message: 'To import videos, Nyx needs access to your photo library.\n\nPlease enable photo library access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Tap "Photos"\n4. Select "All Photos" or "Selected Photos"\n\nThen return to the app to continue.',
          );
          
          if (shouldOpen == true) {
            await _permissionService.openSettings();
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Photo library permission is required'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      return;
    }
    
      // iOS: use Photos-native picker to avoid FilePicker hangs.
      if (Platform.isIOS) {
        if (mounted) {
          setState(() {
            _isImporting = true;
            _importProgress = 0;
            _importTotal = 0;
            _importStatus = 'Selecting videos...';
          });
        }
        await _importVideosIOS();
        return;
      }

      // Android/others: keep using FilePicker.
      // Show immediate feedback so multi-select doesn't feel unresponsive.
      if (mounted) {
        setState(() {
          _isImporting = true;
          _importProgress = 0;
          _importTotal = 0;
          _importStatus = 'Selecting videos...';
        });
      }

      // Use FilePicker. We keep the UI banner visible while the picker is open.
      // Guard against iOS providers that can hang indefinitely while resolving selected items.
      var pickerTimedOut = false;
      final result = await FilePicker.platform
          .pickFiles(
            allowMultiple: true,
            type: FileType.video,
            // On iOS, this uses the native picker which is optimized
            // The delay was likely from FilePicker loading metadata, but we can't control that
            // However, removing our artificial delays helps
          )
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () {
              pickerTimedOut = true;
              return null;
            },
          );
      
      if (result != null && result.files.isNotEmpty) {
        final pickedFiles = result.files;
        final directPathFiles = <PlatformFile>[];
        int missingAccessCount = 0;

        for (final f in pickedFiles) {
          final p = f.path;
          if (p != null && p.isNotEmpty) {
            directPathFiles.add(f);
          } else {
            missingAccessCount++;
          }
        }

        final totalImportable = directPathFiles.length;
        if (totalImportable == 0) {
          if (mounted) {
            setState(() {
              _isImporting = false;
              _importProgress = 0;
              _importTotal = 0;
              _importStatus = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Could not access the selected videos for import. '
                  'If they are in iCloud, download them first (open in Photos), then try again.',
                ),
                backgroundColor: AppTheme.warning,
                duration: Duration(seconds: 4),
              ),
            );
          }
          return;
        }
        
        // Immediately show UI feedback that a multi-select happened.
        // Also yield a frame so the banner renders before any further work.
        setState(() {
          _isImporting = true;
          _importProgress = 0;
          _importTotal = totalImportable;
          _importStatus = missingAccessCount > 0
              ? 'Selected $totalImportable video(s) (skipped $missingAccessCount)...'
              : 'Selected $totalImportable video(s)...';
        });
        await Future.delayed(const Duration(milliseconds: 16));
        if (mounted) {
          setState(() {
            _importStatus = 'Queuing $totalImportable video(s) for import...';
          });
        }
        
        // Initialize background import service
        _initBackgroundImportService();
        
        // Check subscription limits
        final vaultService = Provider.of<VaultService>(context, listen: false);
        final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
        final hasPremium = subscriptionService.currentTier.isUnlimited || subscriptionService.isInTrial;
        
        if (!hasPremium) {
          final currentItemCount = vaultService.items.length;
          final maxItems = subscriptionService.currentTier.maxItems;
          
          if (currentItemCount + totalImportable > maxItems) {
            if (mounted) {
              setState(() {
                _isImporting = false;
                _importStatus = null;
              });
              _showPaywall();
            }
            return;
          }
        }
        
        // Create import tasks (direct paths + temp paths for stream-only items).
        final importTasks = <ImportTask>[
          for (final platformFile in directPathFiles)
            ImportTask(
              filePath: platformFile.path!,
              filename: platformFile.path!.split('/').last,
              mimeType: 'video/${platformFile.extension ?? 'mp4'}',
              source: VaultItemSource.import,
              deleteOriginal: false,
              folderId: _currentFolderId,
            ),
        ];
        
        // Queue imports for background processing
        await _backgroundImportService!.queueImports(importTasks);
        
        // Update UI to show import started
        if (mounted) {
          setState(() {
            _isImporting = true;
            _importTotal = totalImportable;
            _importProgress = 0;
            _importStatus = 'Queued $totalImportable video(s) for import...';
          });
        }
      } else {
        // User cancelled (or picker timed out) - clear loading state
        if (mounted) {
          setState(() {
            _isImporting = false;
            _importStatus = null;
          });
          if (pickerTimedOut) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Video picker is taking too long to load the selected items. '
                  'Try selecting fewer videos, or download them from iCloud first (open in Photos), then try again.',
                ),
                backgroundColor: AppTheme.warning,
                duration: Duration(seconds: 5),
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[VaultHomePage] Error importing videos: $e');
    if (mounted) {
        setState(() {
          _isImporting = false;
          _importProgress = 0;
          _importTotal = 0;
          _importStatus = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error importing videos: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }

  Future<void> _importFiles() async {
    try {
      debugPrint('[VaultHomePage] === Starting file import ===');
      
      setState(() {
        _isImporting = true;
        _importProgress = 0;
        _importTotal = 0;
        _importStatus = 'Selecting files...';
      });
      
      // On iOS, FilePicker handles permissions automatically
      // On Android, request storage permission if needed
      if (Platform.isAndroid) {
        debugPrint('[VaultHomePage] Android platform - checking storage permission...');
        final isPermanentlyDenied = await _permissionService.isPermanentlyDenied(Permission.storage);
        
        if (isPermanentlyDenied) {
          if (mounted) {
            final shouldOpen = await _showPermissionDialog(
              title: 'Storage Access Needed',
              message: 'To import files, Nyx needs access to your storage.\n\nPlease enable storage access in Settings:\n\n1. Open Settings\n2. Tap "Nyx"\n3. Turn on "Storage"\n\nThen return to the app to continue.',
            );
            
            if (shouldOpen == true) {
              await _permissionService.openSettings();
            }
          }
          setState(() {
            _isImporting = false;
          });
      return;
    }
    
        // Request storage permission
        debugPrint('[VaultHomePage] Requesting storage permission...');
        final granted = await _permissionService.requestPhotoLibraryAddPermission();
        debugPrint('[VaultHomePage] Storage permission granted: $granted');
        
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Storage permission is required'),
                backgroundColor: AppTheme.warning,
              ),
            );
          }
          setState(() {
            _isImporting = false;
          });
          return;
        }
      } else {
        debugPrint('[VaultHomePage] iOS platform - FilePicker handles permissions automatically');
      }
      
      // Yield to UI thread before opening file picker
      await Future.delayed(const Duration(milliseconds: 100));
      
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any, // Support all file types
      );
      
      // Yield after file picker closes
      await Future.delayed(const Duration(milliseconds: 50));
      
      if (result != null && result.files.isNotEmpty) {
        final files = result.files.where((f) => f.path != null).toList();
        
        // Initialize background import service
        _initBackgroundImportService();
        
        // Check subscription limits
        final vaultService = Provider.of<VaultService>(context, listen: false);
        final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
        final hasPremium = subscriptionService.currentTier.isUnlimited || subscriptionService.isInTrial;
        
        if (!hasPremium) {
          final currentItemCount = vaultService.items.length;
          final maxItems = subscriptionService.currentTier.maxItems;
          
          if (currentItemCount + files.length > maxItems) {
            if (mounted) {
              _showPaywall();
            }
            return;
          }
        }
        
        // Create import tasks
        final importTasks = files.map((platformFile) {
          return ImportTask(
            filePath: platformFile.path!,
            filename: platformFile.path!.split('/').last,
            mimeType: platformFile.extension != null 
                ? _getMimeTypeFromExtension(platformFile.extension!)
                : null,
            source: VaultItemSource.import,
            deleteOriginal: false,
            folderId: _currentFolderId, // Store in current folder if inside a folder
          );
        }).toList();
        
        // Queue imports for background processing
        await _backgroundImportService!.queueImports(importTasks);
        
        // Update UI to show import started
        if (mounted) {
          setState(() {
            _isImporting = true;
            _importTotal = files.length;
            _importProgress = 0;
            _importStatus = 'Queued ${files.length} file(s) for import...';
          });
        }
      }
    } catch (e) {
      debugPrint('[VaultHomePage] Error importing files: $e');
      if (mounted) {
        setState(() {
          _isImporting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error importing files: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }
  }
  
  Future<void> _importFileToVault(
    File file, 
    VaultItemSource source, {
    String? mimeType,
  }) async {
    if (!await file.exists()) {
      throw Exception('File does not exist');
    }
    
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
    
    // Check free tier limit
    final hasPremium = subscriptionService.currentTier.isUnlimited || subscriptionService.isInTrial;
    if (!hasPremium) {
      final currentItemCount = vaultService.items.length;
      final maxItems = subscriptionService.currentTier.maxItems;
      
      if (currentItemCount >= maxItems) {
        // Show paywall when limit reached
        if (mounted) {
          _showPaywall();
        }
        return;
      }
    }
    
    final filename = file.path.split('/').last;
    // CRITICAL: Never read whole files into RAM (videos can crash iOS).
    // Use path-based streaming copy.
    final storedItem = await vaultService.storeFileFromPath(
      sourceFilePath: file.path,
      filename: filename,
      mimeType: mimeType,
      source: source,
      folderId: _currentFolderId, // Store in current folder if inside a folder
      // Avoid native thumbnail extraction during capture/import on iOS (can crash for some codecs).
      queueThumbnailGeneration: !Platform.isIOS,
    );

    // On non-iOS platforms, ensure videos get a poster thumbnail.
    if (!Platform.isIOS && storedItem.type == VaultItemType.video) {
      try {
        await vaultService.generateThumbnailForItem(storedItem.id);
      } catch (e) {
        debugPrint('[VaultHomePage] Error generating video thumbnail: $e');
      }
    }
    
    // Delete the original file after importing (for camera captures)
    if (source == VaultItemSource.camera) {
      try {
        await file.delete();
      } catch (e) {
        debugPrint('[VaultHomePage] Error deleting original file: $e');
      }
    }
  }
  
  String? _getMimeTypeFromExtension(String extension) {
    final ext = extension.toLowerCase();
    final mimeTypes = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'avi': 'video/x-msvideo',
      'mkv': 'video/x-matroska',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'aac': 'audio/aac',
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'zip': 'application/zip',
      'rar': 'application/x-rar-compressed',
    };
    return mimeTypes[ext];
  }
  
  /// Show permission dialog helper
  Future<bool?> _showPermissionDialog({required String title, required String message}) async {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: Text(
          title,
          style: const TextStyle(color: AppTheme.text),
        ),
        content: Text(
          message,
          style: const TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.accent,
            ),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }
}

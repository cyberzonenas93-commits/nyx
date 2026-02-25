import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../../../app/theme.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/vault_service.dart';
import '../../../core/services/subscription_service.dart';
import '../../../core/models/subscription_tier.dart';
import '../../../core/models/app_state.dart';
import '../../../core/models/vault_item.dart';
import '../../../shared/widgets/pin_verification_dialog.dart';
import '../../../features/subscription/pages/paywall_page.dart';
import '../../../features/unlock/pages/pin_setup_page.dart';
import '../../settings/pages/security_page.dart';
import '../../../core/services/multi_vault_service.dart';
import 'vault_management_page.dart';

/// Vault settings page accessible from within the vault
class VaultSettingsPage extends StatefulWidget {
  const VaultSettingsPage({super.key});
  
  @override
  State<VaultSettingsPage> createState() => _VaultSettingsPageState();
}

class _VaultSettingsPageState extends State<VaultSettingsPage> {
  String? _unlockTriggerCode;
  bool _isLoadingTriggerCode = true;

  @override
  void initState() {
    super.initState();
    _loadUnlockTriggerCode();
  }

  Future<void> _loadUnlockTriggerCode() async {
    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final code = await authService.getUnlockTriggerCode();
      if (mounted) {
        Future.microtask(() {
          if (mounted) {
            setState(() {
              _unlockTriggerCode = code;
              _isLoadingTriggerCode = false;
            });
          }
        });
      }
    } catch (e) {
      debugPrint('[VaultSettingsPage] Error loading trigger code: $e');
      if (mounted) {
        Future.microtask(() {
          if (mounted) {
            setState(() {
              _isLoadingTriggerCode = false;
            });
          }
        });
      }
    }
  }
  
  Future<void> _changePIN() async {
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text('Change PIN?'),
          content: const Text(
            'You will need to enter your current PIN and then set a new PIN. Your vault will be re-encrypted with the new PIN.',
            style: TextStyle(color: AppTheme.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.accent,
              ),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      
      if (confirmed == true && mounted) {
        // Verify current PIN first
        final verifiedPIN = await PinVerificationDialog.show(context);
        
        if (verifiedPIN == null || verifiedPIN.isEmpty) {
          return; // User cancelled
        }
        
        if (!mounted) return;
        
        final authService = Provider.of<AuthService>(context, listen: false);
        final result = await authService.verifyPIN(verifiedPIN);
        
        if (!mounted) return;
        
        if (result != AuthResult.unlocked) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Incorrect PIN'),
              backgroundColor: AppTheme.warning,
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        
        if (!mounted) return;
        
        // Navigate to PIN setup page for changing PIN
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => const PinSetupPage(isChangeMethod: true),
          ),
        );
      }
    } catch (e) {
      debugPrint('[VaultSettingsPage] Error changing PIN: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: AppTheme.warning,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _changeUnlockTriggerCode() async {
    try {
      final result = await showDialog<String>(
        context: context,
        builder: (context) => _UnlockTriggerCodeDialog(currentCode: _unlockTriggerCode),
      );

      if (result != null && result.isNotEmpty && mounted) {
        final authService = Provider.of<AuthService>(context, listen: false);
        final success = await authService.setUnlockTriggerCode(result);

        if (!mounted) return;

        if (success) {
          await _loadUnlockTriggerCode();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Unlock trigger code updated'),
                backgroundColor: AppTheme.accent,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Invalid code. Code must contain only numbers and cannot start with 0.'),
                backgroundColor: AppTheme.warning,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[VaultSettingsPage] Error changing trigger code: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: AppTheme.warning,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  
  Future<void> _manageSubscription() async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const PaywallPage(showCloseButton: true),
      ),
    );
  }

  Future<void> _generateVideoPostersSafe() async {
    final vaultService = Provider.of<VaultService>(context, listen: false);

    int skippedUnsafe = 0;
    final candidates = <VaultItem>[];

    for (final item in vaultService.items) {
      if (item.type != VaultItemType.video) continue;

      final existingThumbPath = vaultService.getThumbnailPath(item.id);
      if (existingThumbPath != null && File(existingThumbPath).existsSync()) continue;

      final filePath = vaultService.getFilePath(item.id);
      if (filePath == null) continue;
      final f = File(filePath);
      if (!f.existsSync()) continue;

      if (Platform.isIOS) {
        final lower = filePath.toLowerCase();
        final isCommonContainer = lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.m4v');
        if (!isCommonContainer) {
          skippedUnsafe++;
          continue;
        }
        final size = await f.length().catchError((_) => 0);
        if (size > 300 * 1024 * 1024) {
          skippedUnsafe++;
          continue;
        }
      }

      candidates.add(item);
    }

    if (candidates.isEmpty) {
      if (!mounted) return;
      final msg = skippedUnsafe > 0
          ? 'No safe video posters to generate. Skipped $skippedUnsafe unsafe video(s).'
          : 'No missing video posters found.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: AppTheme.accent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    BuildContext? dialogContext;
    int done = 0;
    String currentName = candidates.first.displayName;
    bool cancelled = false;
    bool dialogOpen = true;

    void Function(void Function())? setDialogStateRef;
    final dialogReady = Completer<void>();

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            setDialogStateRef ??= (fn) => setDialogState(fn);
            if (!dialogReady.isCompleted) dialogReady.complete();

            final total = candidates.length;
            final progress = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
            return AlertDialog(
              backgroundColor: AppTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
              ),
              title: const Text(
                'Generating Posters',
                style: TextStyle(color: AppTheme.text),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: progress,
                    backgroundColor: AppTheme.text.withOpacity(0.15),
                    color: AppTheme.accent,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '$done / $total',
                    style: TextStyle(color: AppTheme.text.withOpacity(0.8)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    currentName,
                    style: TextStyle(color: AppTheme.text.withOpacity(0.7), fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (Platform.isIOS) ...[
                    const SizedBox(height: 10),
                    Text(
                      'iOS safe mode: only MP4/MOV/M4V ≤ 300MB.',
                      style: TextStyle(color: AppTheme.text.withOpacity(0.5), fontSize: 11),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelled = true;
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('Stop'),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() {
      dialogOpen = false;
    });

    await dialogReady.future;

    for (final item in candidates) {
      if (cancelled) break;
      setDialogStateRef?.call(() {
        currentName = item.displayName;
      });

      try {
        await vaultService.generateThumbnailForItem(item.id);
      } catch (e) {
        debugPrint('[VaultSettingsPage] Poster generation failed for ${item.id}: $e');
      }

      done++;
      setDialogStateRef?.call(() {});
    }

    if (dialogOpen && dialogContext != null && Navigator.of(dialogContext!).canPop()) {
      Navigator.of(dialogContext!).pop();
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cancelled
              ? 'Stopped. Generated $done poster(s).'
              : 'Generated $done poster(s).',
        ),
        backgroundColor: AppTheme.accent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  
  Future<void> _wipeData() async {
    // First confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text(
          'Wipe All Data?',
          style: TextStyle(color: AppTheme.warning),
        ),
        content: const Text(
          'This will permanently delete ALL files in your vault. This action cannot be undone.\n\n'
          'You will need to enter your PIN to confirm.',
          style: TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.warning,
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    
    if (confirmed != true) return;
    
    // PIN verification
    final verifiedPIN = await PinVerificationDialog.show(context);
    
    if (verifiedPIN == null || verifiedPIN.isEmpty) {
      return; // User cancelled
    }
    
    final authService = Provider.of<AuthService>(context, listen: false);
    final result = await authService.verifyPIN(verifiedPIN);
    
    if (!mounted) return;
    
    if (result != AuthResult.unlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Incorrect PIN. Data wipe cancelled.'),
          backgroundColor: AppTheme.warning,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    
    // Final confirmation
    final finalConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text(
          'Final Confirmation',
          style: TextStyle(color: AppTheme.warning),
        ),
        content: const Text(
          'Are you absolutely sure you want to delete ALL files in your vault?\n\n'
          'This action is PERMANENT and CANNOT be undone.',
          style: TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.warning,
            ),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    
    if (finalConfirm != true) return;
    
    // Show loading indicator
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: AppTheme.accent),
      ),
    );
    
    // Wipe all vault data
    final vaultService = Provider.of<VaultService>(context, listen: false);
    final allItems = vaultService.items;
    
    // Delete all items
    for (final item in allItems) {
      await vaultService.deleteItem(item.id);
    }
    
    // Close loading dialog
    if (mounted) {
      Navigator.of(context).pop();
    }
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All vault data has been wiped'),
          backgroundColor: AppTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
      
      // Pop settings page to return to vault
      Navigator.of(context).pop();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final subscriptionService = Provider.of<SubscriptionService>(context);
    final currentTier = subscriptionService.currentTier;
    
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('Vault Settings'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // PIN & Security Section
          _buildSection(
            title: 'Security',
            children: [
              ListTile(
                leading: const Icon(
                  Icons.lock_outline,
                  color: AppTheme.accent,
                ),
                title: const Text(
                  'Change PIN',
                  style: TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  'Update your 6-digit PIN',
                  style: TextStyle(
                    color: AppTheme.text.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: AppTheme.text.withOpacity(0.4),
                ),
                onTap: _changePIN,
              ),
              
              const Divider(height: 1),

              ListTile(
                leading: const Icon(Icons.vpn_key, color: AppTheme.accent),
                title: const Text(
                  'Unlock code',
                  style: TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  _isLoadingTriggerCode
                      ? 'Loading...'
                      : (_unlockTriggerCode != null
                          ? 'Current: $_unlockTriggerCode'
                          : 'Optional code (PIN used on unlock screen)'),
                  style: TextStyle(
                    color: AppTheme.text.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: AppTheme.text.withOpacity(0.4),
                ),
                onTap: _changeUnlockTriggerCode,
              ),

              const Divider(height: 1),
              
              ListTile(
                leading: const Icon(Icons.security, color: AppTheme.accent),
                title: const Text(
                  'Security Settings',
                  style: TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  'Panic switch and more',
                  style: TextStyle(
                    color: AppTheme.text.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: AppTheme.text.withOpacity(0.4),
                ),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const SecurityPage(),
                    ),
                  );
                },
              ),
            ],
          ),
          
          const SizedBox(height: 24),

          // Multiple Vaults Section (only in primary vault)
          Consumer<MultiVaultService>(
            builder: (context, multiVaultService, _) {
              final authService = Provider.of<AuthService>(context, listen: false);
              // Show if unlocked and currentVaultId is null (primary vault)
              // currentVaultId is null when in primary vault, non-null for secondary vaults
              final isPrimaryVault =
                  authService.appState == AppState.unlocked && authService.currentVaultId == null;

              if (!isPrimaryVault) {
                return const SizedBox.shrink();
              }

              return Column(
                children: [
                  _buildSection(
                    title: 'Multiple Vaults',
                    children: [
                      ListTile(
                        leading: const Icon(Icons.folder_special, color: AppTheme.accent),
                        title: const Text(
                          'Manage Vaults',
                          style: TextStyle(
                            color: AppTheme.text,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: Text(
                          '${multiVaultService.vaultCount} vault${multiVaultService.vaultCount != 1 ? 's' : ''} (${multiVaultService.maxVaults} max)',
                          style: TextStyle(
                            color: AppTheme.text.withOpacity(0.6),
                            fontSize: 12,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: AppTheme.text.withOpacity(0.4),
                        ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const VaultManagementPage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              );
            },
          ),

          // Storage Section
          _buildSection(
            title: 'Storage',
            children: [
              _StorageSettingsTile(),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.image_outlined, color: AppTheme.accent),
                title: const Text(
                  'Generate Video Posters (Safe)',
                  style: TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  Platform.isIOS
                      ? 'Creates first-frame posters for MP4/MOV/M4V videos ≤ 300MB'
                      : 'Creates first-frame posters for videos missing thumbnails',
                  style: TextStyle(
                    color: AppTheme.text.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: AppTheme.text.withOpacity(0.4),
                ),
                onTap: _generateVideoPostersSafe,
              ),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // Subscription Section
          _buildSection(
            title: 'Subscription',
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          currentTier.isUnlimited
                              ? Icons.star
                              : Icons.star_outline,
                          color: currentTier.isUnlimited
                              ? AppTheme.accent
                              : AppTheme.text.withOpacity(0.6),
                          size: 32,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                currentTier.displayName,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.text,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                currentTier.isUnlimited
                                    ? 'Unlimited Storage'
                                    : '${currentTier.maxItems} Items Maximum',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.text.withOpacity(0.7),
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
              
              const Divider(height: 1),
              
              ListTile(
                leading: const Icon(Icons.card_membership, color: AppTheme.accent),
                title: const Text(
                  'Manage Subscription',
                  style: TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  currentTier.isUnlimited
                      ? 'Cancel or change your plan'
                      : 'Upgrade to unlimited storage',
                  style: TextStyle(
                    color: AppTheme.text.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: AppTheme.text.withOpacity(0.4),
                ),
                onTap: _manageSubscription,
              ),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // Danger Zone
          _buildSection(
            title: 'Danger Zone',
            children: [
              ListTile(
                leading: Icon(
                  Icons.delete_forever,
                  color: AppTheme.warning,
                ),
                title: const Text(
                  'Wipe All Data',
                  style: TextStyle(
                    color: AppTheme.warning,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: const Text(
                  'Permanently delete all files in vault',
                  style: TextStyle(
                    color: AppTheme.warning,
                    fontSize: 12,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: AppTheme.warning.withOpacity(0.6),
                ),
                onTap: _wipeData,
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              color: AppTheme.text.withOpacity(0.6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Card(
          color: AppTheme.surface,
          child: Column(
            children: children,
          ),
        ),
      ],
    );
  }
}

class _StorageSettingsTile extends StatefulWidget {
  const _StorageSettingsTile();
  
  @override
  State<_StorageSettingsTile> createState() => _StorageSettingsTileState();
}

class _StorageSettingsTileState extends State<_StorageSettingsTile> {
  bool? _useICloudStorage;
  bool _isLoading = true;
  
  @override
  void initState() {
    super.initState();
    _loadStoragePreference();
  }
  
  Future<void> _loadStoragePreference() async {
    try {
      final vaultService = Provider.of<VaultService>(context, listen: false);
      final preference = await vaultService.getStoragePreference();
      if (mounted) {
        setState(() {
          _useICloudStorage = preference;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[StorageSettings] Error loading storage preference: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _useICloudStorage = null; // Default to auto-detect on error
        });
      }
    }
  }
  
  String _getStorageSubtitle() {
    if (Platform.isAndroid) {
      return 'Local storage (Android)';
    }
    if (_useICloudStorage == null) {
      return 'Local storage (iCloud backup auto-enabled)';
    } else if (_useICloudStorage == true) {
      return 'Local storage + iCloud backup';
    } else {
      return 'Local storage only';
    }
  }
  
  bool _isStorageSelectionAvailable() {
    // Storage selection only available on iOS/macOS
    return Platform.isIOS || Platform.isMacOS;
  }
  
  Future<void> _showStorageDialog() async {
    final vaultService = Provider.of<VaultService>(context, listen: false);
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _StorageSelectionDialog(
        currentPreference: _useICloudStorage,
      ),
    );
    
    if (result != null && mounted) {
      bool? newPreference;
      if (result == 'icloud') {
        newPreference = true;
      } else if (result == 'local') {
        newPreference = false;
      } else {
        newPreference = null; // auto-detect
      }
      
      await vaultService.setStoragePreference(newPreference);
      
      setState(() {
        _useICloudStorage = newPreference;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Storage preference updated. iCloud backup will start automatically in the background.',
            ),
            backgroundColor: AppTheme.accent,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    // Add timeout to prevent infinite loading
    if (_isLoading) {
      // Set a timeout to prevent infinite loading
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted && _isLoading) {
          setState(() {
            _isLoading = false;
            _useICloudStorage = null; // Default to auto-detect
          });
        }
      });
      
      return const ListTile(
        leading: CircularProgressIndicator(
          color: AppTheme.accent,
          strokeWidth: 2,
        ),
        title: Text('Loading storage settings...'),
      );
    }
    
    return ListTile(
      leading: const Icon(Icons.storage, color: AppTheme.accent),
      title: const Text(
        'Vault Storage',
        style: TextStyle(
          color: AppTheme.text,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        _getStorageSubtitle(),
        style: TextStyle(
          color: AppTheme.text.withOpacity(0.6),
          fontSize: 12,
        ),
      ),
      trailing: _isStorageSelectionAvailable()
          ? Icon(
              Icons.chevron_right,
              color: AppTheme.text.withOpacity(0.4),
            )
          : null,
      onTap: _isStorageSelectionAvailable() ? _showStorageDialog : null,
    );
  }
}

class _StorageSelectionDialog extends StatelessWidget {
  final bool? currentPreference;
  
  const _StorageSelectionDialog({
    required this.currentPreference,
  });
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: const Text(
        'Vault Storage Location',
        style: TextStyle(
          color: AppTheme.text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.8,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StorageOption(
              title: 'Local + iCloud Backup',
              description: 'Files stored locally for fast access. Automatically backed up to iCloud in the background. Best of both worlds: performance and backup protection.',
              icon: Icons.cloud_sync,
              isSelected: currentPreference == true,
              onTap: () => Navigator.of(context).pop('icloud'),
            ),
            const SizedBox(height: 12),
            _StorageOption(
              title: 'Local Only',
              description: 'Fastest performance with local storage only. No iCloud backup. If your device is lost or damaged, your data cannot be recovered.',
              icon: Icons.phone_iphone,
              isSelected: currentPreference == false,
              onTap: () => Navigator.of(context).pop('local'),
            ),
            const SizedBox(height: 12),
            _StorageOption(
              title: 'Auto (Recommended)',
              description: 'Local storage with automatic iCloud backup if available. Optimal performance with backup protection. This is the default setting.',
              icon: Icons.auto_awesome,
              isSelected: currentPreference == null,
              onTap: () => Navigator.of(context).pop('auto'),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.accent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: AppTheme.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Note: Files are always stored locally first for best performance. iCloud is used for automatic backup in the background.',
                      style: TextStyle(
                        color: AppTheme.text.withOpacity(0.8),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _StorageOption extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  
  const _StorageOption({
    required this.title,
    required this.description,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected ? AppTheme.accent : AppTheme.text.withOpacity(0.2),
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
          color: isSelected ? AppTheme.accent.withOpacity(0.1) : Colors.transparent,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? AppTheme.accent : AppTheme.text.withOpacity(0.6),
              size: 32,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppTheme.text,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      color: AppTheme.text.withOpacity(0.7),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                color: AppTheme.accent,
                size: 24,
              ),
          ],
        ),
      ),
    );
  }
}

class _UnlockTriggerCodeDialog extends StatefulWidget {
  final String? currentCode;

  const _UnlockTriggerCodeDialog({this.currentCode});

  @override
  State<_UnlockTriggerCodeDialog> createState() => _UnlockTriggerCodeDialogState();
}

class _UnlockTriggerCodeDialogState extends State<_UnlockTriggerCodeDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.currentCode != null) {
      _controller.text = widget.currentCode!;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _validateAndSubmit() {
    final code = _controller.text.trim();

    if (code.isEmpty) {
      setState(() {
        _errorMessage = 'Code cannot be empty';
      });
      return;
    }

    if (!RegExp(r'^\d+$').hasMatch(code)) {
      setState(() {
        _errorMessage = 'Code must contain only numbers';
      });
      return;
    }

    if (code.startsWith('0')) {
      setState(() {
        _errorMessage = 'Code cannot start with 0. Please enter a code that starts with 1-9.';
      });
      return;
    }

    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: const Text(
        'Set Unlock Trigger Code',
        style: TextStyle(color: AppTheme.text),
      ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.8,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Optional code for this vault. Your PIN is used on the unlock screen to open your vault.',
              style: TextStyle(color: AppTheme.text),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppTheme.text),
              decoration: InputDecoration(
                labelText: 'Trigger Code',
                labelStyle: TextStyle(color: AppTheme.text.withOpacity(0.7)),
                hintText: 'e.g., 123456',
                hintStyle: TextStyle(color: AppTheme.text.withOpacity(0.4)),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppTheme.text.withOpacity(0.3)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: AppTheme.accent),
                ),
                errorText: _errorMessage,
              ),
              autofocus: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _validateAndSubmit,
          style: TextButton.styleFrom(
            foregroundColor: AppTheme.accent,
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

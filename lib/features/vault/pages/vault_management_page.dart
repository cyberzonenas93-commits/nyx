import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../app/theme.dart';
import '../../../core/services/multi_vault_service.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/vault_service.dart';
import '../../../core/models/vault_metadata.dart';
import '../../../shared/widgets/pin_verification_dialog.dart';
import '../../../shared/widgets/pattern_verification_dialog.dart';
import '../../../features/unlock/pages/pin_setup_page.dart';
import '../../../features/unlock/pages/pattern_setup_page.dart';
import 'vault_home_page.dart';

/// Page for managing multiple vaults (only accessible from primary vault)
class VaultManagementPage extends StatefulWidget {
  const VaultManagementPage({super.key});
  
  @override
  State<VaultManagementPage> createState() => _VaultManagementPageState();
}

class _VaultManagementPageState extends State<VaultManagementPage> {
  bool _isAuthenticated = false;
  bool _isVerifying = false;
  String? _errorMessage;
  bool _hasShownDialog = false;
  
  @override
  void initState() {
    super.initState();
    // Don't show dialog in initState - wait for didChangeDependencies
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Show PIN verification dialog after widget tree is built
    if (!_hasShownDialog && !_isAuthenticated && !_isVerifying) {
      _hasShownDialog = true;
      // Use post-frame callback to ensure context is fully available
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _verifyPrimaryVaultPIN();
        }
      });
    }
  }
  
  Future<void> _verifyPrimaryVaultPIN() async {
    try {
      if (mounted) {
        setState(() {
          _isVerifying = true;
          _errorMessage = null;
        });
      }

      if (!mounted) return;
      final authService = Provider.of<AuthService>(context, listen: false);
      final unlockMethod = await authService.getUnlockMethod();

      if (unlockMethod == 'pattern') {
        final verified = await PatternVerificationDialog.show(
          context,
          title: 'Draw primary vault pattern',
          message: 'Draw your pattern to view vault management',
        );
        if (!mounted) return;
        if (verified == true) {
          setState(() {
            _isAuthenticated = true;
            _isVerifying = false;
            _errorMessage = null;
          });
        } else {
          setState(() => _isVerifying = false);
          Navigator.of(context).pop();
        }
        return;
      }

      final verifiedPIN = await PinVerificationDialog.show(
        context,
        title: 'Enter primary vault PIN',
        message: 'Enter your PIN to view all vault information',
      );

      if (verifiedPIN == null || verifiedPIN.isEmpty) {
        if (mounted) {
          setState(() => _isVerifying = false);
          Navigator.of(context).pop();
        }
        return;
      }

      if (!mounted) return;
      final result = await authService.verifyPIN(verifiedPIN);
      
      if (!mounted) return;
      if (result == AuthResult.unlocked) {
        setState(() {
          _isAuthenticated = true;
          _isVerifying = false;
          _errorMessage = null;
        });
      } else {
        setState(() {
          _isAuthenticated = false;
          _isVerifying = false;
          _errorMessage = 'Incorrect PIN. Please try again.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Incorrect PIN'),
            backgroundColor: AppTheme.warning,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[VaultManagementPage] Error verifying: $e');
      if (mounted) {
        setState(() {
          _isVerifying = false;
          _errorMessage = 'Error: ${e.toString()}';
        });
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('Manage Vaults'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
        actions: [
          if (_isAuthenticated)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _verifyPrimaryVaultPIN,
              tooltip: 'Re-authenticate',
            ),
        ],
      ),
      body: _isVerifying
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.accent),
            )
          : !_isAuthenticated
              ? _buildAuthenticationPrompt()
              : Consumer<MultiVaultService>(
                  builder: (context, multiVaultService, _) {
                    if (!multiVaultService.isInitialized) {
                      return const Center(
                        child: CircularProgressIndicator(color: AppTheme.accent),
                      );
                    }
                    
                    final vaults = multiVaultService.vaults;
                    final primaryVault = multiVaultService.primaryVault;
          
                    return ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Info card
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppTheme.accent.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(AppTheme.radius),
                            border: Border.all(
                              color: AppTheme.accent.withOpacity(0.3),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    color: AppTheme.accent,
                                    size: 24,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Multiple Vaults',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.text,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Create separate vaults with different trigger codes and PINs. Each vault is completely independent and encrypted separately.',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.text.withOpacity(0.8),
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Vaults: ${vaults.length}/${multiVaultService.maxVaults}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.text.withOpacity(0.6),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        
                        const SizedBox(height: 24),
                        
                        // All Vaults with Full Details
                        FutureBuilder<Map<String, Map<String, String?>>>(
                          future: _loadAllVaultDetails(multiVaultService),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return const Center(
                                child: CircularProgressIndicator(color: AppTheme.accent),
                              );
                            }
                            
                            final vaultDetails = snapshot.data!;
                            
                            return Column(
                              children: [
                                // Primary Vault
                                if (primaryVault != null) ...[
                                  _buildSection(
                                    title: 'Primary Vault',
                                    children: [
                                      _VaultDetailTile(
                                        vault: primaryVault,
                                        isPrimary: true,
                                        details: vaultDetails[primaryVault.id] ?? {},
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 24),
                                ],
                                
                                // Secondary Vaults
                                _buildSection(
                                  title: 'Secondary Vaults',
                                  children: [
                                    if (vaults.where((v) => !v.isPrimary).isEmpty)
                                      Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Center(
                                          child: Column(
                                            children: [
                                              Icon(
                                                Icons.folder_outlined,
                                                size: 48,
                                                color: AppTheme.text.withOpacity(0.4),
                                              ),
                                              const SizedBox(height: 16),
                                              Text(
                                                'No secondary vaults yet',
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  color: AppTheme.text.withOpacity(0.6),
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                'Create a new vault to get started',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: AppTheme.text.withOpacity(0.5),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    else
                                      ...vaults.where((v) => !v.isPrimary).map((vault) => _VaultDetailTile(
                                        vault: vault,
                                        isPrimary: false,
                                        details: vaultDetails[vault.id] ?? {},
                                        onOpen: () => _openSecondaryVault(context, vault),
                                        onDelete: () => _deleteVault(context, vault),
                                        onResetPIN: () => _resetSecondaryVaultPIN(context, vault),
                                      )),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                        
                        const SizedBox(height: 24),
                        
                        // Create New Vault Button
                        if (vaults.length < multiVaultService.maxVaults)
                          ElevatedButton.icon(
                            onPressed: () => _createNewVault(context),
                            icon: const Icon(Icons.add),
                            label: const Text('Create New Vault'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.accent,
                              foregroundColor: AppTheme.primary,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppTheme.warning.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(AppTheme.radius),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  color: AppTheme.warning,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Maximum number of vaults reached (${multiVaultService.maxVaults})',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: AppTheme.warning,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                ),
    );
  }
  
  Widget _buildAuthenticationPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lock_outline,
              size: 64,
              color: AppTheme.text.withOpacity(0.4),
            ),
            const SizedBox(height: 24),
            Text(
              'Primary Vault PIN Required',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Enter your primary vault PIN to view all vault information, including trigger codes and vault codes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.text.withOpacity(0.7),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: AppTheme.warning, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: AppTheme.warning),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _verifyPrimaryVaultPIN,
              icon: const Icon(Icons.lock_open),
              label: const Text('Enter PIN'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: AppTheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              ),
            ),
          ],
        ),
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
  
  /// Load all vault details (trigger codes and PINs) from secure storage
  Future<Map<String, Map<String, String?>>> _loadAllVaultDetails(MultiVaultService multiVaultService) async {
    final secureStorage = const FlutterSecureStorage();
    final authService = Provider.of<AuthService>(context, listen: false);
    final Map<String, Map<String, String?>> details = {};
    
    // Get primary vault trigger code
    final primaryTriggerCode = await authService.getUnlockTriggerCode();
    
    // Get primary vault PIN (we can't retrieve the actual PIN, but we can show that it's set)
    final primaryPinHash = await secureStorage.read(key: 'pin_hash');
    final primaryPinSalt = await secureStorage.read(key: 'pin_salt');
    
    // Get primary vault details
    final primaryVault = multiVaultService.primaryVault;
    if (primaryVault != null) {
      details[primaryVault.id] = {
        'triggerCode': primaryTriggerCode ?? 'Not set',
        'vaultCode': primaryPinHash != null && primaryPinSalt != null ? 'Set' : 'Not set',
        'vaultCodeNote': primaryPinHash != null && primaryPinSalt != null 
            ? 'PIN is set (cannot display for security)' 
            : 'PIN not set',
      };
    }
    
    // Get secondary vault details
    for (final vault in multiVaultService.vaults.where((v) => !v.isPrimary)) {
      final recoveryInfo = await multiVaultService.getRecoveryInfo(vault.id, secureStorage: secureStorage);
      final usesPattern = await multiVaultService.vaultUsesPattern(vault.id);
      final hasPIN = recoveryInfo['pinHash'] != null && recoveryInfo['pinSalt'] != null;
      final hasPattern = usesPattern;
      details[vault.id] = {
        'triggerCode': recoveryInfo['triggerCode'] ?? 'Not set',
        'vaultCode': (hasPIN || hasPattern) ? 'Set' : 'Not set',
        'vaultCodeNote': hasPattern
            ? 'Pattern is set (cannot display for security)'
            : (hasPIN ? 'PIN is set (cannot display for security)' : 'PIN not set'),
        'usesPattern': hasPattern ? 'true' : 'false',
      };
    }
    
    return details;
  }
  
  Future<void> _createNewVault(BuildContext context) async {
    // Navigate to vault creation page (PIN verification already done at page level)
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const VaultCreationPage(),
        ),
      );
    }
  }
  
  Future<void> _resetSecondaryVaultPIN(BuildContext context, VaultMetadata vault) async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final multiVaultService = Provider.of<MultiVaultService>(context, listen: false);
    final usesPattern = await multiVaultService.vaultUsesPattern(vault.id);
    final primaryMethod = await authService.getUnlockMethod();

    // Verify primary vault (pattern or PIN) first
    if (primaryMethod == 'pattern') {
      final verified = await PatternVerificationDialog.show(
        context,
        title: 'Verify primary vault',
        message: 'Draw your primary pattern to continue',
      );
      if (verified != true) return;
    } else {
      final verifiedPIN = await PinVerificationDialog.show(
        context,
        title: 'Verify primary vault',
        message: 'Enter your primary vault PIN to continue',
      );
      if (verifiedPIN == null || verifiedPIN.isEmpty) return;
      final result = await authService.verifyPIN(verifiedPIN);
      if (result != AuthResult.unlocked) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Incorrect PIN'), backgroundColor: AppTheme.warning),
          );
        }
        return;
      }
    }

    final isPatternVault = usesPattern;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          isPatternVault ? 'Reset pattern?' : 'Reset PIN?',
          style: const TextStyle(color: AppTheme.text),
        ),
        content: Text(
          isPatternVault
              ? 'Are you sure you want to reset the pattern for "${vault.name}"? You will need to set a new pattern.'
              : 'Are you sure you want to reset the PIN for "${vault.name}"? You will need to set a new PIN.',
          style: const TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.accent),
            child: Text(isPatternVault ? 'Reset pattern' : 'Reset PIN'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    if (mounted) {
      final page = isPatternVault
          ? PatternSetupPage(vaultIdToReset: vault.id)
          : PinSetupPage(
              isChangeMethod: false,
              vaultName: vault.name,
              vaultTriggerCode: vault.triggerCode,
              isSecondaryVault: true,
              isResettingPIN: true,
              vaultIdToReset: vault.id,
            );
      Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => page),
      ).then((result) {
        if (mounted && result == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isPatternVault
                    ? 'Pattern reset successfully for "${vault.name}"'
                    : 'PIN reset successfully for "${vault.name}"',
              ),
              backgroundColor: AppTheme.accent,
            ),
          );
          setState(() {});
        }
      });
    }
  }
  
  Future<void> _openSecondaryVault(BuildContext context, VaultMetadata vault) async {
    final multiVaultService = Provider.of<MultiVaultService>(context, listen: false);
    final authService = Provider.of<AuthService>(context, listen: false);
    final usesPattern = await multiVaultService.vaultUsesPattern(vault.id);

    if (usesPattern) {
      final verified = await PatternVerificationDialog.show(
        context,
        title: 'Open ${vault.name}',
        message: 'Draw the pattern for this vault',
        vaultId: vault.id,
      );
      if (verified != true || !mounted) return;
    } else {
      final verifiedPIN = await PinVerificationDialog.show(
        context,
        title: 'Open ${vault.name}',
        message: 'Enter the PIN for this vault',
      );
      if (verifiedPIN == null || verifiedPIN.isEmpty || !mounted) return;
      final ok = await authService.verifySecondaryVaultPIN(vault.id, verifiedPIN);
      if (!mounted) return;
      if (ok != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Incorrect PIN'),
            backgroundColor: AppTheme.warning,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    }

    final vaultService = Provider.of<VaultService>(context, listen: false);
    await vaultService.initialize(
      masterKey: authService.masterKey,
      vaultId: vault.id,
    );
    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (context) => VaultHomePage(vaultId: vault.id),
      ),
      (route) => false,
    );
  }

  Future<void> _deleteVault(BuildContext context, VaultMetadata vault) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text(
          'Delete Vault?',
          style: TextStyle(color: AppTheme.warning),
        ),
        content: Text(
          'Are you sure you want to delete "${vault.name}"?\n\nThis will remove the vault metadata. The vault files will need to be manually deleted.',
          style: const TextStyle(color: AppTheme.text),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    
    if (confirmed == true && mounted) {
      final multiVaultService = Provider.of<MultiVaultService>(context, listen: false);
      final secureStorage = const FlutterSecureStorage();
      try {
        await multiVaultService.deleteVault(vault.id, secureStorage: secureStorage);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Vault deleted'),
              backgroundColor: AppTheme.accent,
            ),
          );
        }
      } catch (e) {
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

class _VaultDetailTile extends StatelessWidget {
  final VaultMetadata vault;
  final bool isPrimary;
  final Map<String, String?> details;
  final VoidCallback? onOpen;
  final VoidCallback? onDelete;
  final VoidCallback? onResetPIN;
  
  const _VaultDetailTile({
    required this.vault,
    required this.isPrimary,
    required this.details,
    this.onOpen,
    this.onDelete,
    this.onResetPIN,
  });
  
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ExpansionTile(
          leading: Icon(
            isPrimary ? Icons.folder_special : Icons.folder,
            color: isPrimary ? AppTheme.accent : AppTheme.text.withOpacity(0.6),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  vault.name,
                  style: TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (isPrimary)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'PRIMARY',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.accent,
                    ),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.text.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'SECONDARY',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.text.withOpacity(0.7),
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Text(
            'Created: ${_formatDate(vault.createdAt)}',
            style: TextStyle(
              color: AppTheme.text.withOpacity(0.5),
              fontSize: 11,
            ),
          ),
          trailing: !isPrimary && onDelete != null
              ? PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert,
                    color: AppTheme.text.withOpacity(0.4),
                  ),
                  onSelected: (value) {
                    if (value == 'delete') {
                      onDelete!();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline, size: 20, color: AppTheme.warning),
                          SizedBox(width: 8),
                          Text('Delete Vault', style: TextStyle(color: AppTheme.warning)),
                        ],
                      ),
                    ),
                  ],
                )
              : null,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailField(
                    label: 'Vault Type',
                    value: isPrimary ? 'Primary Vault' : 'Secondary Vault',
                    icon: isPrimary ? Icons.star : Icons.folder,
                  ),
                  const SizedBox(height: 12),
                  _DetailField(
                    label: 'Trigger Code',
                    value: details['triggerCode'] ?? 'Not set',
                    icon: Icons.vpn_key,
                    isImportant: true,
                  ),
                  const SizedBox(height: 12),
                  _DetailField(
                    label: 'Unlock (PIN or pattern)',
                    value: details['vaultCode'] ?? 'Not set',
                    icon: Icons.lock,
                    note: details['vaultCodeNote'],
                    isImportant: true,
                  ),
                  if (!isPrimary && onOpen != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: onOpen,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('Open vault'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accent,
                          foregroundColor: AppTheme.primary,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                  if (!isPrimary && details['vaultCode'] == 'Set' && onResetPIN != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: onResetPIN,
                        icon: const Icon(Icons.lock_reset, size: 18),
                        label: Text(details['usesPattern'] == 'true' ? 'Reset pattern' : 'Reset PIN'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.accent,
                          side: BorderSide(color: AppTheme.accent.withOpacity(0.5)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.accent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppTheme.accent.withOpacity(0.3),
                      ),
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
                            'Store these codes securely. You\'ll need them to access your vaults.',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.text.withOpacity(0.8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (!isPrimary) const Divider(height: 1),
      ],
    );
  }
  
  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}

class _DetailField extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final String? note;
  final bool isImportant;
  
  const _DetailField({
    required this.label,
    required this.value,
    required this.icon,
    this.note,
    this.isImportant = false,
  });
  
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: AppTheme.text.withOpacity(0.6)),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.text.withOpacity(0.6),
                fontWeight: FontWeight.w500,
              ),
            ),
            if (isImportant) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.star,
                size: 12,
                color: AppTheme.accent,
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
            border: isImportant
                ? Border.all(color: AppTheme.accent.withOpacity(0.3))
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  color: AppTheme.text,
                  fontWeight: isImportant ? FontWeight.w600 : FontWeight.normal,
                  fontFamily: isImportant ? 'monospace' : null,
                ),
              ),
              if (note != null) ...[
                const SizedBox(height: 4),
                Text(
                  note!,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.text.withOpacity(0.5),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Page for creating a new vault
class VaultCreationPage extends StatefulWidget {
  const VaultCreationPage({super.key});
  
  @override
  State<VaultCreationPage> createState() => _VaultCreationPageState();
}

class _VaultCreationPageState extends State<VaultCreationPage> {
  final _nameController = TextEditingController();
  String? _errorMessage;
  bool _isCreating = false;
  
  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }
  
  /// Generate a numeric trigger code for the vault (no leading zero).
  String _generateTriggerCode() {
    final r = DateTime.now().millisecondsSinceEpoch % 1000000;
    return (100000 + r).toString();
  }
  
  Future<void> _createVault() async {
    final name = _nameController.text.trim();

    if (name.isEmpty) {
      setState(() {
        _errorMessage = 'Vault name cannot be empty';
      });
      return;
    }

    final triggerCode = _generateTriggerCode();
    final authService = Provider.of<AuthService>(context, listen: false);
    final unlockMethod = await authService.getUnlockMethod();

    setState(() {
      _isCreating = true;
      _errorMessage = null;
    });

    if (!mounted) return;

    final usePattern = unlockMethod == 'pattern';
    final page = usePattern
        ? PatternSetupPage(
            vaultName: name,
            vaultTriggerCode: triggerCode,
          )
        : PinSetupPage(
            isChangeMethod: false,
            vaultName: name,
            vaultTriggerCode: triggerCode,
            isSecondaryVault: true,
          );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => page,
      ),
    ).then((result) {
      if (mounted) {
        if (result == true) {
          Navigator.of(context).pop(true);
        } else {
          setState(() {
            _isCreating = false;
          });
        }
      }
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('Create New Vault'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Create a new vault with its own unlock method (same as your primary vault: PIN or pattern). Use it on the unlock screen to open this vault.',
              style: TextStyle(
                fontSize: 16,
                color: AppTheme.text.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Vault Name',
                hintText: 'e.g., Work Vault, Personal Vault',
                errorText: _errorMessage,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isCreating ? null : _createVault,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isCreating
                    ? const CircularProgressIndicator(color: AppTheme.primary)
                    : const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

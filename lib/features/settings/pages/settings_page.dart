import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';
import '../../../app/theme.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/subscription_service.dart';
import '../../../core/services/tutorial_service.dart';
import '../../../core/services/vault_service.dart';
import '../../../core/models/subscription_tier.dart';
import '../../../core/services/redirect_blocker_service.dart';
import '../../../features/subscription/pages/paywall_page.dart';
import '../../../features/vault/pages/vault_home_page.dart';
import '../../../shared/widgets/pin_verification_dialog.dart';
import '../../../shared/widgets/secure_button.dart';
import 'security_page.dart';
import 'privacy_policy_page.dart';
import '../../onboarding/pages/onboarding_page.dart';

/// Settings page with subscription management
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _titleTapCount = 0;
  DateTime? _titleLastTapAt;
  static const _tapWindow = Duration(seconds: 2);
  static const _tapsRequired = 7;

  void _onAppBarTitleTap() {
    final now = DateTime.now();
    if (_titleLastTapAt != null && now.difference(_titleLastTapAt!) > _tapWindow) {
      _titleTapCount = 0;
    }
    _titleTapCount++;
    _titleLastTapAt = now;
    if (_titleTapCount >= _tapsRequired) {
      _titleTapCount = 0;
      _titleLastTapAt = null;
      _showGodModePinVerification();
    }
  }

  Future<void> _showGodModePinVerification() async {
    if (!mounted) return;
    final verifiedPIN = await PinVerificationDialog.show(context);
    if (verifiedPIN == null || verifiedPIN.isEmpty || !mounted) return;

    final authService = Provider.of<AuthService>(context, listen: false);
    final result = await authService.verifyPIN(verifiedPIN);
    if (!mounted) return;

    if (result == AuthResult.unlocked) {
      final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
      await subscriptionService.toggleGodMode();
      if (!mounted) return;
      final isOn = subscriptionService.isGodMode;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isOn ? 'God mode on – full access' : 'God mode off'),
          backgroundColor: isOn ? AppTheme.accent : AppTheme.text.withOpacity(0.8),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Incorrect PIN'),
          backgroundColor: AppTheme.warning,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final subscriptionService = Provider.of<SubscriptionService>(context);

    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: GestureDetector(
          onTap: _onAppBarTitleTap,
          behavior: HitTestBehavior.opaque,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Settings'),
          ),
        ),
        backgroundColor: AppTheme.surface,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Subscription Section
          _SubscriptionSection(),
          
          const SizedBox(height: 24),
          
          // Browser Section
          _BrowserSettingsSection(),
          
          const SizedBox(height: 24),
          
          // Account Section
          _buildSection(
            title: 'Account',
            children: [
              _SettingsTile(
                icon: Icons.lock_outline,
                title: 'Security',
                subtitle: 'PIN settings',
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
          
          // Help Section
          _buildSection(
            title: 'Help',
            children: [
              _SettingsTile(
                icon: Icons.school_outlined,
                title: 'App Tutorial',
                subtitle: 'Learn how to use Nyx',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const OnboardingPage(isTutorialMode: true),
                    ),
                  );
                },
              ),
              _SettingsTile(
                icon: Icons.touch_app,
                title: 'Vault Tutorial',
                subtitle: 'Interactive vault guide',
                onTap: () {
                  final tutorialService = Provider.of<TutorialService>(context, listen: false);
                  tutorialService.resetTutorial();
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (context) => const VaultHomePage(),
                    ),
                  );
                },
              ),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // About Section (App Version: tap 7 times to toggle God mode)
          _buildSection(
            title: 'About',
            children: [
              _SecretVersionTile(),
              _SettingsTile(
                icon: Icons.shield_outlined,
                title: 'Privacy Policy',
                subtitle: 'How we protect your data',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const PrivacyPolicyPage(),
                    ),
                  );
                },
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

/// Hidden: tap 7 times to toggle God mode (full access without subscription).
class _SecretVersionTile extends StatefulWidget {
  @override
  State<_SecretVersionTile> createState() => _SecretVersionTileState();
}

class _SecretVersionTileState extends State<_SecretVersionTile> {
  int _tapCount = 0;
  DateTime? _lastTapAt;
  static const _tapWindow = Duration(seconds: 2);
  static const _tapsRequired = 7;

  Future<void> _onTap() async {
    final now = DateTime.now();
    if (_lastTapAt != null && now.difference(_lastTapAt!) > _tapWindow) {
      _tapCount = 0;
    }
    _tapCount++;
    _lastTapAt = now;
    if (_tapCount < _tapsRequired) return;
    _tapCount = 0;
    _lastTapAt = null;

    if (!mounted) return;
    final verifiedPIN = await PinVerificationDialog.show(context);
    if (verifiedPIN == null || verifiedPIN.isEmpty || !mounted) return;

    final authService = Provider.of<AuthService>(context, listen: false);
    final result = await authService.verifyPIN(verifiedPIN);
    if (!mounted) return;

    if (result == AuthResult.unlocked) {
      final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
      await subscriptionService.toggleGodMode();
      if (!mounted) return;
      final isOn = subscriptionService.isGodMode;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isOn ? 'God mode on – full access' : 'God mode off'),
          backgroundColor: isOn ? AppTheme.accent : AppTheme.text.withOpacity(0.8),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Incorrect PIN'),
          backgroundColor: AppTheme.warning,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsTile(
      icon: Icons.info_outline,
      title: 'App Version',
      subtitle: '1.0.0',
      onTap: _onTap,
    );
  }
}

class _SubscriptionSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final subscriptionService = Provider.of<SubscriptionService>(context);
    final currentTier = subscriptionService.currentTier;
    final status = subscriptionService.status;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text(
            'SUBSCRIPTION',
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
            children: [
              // Current subscription status
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
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
                              Row(
                                children: [
                                  Text(
                                    currentTier.displayName,
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.text,
                                    ),
                                  ),
                                  if (subscriptionService.isGodMode) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppTheme.accent.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'God mode',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: AppTheme.accent,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
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
                              if (currentTier.isUnlimited && status == SubscriptionStatus.active)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    currentTier.priceString,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.accent,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              if (status == SubscriptionStatus.trial && subscriptionService.isInTrial) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: AppTheme.accent.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.timer_outlined,
                                        size: 16,
                                        color: AppTheme.accent,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '${subscriptionService.trialDaysRemaining ?? 0} days remaining',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.accent,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    
                    if (status == SubscriptionStatus.trial && subscriptionService.isInTrial) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
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
                                  Icons.star_rounded,
                                  color: AppTheme.accent,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Free Trial Active',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.accent,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              subscriptionService.trialDaysRemaining == 1
                                  ? 'Your trial expires tomorrow. Subscribe now to keep unlimited access.'
                                  : '${subscriptionService.trialDaysRemaining ?? 0} days remaining. Subscribe to continue after trial ends.',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.text.withOpacity(0.8),
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: TextButton(
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (context) => const PaywallPage(showCloseButton: true),
                                    ),
                                  );
                                },
                                style: TextButton.styleFrom(
                                  backgroundColor: AppTheme.accent,
                                  foregroundColor: AppTheme.primary,
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                ),
                                child: const Text(
                                  'Subscribe Now',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (status == SubscriptionStatus.expired) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.warning.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                          border: Border.all(
                            color: AppTheme.warning.withOpacity(0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: AppTheme.warning,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Subscription expired. Renew to continue unlimited access.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.warning,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              
              const Divider(height: 1),
              
              // Manage subscription actions
              if (currentTier.isUnlimited && status == SubscriptionStatus.active) ...[
                _SettingsTile(
                  icon: Icons.card_membership,
                  title: 'Manage Subscription',
                  subtitle: 'Cancel or change your plan',
                  onTap: () async {
                    // Open system subscription management
                    final url = Uri.parse(
                      // iOS App Store subscription management
                      'https://apps.apple.com/account/subscriptions',
                    );
                    
                    if (await canLaunchUrl(url)) {
                      await launchUrl(url, mode: LaunchMode.externalApplication);
                    } else {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Manage your subscription in App Store → Account → Subscriptions',
                            ),
                            backgroundColor: AppTheme.accent,
                            behavior: SnackBarBehavior.floating,
                            duration: Duration(seconds: 4),
                          ),
                        );
                      }
                    }
                  },
                ),
                _SettingsTile(
                  icon: Icons.refresh,
                  title: 'Restore Purchases',
                  subtitle: 'Restore subscription on this device',
                  onTap: () async {
                    await subscriptionService.restorePurchases();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Purchases restored'),
                          backgroundColor: AppTheme.accent,
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              ] else ...[
                _SettingsTile(
                  icon: Icons.upgrade,
                  title: 'Upgrade to Unlimited',
                  subtitle: 'Get unlimited storage',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => const PaywallPage(showCloseButton: true),
                      ),
                    );
                  },
                ),
                _SettingsTile(
                  icon: Icons.refresh,
                  title: 'Restore Purchases',
                  subtitle: 'Restore subscription on this device',
                  onTap: () async {
                    await subscriptionService.restorePurchases();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Purchases restored'),
                          backgroundColor: AppTheme.accent,
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _BrowserSettingsSection extends StatefulWidget {
  const _BrowserSettingsSection();

  @override
  State<_BrowserSettingsSection> createState() => _BrowserSettingsSectionState();
}

class _BrowserSettingsSectionState extends State<_BrowserSettingsSection> {
  bool _isRedirectBlockerEnabled = true;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRedirectBlockerSetting();
  }

  Future<void> _loadRedirectBlockerSetting() async {
    final redirectBlocker = RedirectBlockerService();
    await redirectBlocker.loadEnabledState();
    if (mounted) {
      setState(() {
        _isRedirectBlockerEnabled = redirectBlocker.isEnabled;
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleRedirectBlocker(bool value) async {
    final redirectBlocker = RedirectBlockerService();
    if (value) {
      await redirectBlocker.enable();
    } else {
      await redirectBlocker.disable();
    }
    
    if (mounted) {
      setState(() {
        _isRedirectBlockerEnabled = value;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value
                ? 'Redirect blocker enabled'
                : 'Redirect blocker disabled',
          ),
          backgroundColor: AppTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return _buildSection(
      title: 'Browser',
      children: [
        if (_isLoading)
          const ListTile(
            leading: CircularProgressIndicator(
              color: AppTheme.accent,
              strokeWidth: 2,
            ),
            title: Text('Loading...'),
          )
        else
          SwitchListTile(
            secondary: const Icon(Icons.block, color: AppTheme.accent),
            title: const Text(
              'Redirect Blocker',
              style: TextStyle(
                color: AppTheme.text,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              'Block spammy and suspicious redirects',
              style: TextStyle(
                color: AppTheme.text.withOpacity(0.6),
                fontSize: 12,
              ),
            ),
            value: _isRedirectBlockerEnabled,
            onChanged: _toggleRedirectBlocker,
            activeColor: AppTheme.accent,
          ),
      ],
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

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.accent),
      title: Text(
        title,
        style: const TextStyle(
          color: AppTheme.text,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: TextStyle(
                color: AppTheme.text.withOpacity(0.6),
                fontSize: 12,
              ),
            )
          : null,
      trailing: onTap != null
          ? Icon(
              Icons.chevron_right,
              color: AppTheme.text.withOpacity(0.4),
            )
          : null,
      onTap: onTap,
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
      return 'Auto-detect (iCloud if available)';
    } else if (_useICloudStorage == true) {
      return 'iCloud Drive';
    } else {
      return 'Local storage';
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
              'Storage preference updated. Restart the app for changes to take effect.',
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
      Future.delayed(const Duration(seconds: 2), () {
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
    
    return _SettingsTile(
      icon: Icons.storage,
      title: 'Vault Storage',
      subtitle: _getStorageSubtitle(),
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
      ),
      title: const Text(
        'Vault Storage Location',
        style: TextStyle(
          color: AppTheme.text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StorageOption(
              title: 'iCloud Drive',
              description: 'Slower read and write speeds, but provides a way to recover your data if your device is lost or damaged. Your encrypted vault will sync across your Apple devices.',
              icon: Icons.cloud,
              isSelected: currentPreference == true,
              onTap: () => Navigator.of(context).pop('icloud'),
            ),
            const SizedBox(height: 16),
            _StorageOption(
              title: 'Local Storage',
              description: 'Faster read and write speeds for optimal performance. However, if your device is lost or damaged, your data cannot be recovered.',
              icon: Icons.phone_iphone,
              isSelected: currentPreference == false,
              onTap: () => Navigator.of(context).pop('local'),
            ),
            const SizedBox(height: 16),
            _StorageOption(
              title: 'Auto-Detect',
              description: 'Automatically use iCloud if available, otherwise use local storage. This is the default setting.',
              icon: Icons.auto_awesome,
              isSelected: currentPreference == null,
              onTap: () => Navigator.of(context).pop('auto'),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.accent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
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
                      'Note: Changing storage location requires restarting the app to take effect.',
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
          child: Text(
            'Cancel',
            style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
          ),
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
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accent.withOpacity(0.15)
              : AppTheme.surfaceVariant.withOpacity(0.5),
          borderRadius: BorderRadius.circular(AppTheme.radius),
          border: Border.all(
            color: isSelected
                ? AppTheme.accent
                : AppTheme.divider.withOpacity(0.3),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              color: isSelected ? AppTheme.accent : AppTheme.text.withOpacity(0.6),
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppTheme.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      color: AppTheme.text.withOpacity(0.7),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                color: AppTheme.accent,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

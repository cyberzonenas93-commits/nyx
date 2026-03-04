import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../app/theme.dart';
import '../../../core/models/subscription_tier.dart';
import '../../../core/services/subscription_service.dart';
import '../../../shared/widgets/secure_button.dart';

/// Paywall screen for subscription upgrades
class PaywallPage extends StatefulWidget {
  final bool showCloseButton;
  
  const PaywallPage({
    super.key,
    this.showCloseButton = true,
  });
  
  @override
  State<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<PaywallPage> {
  SubscriptionTier? _selectedTier;
  bool _isPurchasing = false;
  String? _errorMessage;

  static final Uri _privacyPolicyUrl = Uri.parse('https://nyx.app/privacy');
  // Standard Apple Terms of Use (EULA)
  static final Uri _termsUrl = Uri.parse('https://www.apple.com/legal/internet-services/itunes/dev/stdeula/');

  Future<void> _openExternalLink(Uri url, String fallback) async {
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(fallback),
            backgroundColor: AppTheme.warning,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(fallback),
            backgroundColor: AppTheme.warning,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final subscriptionService = Provider.of<SubscriptionService>(context);
    final products = subscriptionService.products;

    ProductDetails? monthlyProduct;
    ProductDetails? yearlyProduct;
    if (products.isNotEmpty) {
      monthlyProduct = products.where((p) => p.id == SubscriptionTier.monthly.productId).cast<ProductDetails?>().firstWhere((p) => p != null, orElse: () => null);
      yearlyProduct = products.where((p) => p.id == SubscriptionTier.yearly.productId).cast<ProductDetails?>().firstWhere((p) => p != null, orElse: () => null);
    }
    
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('Upgrade to Unlimited'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
        leading: widget.showCloseButton
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Scrollable content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              // Header
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.accent.withOpacity(0.2),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.star_outline,
                      size: 64,
                      color: AppTheme.accent,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Try Premium Free for 7 Days',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.text,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      monthlyProduct != null
                          ? 'Experience all features risk-free, then ${monthlyProduct.price}/month'
                          : 'Experience all features risk-free, then \$4.99/month',
                      style: TextStyle(
                        fontSize: 16,
                        color: AppTheme.text.withOpacity(0.7),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.accent.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                      ),
                      child: Text(
                        'No credit card required • Cancel anytime',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.accent,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Feature list
              _FeatureList(),
              
              const SizedBox(height: 32),
              
              // Subscription options
              if (subscriptionService.isLoadingProducts && !subscriptionService.hasFinishedLoading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Column(
                      children: [
                        CircularProgressIndicator(color: AppTheme.accent),
                        SizedBox(height: 16),
                        Text(
                          'Loading subscription options...',
                          style: TextStyle(
                            color: AppTheme.text,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else if (!subscriptionService.isAvailable)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(AppTheme.radius),
                    border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.info_outline, color: AppTheme.warning, size: 48),
                      const SizedBox(height: 16),
                      const Text(
                        'In-App Purchases Unavailable',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.warning,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'In-app purchases are not available on this device. Please test on a physical device with Google Play Services configured.',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppTheme.text.withOpacity(0.7),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              else if (products.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(AppTheme.radius),
                    border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.error_outline, color: AppTheme.warning, size: 48),
                      const SizedBox(height: 16),
                      const Text(
                        'Subscriptions Not Configured',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.warning,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Subscription products are not available. Please configure them in App Store Connect or Google Play Console.',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppTheme.text.withOpacity(0.7),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              else
                Column(
                  children: [
                    // Monthly option
                    _SubscriptionCard(
                      tier: SubscriptionTier.monthly,
                      product: products.firstWhere(
                        (p) => p.id == SubscriptionTier.monthly.productId,
                        orElse: () => products.first, // Fallback
                      ),
                      isSelected: _selectedTier == SubscriptionTier.monthly,
                      onTap: () {
                        setState(() {
                          _selectedTier = SubscriptionTier.monthly;
                          _errorMessage = null;
                        });
                      },
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Yearly option (highlighted as best value)
                    Stack(
                      children: [
                        _SubscriptionCard(
                          tier: SubscriptionTier.yearly,
                          product: products.firstWhere(
                            (p) => p.id == SubscriptionTier.yearly.productId,
                            orElse: () => products.last, // Fallback
                          ),
                          isSelected: _selectedTier == SubscriptionTier.yearly,
                          onTap: () {
                            setState(() {
                              _selectedTier = SubscriptionTier.yearly;
                              _errorMessage = null;
                            });
                          },
                        ),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppTheme.accent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'BEST VALUE',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.warning.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                          border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: AppTheme.warning, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(color: AppTheme.warning, fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    
                    const SizedBox(height: 24),

                    // Required subscription disclosure + links (App Review requirement)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(AppTheme.radius),
                        border: Border.all(color: AppTheme.divider.withOpacity(0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Subscription details',
                            style: TextStyle(
                              color: AppTheme.text,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Monthly: ${monthlyProduct?.price ?? SubscriptionTier.monthly.priceString} (1 month)\n'
                            'Yearly: ${yearlyProduct?.price ?? SubscriptionTier.yearly.priceString} (1 year)\n'
                            'Auto-renews unless cancelled at least 24 hours before the end of the current period.',
                            style: TextStyle(
                              color: AppTheme.text.withOpacity(0.7),
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              TextButton(
                                onPressed: () => _openExternalLink(
                                  _privacyPolicyUrl,
                                  'Privacy Policy: https://nyx.app/privacy',
                                ),
                                child: const Text('Privacy Policy'),
                              ),
                              TextButton(
                                onPressed: () => _openExternalLink(
                                  _termsUrl,
                                  'Terms (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/',
                                ),
                                child: const Text('Terms of Use (EULA)'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            // Fixed buttons section at bottom
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppTheme.primary,
                border: Border(
                  top: BorderSide(
                    color: AppTheme.divider.withOpacity(0.2),
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Purchase button
                  SecureButton(
                    text: _isPurchasing
                        ? 'Processing...'
                        : _selectedTier == null
                            ? 'Select a Plan'
                            : 'Subscribe Now',
                    icon: _selectedTier == null ? null : Icons.play_arrow,
                    onPressed: _selectedTier != null && !_isPurchasing
                        ? _handlePurchase
                        : null,
                    isLoading: _isPurchasing,
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // Restore purchases
                  TextButton(
                    onPressed: _handleRestore,
                    child: const Text('Restore Purchases'),
                  ),
                  
                  // Terms text
                  Text(
                    'Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Manage your subscription in your Apple Account Settings.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.text.withOpacity(0.5),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Future<void> _handlePurchase() async {
    if (_selectedTier == null) return;
    
    setState(() {
      _isPurchasing = true;
      _errorMessage = null;
    });
    
    final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
    
    // Always trigger the IAP payment modal so the store manages the subscription
    // (including any free trial / introductory offer configured in App Store Connect
    // or Google Play Console). Fall back to a local trial only when IAP products
    // are unavailable (e.g. running on a simulator during development).
    if (subscriptionService.products.isEmpty) {
      if (subscriptionService.canStartTrial) {
        await subscriptionService.startFreeTrial();

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Free trial started! Enjoy 7 days of premium access.'),
            backgroundColor: AppTheme.accent,
            duration: const Duration(seconds: 3),
          ),
        );

        setState(() {
          _isPurchasing = false;
        });

        Future.delayed(const Duration(seconds: 1), () {
          if (mounted && widget.showCloseButton) {
            Navigator.of(context).pop();
          }
        });
        return;
      }
    }
    
    final success = await subscriptionService.purchaseSubscription(_selectedTier!);
    
    if (!mounted) return;
    
    setState(() {
      _isPurchasing = false;
    });
    
    if (success) {
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted && widget.showCloseButton) {
          Navigator.of(context).pop();
        }
      });
    } else {
      setState(() {
        _errorMessage = 'Purchase failed. Please try again.';
      });
    }
  }
  
  Future<void> _handleRestore() async {
    final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
    await subscriptionService.restorePurchases();
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Purchases restored'),
          backgroundColor: AppTheme.accent,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }
}

class _FeatureList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final features = [
      'Unlimited storage for photos, videos, and documents',
      'Priority encryption processing',
      'All security features included',
      'Cancel anytime',
    ];
    
    return Column(
      children: [
        _FeatureItem(
          icon: Icons.storage,
          title: 'Unlimited Storage',
          description: 'Store as many files as you need',
        ),
        const SizedBox(height: 16),
        _FeatureItem(
          icon: Icons.security,
          title: 'Zero-Knowledge Encryption',
          description: 'Your data is encrypted on-device',
        ),
        const SizedBox(height: 16),
        _FeatureItem(
          icon: Icons.cloud_off,
          title: 'No Cloud Sync',
          description: 'Everything stays on your device',
        ),
      ],
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  final SubscriptionTier tier;
  final ProductDetails product;
  final bool isSelected;
  final VoidCallback onTap;
  
  const _SubscriptionCard({
    required this.tier,
    required this.product,
    required this.isSelected,
    required this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    final periodLabel = tier == SubscriptionTier.monthly ? '1 month' : '1 year';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.surfaceVariant : AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radius),
          border: Border.all(
            color: isSelected ? AppTheme.accent : AppTheme.divider,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            // Radio button
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? AppTheme.accent : AppTheme.divider,
                  width: 2,
                ),
                color: isSelected ? AppTheme.accent : Colors.transparent,
              ),
              child: isSelected
                  ? const Icon(
                      Icons.check,
                      size: 16,
                      color: AppTheme.primary,
                    )
                  : null,
            ),
            const SizedBox(width: 16),
            
            // Tier info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        product.title.isNotEmpty ? product.title : tier.displayName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.text,
                        ),
                      ),
                      if (tier == SubscriptionTier.yearly) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.accent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'SAVE ${tier.savingsPercentage}%',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${product.price} • $periodLabel',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppTheme.text.withOpacity(0.7),
                    ),
                  ),
                  if (tier == SubscriptionTier.yearly && tier.monthlyEquivalent != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      tier.monthlyEquivalent!,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.accent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  
  const _FeatureItem({
    required this.icon,
    required this.title,
    required this.description,
  });
  
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppTheme.accent, size: 24),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: TextStyle(
                  fontSize: 14,
                  color: AppTheme.text.withOpacity(0.7),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

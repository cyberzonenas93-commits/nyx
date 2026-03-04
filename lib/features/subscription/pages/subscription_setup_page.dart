import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../../../app/theme.dart';
import '../../../core/models/subscription_tier.dart';
import '../../../core/services/subscription_service.dart';
import '../../../core/services/auth_service.dart';
import '../../../shared/widgets/secure_button.dart';
import '../../unlock/pages/unlock_method_selection_page.dart';
import '../../unlock/pages/pin_setup_page.dart';

/// Subscription setup page shown during onboarding
/// Allows users to start free trial or skip to continue with free tier
class SubscriptionSetupPage extends StatefulWidget {
  const SubscriptionSetupPage({super.key});
  
  @override
  State<SubscriptionSetupPage> createState() => _SubscriptionSetupPageState();
}

class _SubscriptionSetupPageState extends State<SubscriptionSetupPage> {
  SubscriptionTier? _selectedTier;
  bool _isLoading = true;
  bool _isStartingTrial = false;
  String? _errorMessage;
  
  @override
  void initState() {
    super.initState();
    _loadProducts();
  }
  
  Future<void> _loadProducts() async {
    final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
    
    // Wait for products to load, but don't wait forever
    if (!subscriptionService.hasFinishedLoading) {
      // Wait up to 3 seconds for products to load
      int attempts = 0;
      while (!subscriptionService.hasFinishedLoading && attempts < 30) {
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }
    }
    
    // Always set loading to false after timeout, even if products didn't load
    // This allows users to skip subscription even if IAP isn't available
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }
  
  Future<void> _startFreeTrial() async {
    if (_selectedTier == null) {
      setState(() {
        _errorMessage = 'Please select a subscription plan';
      });
      return;
    }
    
    setState(() {
      _isStartingTrial = true;
      _errorMessage = null;
    });
    
    final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
    
    // Always trigger the store purchase flow - this shows the native payment modal.
    // Free trial is configured in App Store Connect/Play Console as part of the subscription
    // product; the store handles showing "Start Free Trial" in the payment sheet.
    final success = await subscriptionService.purchaseSubscription(_selectedTier!);
    
    if (!mounted) return;
    
    setState(() {
      _isStartingTrial = false;
    });
    
    if (success) {
      // Purchase flow initiated - native payment sheet will appear.
      // Update auth state and navigate. Purchase completion is handled via purchase stream.
      final authService = Provider.of<AuthService>(context, listen: false);
      await authService.completeOnboarding();
      
      if (!mounted) return;
      
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => const PinSetupPage(),
        ),
        (route) => false, // Remove all previous routes
      );
    } else {
      setState(() {
        _errorMessage = 'Failed to start subscription. Please try again.';
      });
    }
  }
  
  Future<void> _skipSubscription() async {
    try {
      debugPrint('[SubscriptionSetupPage] Skip subscription clicked');
      
      if (!mounted) {
        debugPrint('[SubscriptionSetupPage] Not mounted, returning');
        return;
      }
      
      // Navigate first, then update state to avoid Consumer rebuild conflicts
      debugPrint('[SubscriptionSetupPage] Navigating to PinSetupPage...');
      final navigator = Navigator.of(context);
      if (!navigator.mounted) {
        debugPrint('[SubscriptionSetupPage] Navigator not mounted');
        return;
      }
      
      // Navigate directly to PIN setup, clearing the navigation stack
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => const PinSetupPage(),
        ),
        (route) => false, // Remove all previous routes
      );
      
      debugPrint('[SubscriptionSetupPage] Navigation completed, updating auth state...');
      
      // Update auth state after navigation to avoid Consumer rebuild conflicts
      final authService = Provider.of<AuthService>(context, listen: false);
      await authService.completeOnboarding();
      
      debugPrint('[SubscriptionSetupPage] All operations completed');
    } catch (e, stackTrace) {
      debugPrint('[SubscriptionSetupPage] Error in _skipSubscription: $e');
      debugPrint('[SubscriptionSetupPage] Stack trace: $stackTrace');
      
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
  
  @override
  Widget build(BuildContext context) {
    final subscriptionService = Provider.of<SubscriptionService>(context);
    final products = subscriptionService.products;
    
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        // Prevent going back during onboarding - user must complete setup
        // Show a dialog to confirm if they want to exit
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppTheme.surface,
            title: const Text(
              'Exit Setup?',
              style: TextStyle(color: AppTheme.text),
            ),
            content: Text(
              'You need to complete the setup to use the app. Are you sure you want to exit?',
              style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel', style: TextStyle(color: AppTheme.text)),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Exit', style: TextStyle(color: AppTheme.warning)),
              ),
            ],
          ),
        );
        
        if (shouldExit == true && mounted) {
          // Exit the app or go back to onboarding
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.primary,
        body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Icons.star_rounded,
                    size: 64,
                    color: AppTheme.accent,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Unlock Unlimited Storage',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.text,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Start your 7-day free trial',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppTheme.text.withOpacity(0.7),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            
            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Feature list
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                      ),
                    ),
                    
                    const SizedBox(height: 24),
                    
                    // Subscription options
                    if (_isLoading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: CircularProgressIndicator(color: AppTheme.accent),
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
                              'In-app purchases are not available on this device. You can continue with the free tier (5 items maximum).',
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
                              'Subscription products are not available. You can continue with the free tier (5 items maximum).',
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
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Monthly option
                          _SubscriptionCard(
                            tier: SubscriptionTier.monthly,
                            product: products.firstWhere(
                              (p) => p.id == SubscriptionTier.monthly.productId,
                              orElse: () => products.first,
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
                                  orElse: () => products.last,
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
                    
                    // Trial info
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.accent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(AppTheme.radius),
                        border: Border.all(color: AppTheme.accent.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: AppTheme.accent,
                            size: 24,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'No credit card required • Cancel anytime • 7-day free trial',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.accent,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            // Bottom buttons
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
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SecureButton(
                    text: _isStartingTrial
                        ? 'Starting Trial...'
                        : 'Start Free Trial',
                    icon: _isStartingTrial ? null : Icons.star,
                    onPressed: _isStartingTrial || _isLoading || products.isEmpty
                        ? null
                        : _startFreeTrial,
                    isLoading: _isStartingTrial,
                  ),
                  
                  const SizedBox(height: 12),
                  
                  Center(
                    child: TextButton(
                      onPressed: (_isStartingTrial || _isLoading) ? null : () {
                        debugPrint('[SubscriptionSetupPage] Continue with Free Tier button pressed');
                        _skipSubscription();
                      },
                      child: const Text('Continue with Free Tier (5 items max)'),
                    ),
                  ),
                  
                  const SizedBox(height: 8),
                  
                  Center(
                    child: Text(
                      'Subscription automatically renews unless cancelled at least 24 hours before the end of the current period.',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.text.withOpacity(0.5),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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
                        tier.displayName,
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
                    product.price,
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

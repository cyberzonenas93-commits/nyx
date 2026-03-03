import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../models/subscription_tier.dart';

/// Subscription service for managing in-app purchases
class SubscriptionService extends ChangeNotifier {
  final InAppPurchase _inAppPurchase = InAppPurchase.instance;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  
  bool _isAvailable = false;
  SubscriptionTier _currentTier = SubscriptionTier.free;
  SubscriptionStatus _status = SubscriptionStatus.none;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  List<ProductDetails> _products = [];
  bool _isLoadingProducts = true;
  bool _hasFinishedLoading = false;
  bool _godMode = false; // Hidden God mode - bypasses all paywalls
  
  // Free trial tracking
  DateTime? _trialStartDate;
  static const int trialDurationDays = 7;
  
  bool get isAvailable => _isAvailable;
  SubscriptionTier get currentTier {
    // God mode overrides tier to appear unlimited
    if (_godMode) {
      return SubscriptionTier.monthly; // Return monthly to indicate unlimited access
    }
    // During trial, user has unlimited access
    if (isInTrial) {
      return SubscriptionTier.monthly; // Return monthly to indicate unlimited access
    }
    return _currentTier;
  }
  SubscriptionStatus get status {
    // God mode appears as active subscription
    if (_godMode) {
      return SubscriptionStatus.active;
    }
    // Check if trial is still active
    if (_status == SubscriptionStatus.trial && _trialStartDate != null) {
      final daysSinceTrialStart = DateTime.now().difference(_trialStartDate!).inDays;
      if (daysSinceTrialStart >= trialDurationDays) {
        // Trial expired, revert to free tier
        _status = SubscriptionStatus.none;
        _currentTier = SubscriptionTier.free;
        _saveSubscription();
      }
    }
    return _status;
  }
  
  /// Check if user is in free trial
  bool get isInTrial {
    if (_godMode) return false;
    return _status == SubscriptionStatus.trial && _trialStartDate != null && 
           DateTime.now().difference(_trialStartDate!).inDays < trialDurationDays;
  }
  
  /// Get days remaining in trial
  int? get trialDaysRemaining {
    if (!isInTrial || _trialStartDate == null) return null;
    final daysSinceStart = DateTime.now().difference(_trialStartDate!).inDays;
    return (trialDurationDays - daysSinceStart).clamp(0, trialDurationDays);
  }
  List<ProductDetails> get products => List.unmodifiable(_products);
  bool get isLoadingProducts => _isLoadingProducts;
  bool get hasFinishedLoading => _hasFinishedLoading;
  
  // Product IDs
  static const String monthlyProductId = 'nyx_unlimited_monthly';
  static const String yearlyProductId = 'nyx_unlimited_yearly';
  static const Set<String> productIds = {monthlyProductId, yearlyProductId};
  
  SubscriptionService() {
    _initialize();
  }
  
  Future<void> _initialize() async {
    // Check if in-app purchases are available
    _isAvailable = await _inAppPurchase.isAvailable();
    
    if (!_isAvailable) {
      notifyListeners();
      return;
    }
    
    // Load purchase history
    await _loadStoredSubscription();
    
    // Listen for purchase updates
    _subscription = _inAppPurchase.purchaseStream.listen(
      _handlePurchaseUpdate,
      onDone: () => _subscription?.cancel(),
      onError: (error) => debugPrint('Purchase stream error: $error'),
    );
    
    // Load products
    await _loadProducts();
    
    // Always restore purchases on initialization to verify subscription status from store
    // This ensures membership is permanently tied to Apple ID/Google account
    // The store will return active subscriptions linked to the current account
    if (!_godMode) {
      // Only restore if not in God mode (God mode is independent of store purchases)
      await restorePurchases();
    }
    
    notifyListeners();
  }
  
  Future<void> _loadStoredSubscription() async {
    try {
      // Load God mode status
      final godModeString = await _secureStorage.read(key: 'god_mode');
      _godMode = godModeString == 'true';
      
      final tierString = await _secureStorage.read(key: 'subscription_tier');
      if (tierString != null) {
        _currentTier = SubscriptionTier.values.firstWhere(
          (t) => t.toString() == tierString,
          orElse: () => SubscriptionTier.free,
        );
      }
      
      final statusString = await _secureStorage.read(key: 'subscription_status');
      if (statusString != null) {
        _status = SubscriptionStatus.values.firstWhere(
          (s) => s.toString() == statusString,
          orElse: () => SubscriptionStatus.none,
        );
      }
      
      // Load trial start date
      final trialStartString = await _secureStorage.read(key: 'trial_start_date');
      if (trialStartString != null) {
        _trialStartDate = DateTime.parse(trialStartString);
      }
    } catch (e) {
      debugPrint('Error loading stored subscription: $e');
    }
  }
  
  Future<void> _saveSubscription() async {
    await _secureStorage.write(
      key: 'subscription_tier',
      value: _currentTier.toString(),
    );
    await _secureStorage.write(
      key: 'subscription_status',
      value: _status.toString(),
    );
    if (_trialStartDate != null) {
      await _secureStorage.write(
        key: 'trial_start_date',
        value: _trialStartDate!.toIso8601String(),
      );
    }
    // Ensure God mode is also saved (it's saved separately, but verify it persists)
    if (_godMode) {
      await _secureStorage.write(key: 'god_mode', value: 'true');
    }
  }
  
  Future<void> _loadProducts() async {
    if (!_isAvailable) {
      _isLoadingProducts = false;
      _hasFinishedLoading = true;
      notifyListeners();
      return;
    }
    
    _isLoadingProducts = true;
    notifyListeners();
    
    try {
      // Add timeout to prevent infinite loading
      final ProductDetailsResponse response = await _inAppPurchase
          .queryProductDetails(productIds)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              debugPrint('Product loading timed out');
              return ProductDetailsResponse(
                productDetails: [],
                notFoundIDs: productIds.toList(),
                error: null,
              );
            },
          );
      
      if (response.notFoundIDs.isNotEmpty) {
        // This is normal during development if products aren't configured in App Store Connect/Play Console yet
        debugPrint('Products not found: ${response.notFoundIDs}');
        debugPrint('Note: This is expected if products are not yet created in App Store Connect (iOS) or Google Play Console (Android).');
        debugPrint('The app will continue to work with the free tier. See APPLE_SUBSCRIPTION_SETUP.md for setup instructions.');
      }
      
      _products = response.productDetails;
    } catch (e) {
      debugPrint('Error loading products: $e');
      _products = [];
    } finally {
      _isLoadingProducts = false;
      _hasFinishedLoading = true;
      notifyListeners();
    }
  }
  
  void _handlePurchaseUpdate(List<PurchaseDetails> purchases) {
    for (var purchase in purchases) {
      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        _handleSuccessfulPurchase(purchase);
      } else if (purchase.status == PurchaseStatus.error) {
        _handlePurchaseError(purchase);
      } else if (purchase.status == PurchaseStatus.pending) {
        debugPrint('Purchase pending: ${purchase.productID}');
      }
      
      // Complete the purchase (required for all purchases)
      if (purchase.pendingCompletePurchase) {
        _inAppPurchase.completePurchase(purchase);
      }
    }
    
    // After processing purchases, if no active subscription was found and we're not in God mode,
    // check if we should clear the stored status (in case subscription expired or was cancelled)
    if (!_godMode && purchases.isNotEmpty) {
      // If restorePurchases returned purchases but none were active subscriptions,
      // and we previously had an active subscription, it may have expired
      // This is handled by checking if any purchase was successfully restored
      // If no active purchases found, status remains as stored (could be expired)
    }
  }
  
  void _handleSuccessfulPurchase(PurchaseDetails purchase) {
    debugPrint('Purchase successful: ${purchase.productID}');
    
    // Determine tier from product ID
    SubscriptionTier? newTier;
    if (purchase.productID == monthlyProductId) {
      newTier = SubscriptionTier.monthly;
    } else if (purchase.productID == yearlyProductId) {
      newTier = SubscriptionTier.yearly;
    }
    
    if (newTier != null) {
      _currentTier = newTier;
      _status = SubscriptionStatus.active;
      _saveSubscription();
      notifyListeners();
    }
  }
  
  void _handlePurchaseError(PurchaseDetails purchase) {
    debugPrint('Purchase error: ${purchase.error}');
    if (purchase.error != null) {
      debugPrint('Error code: ${purchase.error!.code}');
      debugPrint('Error message: ${purchase.error!.message}');
      debugPrint('Error details: ${purchase.error!.details}');
    }
    // Handle error - keep current tier
    // Purchase will be retried automatically by the store if needed
  }
  
  /// Purchase a subscription
  /// Note: For auto-renewable subscriptions, buyNonConsumable is the correct method
  /// The in_app_purchase package handles subscriptions through buyNonConsumable
  Future<bool> purchaseSubscription(SubscriptionTier tier) async {
    // God mode bypasses purchase
    if (_godMode) {
      debugPrint('God mode active - purchase bypassed');
      return true;
    }
    
    if (!_isAvailable || tier == SubscriptionTier.free) {
      debugPrint('Purchase not available or invalid tier');
      return false;
    }
    
    final productId = tier.productId;
    if (productId == null) {
      debugPrint('Product ID is null for tier: $tier');
      return false;
    }
    
    // Check if product is loaded
    if (_products.isEmpty) {
      debugPrint('Products not loaded yet');
      return false;
    }
    
    try {
      final product = _products.firstWhere(
        (p) => p.id == productId,
        orElse: () => throw StateError('Product not found: $productId'),
      );
      
      final PurchaseParam purchaseParam = PurchaseParam(productDetails: product);
      
      // For auto-renewable subscriptions, use buyNonConsumable
      // The in_app_purchase package handles subscriptions this way
      await _inAppPurchase.buyNonConsumable(purchaseParam: purchaseParam);
      
      // Purchase status will be updated via the purchase stream
      return true;
    } catch (e) {
      debugPrint('Purchase error: $e');
      return false;
    }
  }
  
  /// Enable God mode - bypasses all paywalls (hidden feature)
  Future<void> enableGodMode() async {
    _godMode = true;
    await _secureStorage.write(key: 'god_mode', value: 'true');
    notifyListeners();
    debugPrint('GOD MODE: All paywalls bypassed');
  }
  
  /// Disable God mode - restore normal subscription checks
  Future<void> disableGodMode() async {
    _godMode = false;
    await _secureStorage.delete(key: 'god_mode');
    notifyListeners();
    debugPrint('GOD MODE: Disabled');
  }

  /// Check if God mode is active
  bool get isGodMode => _godMode;

  /// Toggle God mode (enable if off, disable if on)
  Future<void> toggleGodMode() async {
    if (_godMode) {
      await disableGodMode();
    } else {
      await enableGodMode();
    }
  }

  /// Restore previous purchases
  Future<void> restorePurchases() async {
    if (!_isAvailable) return;
    
    try {
      await _inAppPurchase.restorePurchases();
      // The purchase stream will handle restoration
    } catch (e) {
      debugPrint('Restore purchases error: $e');
    }
  }
  
  /// Start free trial
  Future<void> startFreeTrial() async {
    if (_godMode || isInTrial || _status == SubscriptionStatus.active) {
      return; // Already have access
    }
    
    _trialStartDate = DateTime.now();
    _status = SubscriptionStatus.trial;
    await _saveSubscription();
    notifyListeners();
    debugPrint('[SubscriptionService] Free trial started. Expires in $trialDurationDays days.');
  }
  
  /// Check if user can start free trial
  bool get canStartTrial {
    if (_godMode) return false;
    if (isInTrial) return false;
    if (_status == SubscriptionStatus.active) return false;
    // Check if user has used trial before
    final hasUsedTrial = _trialStartDate != null;
    return !hasUsedTrial;
  }
  
  /// Check if user can add more items
  bool canAddItem(int currentItemCount) {
    // God mode bypasses all limits
    if (_godMode) {
      return true;
    }
    // Trial provides unlimited access
    if (isInTrial) {
      return true;
    }
    if (_currentTier.isUnlimited) {
      return true;
    }
    return currentItemCount < _currentTier.maxItems;
  }
  
  /// Get items remaining (for free tier)
  int? getItemsRemaining(int currentItemCount) {
    // God mode bypasses all limits
    if (_godMode) {
      return null; // Unlimited
    }
    if (_currentTier.isUnlimited) {
      return null; // Unlimited
    }
    final remaining = _currentTier.maxItems - currentItemCount;
    return remaining > 0 ? remaining : 0;
  }
  
  /// Get the maximum number of items that can be viewed
  /// Returns null for unlimited viewing (users can always view all stored items)
  /// Note: This allows viewing all stored content even after subscription expires
  int? getMaxViewableItems() {
    // God mode bypasses all limits
    if (_godMode) {
      return null; // Unlimited
    }
    // Users can always view all stored items, even after subscription expires
    // The limit only applies to adding NEW items (handled by canAddItem)
    return null; // Unlimited viewing
  }
  
  /// Check if subscription is expired (not active unlimited)
  bool get isExpiredOrFree {
    if (_godMode) {
      return false;
    }
    if (isInTrial) {
      return false; // Trial provides unlimited access
    }
    return !(_currentTier.isUnlimited && _status == SubscriptionStatus.active);
  }
  
  /// Check if user can access browser feature
  /// Browser access requires unlimited subscription, active trial, or God mode
  bool get canAccessBrowser {
    if (_godMode) {
      return true;
    }
    if (isInTrial) {
      return true;
    }
    return _currentTier.isUnlimited && _status == SubscriptionStatus.active;
  }
  
  /// Check if user can extract media from browser
  /// Media extraction requires unlimited subscription, active trial, or God mode
  bool get canExtractMedia {
    if (_godMode) {
      return true;
    }
    if (isInTrial) {
      return true;
    }
    return _currentTier.isUnlimited && _status == SubscriptionStatus.active;
  }
}

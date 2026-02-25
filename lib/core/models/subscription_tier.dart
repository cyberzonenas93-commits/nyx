/// Subscription tier enum
enum SubscriptionTier {
  /// Free tier - limited to 5 items
  free,
  
  /// Monthly subscription - unlimited items
  monthly,
  
  /// Yearly subscription - unlimited items
  yearly,
}

extension SubscriptionTierExtension on SubscriptionTier {
  /// Check if tier allows unlimited storage
  bool get isUnlimited {
    return this != SubscriptionTier.free;
  }
  
  /// Get maximum items allowed for this tier
  int get maxItems {
    switch (this) {
      case SubscriptionTier.free:
        return 5;
      case SubscriptionTier.monthly:
      case SubscriptionTier.yearly:
        return -1; // Unlimited
    }
  }
  
  /// Get display name
  String get displayName {
    switch (this) {
      case SubscriptionTier.free:
        return 'Free';
      case SubscriptionTier.monthly:
        return 'Monthly';
      case SubscriptionTier.yearly:
        return 'Yearly';
    }
  }
  
  /// Get price string
  String get priceString {
    switch (this) {
      case SubscriptionTier.free:
        return 'Free';
      case SubscriptionTier.monthly:
        return '\$4.99/month';
      case SubscriptionTier.yearly:
        return '\$39.99/year';
    }
  }
  
  /// Get monthly equivalent price (for annual)
  String? get monthlyEquivalent {
    switch (this) {
      case SubscriptionTier.yearly:
        return '\$3.33/month';
      default:
        return null;
    }
  }
  
  /// Get savings percentage (for annual)
  int? get savingsPercentage {
    switch (this) {
      case SubscriptionTier.yearly:
        return 33; // 33% savings vs monthly
      default:
        return null;
    }
  }
  
  /// Get product ID for in-app purchase
  String? get productId {
    switch (this) {
      case SubscriptionTier.free:
        return null;
      case SubscriptionTier.monthly:
        return 'nyx_unlimited_monthly';
      case SubscriptionTier.yearly:
        return 'nyx_unlimited_yearly';
    }
  }
}

/// Subscription status
enum SubscriptionStatus {
  /// Active subscription
  active,
  
  /// Free trial active
  trial,
  
  /// Subscription expired or cancelled
  expired,
  
  /// Never subscribed (free tier)
  none,
}

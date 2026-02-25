# Subscription Expiry Behavior

## Current Implementation Status

### ⚠️ **Subscription Expiry Detection: NOT IMPLEMENTED**

The app currently does **not** automatically detect when a subscription expires. The `SubscriptionStatus.expired` enum exists but is never set automatically.

### What Happens When Subscription Expires

#### 1. **Subscription Status**
- **Current Behavior**: Status remains `active` until manually changed or restored
- **Issue**: App does not check expiration dates from Apple receipts
- **Impact**: App may show subscription as active even after it expires

#### 2. **Vault Items**
- **Current Behavior**: **All vault items remain accessible** ✓
- **Items are NOT deleted** when subscription expires
- **Items are NOT locked** when subscription expires
- **Users can still view, download, and access all existing items**

#### 3. **Adding New Items**
- **After Expiry**: User cannot add items beyond the free tier limit (5 items)
- **If user has 10 items and subscription expires**: 
  - All 10 items remain accessible
  - User cannot add new items until they delete down to 5 or resubscribe

#### 4. **Subscription Restoration**
- **If subscription renews or is restored**: User regains ability to add unlimited items
- **`restorePurchases()`** is called on app start and when user taps "Restore Purchases"
- **Purchase stream** handles restoration and updates subscription status

## Current Flow

### When Subscription Expires (User's Perspective)

1. **Subscription expires** (cancelled, payment failed, etc.)
2. **User opens app** - Subscription status is still `active` (if previously saved)
3. **User tries to add new item** - If over free limit (5 items), paywall appears
4. **All existing items remain accessible** - User can view, download, delete any existing items
5. **If user taps "Restore Purchases"** - App checks with Apple and updates status if subscription is still active

### What Happens to Vault Items

**✅ GOOD NEWS: All vault items are safe**

- **Encrypted files remain on device** - All encrypted files are stored locally
- **User can access all items** - No items are locked or deleted
- **User can download items** - All items can be downloaded
- **User can delete items** - User maintains full control

**The only limitation is adding NEW items beyond the free tier limit.**

## Missing Implementation

### Subscription Expiry Detection

Currently, the app does NOT:

1. **Check expiration dates from receipts**
   - Receipt validation is not implemented
   - Expiration dates are not checked
   - Status is not automatically updated to `expired`

2. **Monitor subscription status changes**
   - App doesn't listen for subscription expiry notifications
   - No periodic checks for subscription validity
   - Status is only updated when:
     - User purchases new subscription
     - User restores purchases
     - App starts and calls `restorePurchases()`

### Recommended Implementation (Optional)

To properly detect subscription expiry, you would need:

1. **Receipt Validation**
   - Validate receipts with Apple's servers
   - Check expiration dates from receipt data
   - Update subscription status to `expired` when needed

2. **Periodic Status Checks**
   - Check subscription status periodically (e.g., on app start)
   - Listen for App Store Server Notifications (optional)
   - Update status when subscription expires

3. **Status Update Logic**
   ```dart
   // Pseudo-code for expiry detection
   if (subscriptionStatus == SubscriptionStatus.active) {
     // Check receipt expiration date
     if (receiptExpirationDate < DateTime.now()) {
       _status = SubscriptionStatus.expired;
       _currentTier = SubscriptionTier.free;
       _saveSubscription();
       notifyListeners();
     }
   }
   ```

## User Experience After Expiry

### What Users Can Do

✅ **View all existing vault items**  
✅ **Download all existing items**  
✅ **Delete items**  
✅ **Access decoy vault** (if previously set up)  
✅ **View/delete up to 5 items** (free tier limit)

### What Users Cannot Do

❌ **Add new items if they have more than 5 items**  
❌ **Add items beyond the free tier limit**

### If User Resubscribes

✅ **Immediately regains ability to add unlimited items**  
✅ **All existing items remain accessible**  
✅ **Subscription status updates to `active`**

## Summary

### Subscription Expiry: Current Behavior

| Aspect | Behavior |
|--------|----------|
| **Vault Items** | ✅ All items remain accessible - **NOT deleted** |
| **Viewing Items** | ✅ User can view all existing items |
| **Downloading Items** | ✅ User can download all existing items |
| **Adding New Items** | ⚠️ Limited to 5 items (free tier) |
| **Expiry Detection** | ❌ Not automatically detected |
| **Status Update** | ⚠️ Only updates when restoring purchases or new purchase |

### Key Points

1. **Vault items are NEVER deleted** - This is a security/privacy feature. User's encrypted data is preserved.

2. **Subscription expiry is not automatically detected** - Status remains as last known state until:
   - User restores purchases (checks with Apple)
   - User purchases new subscription
   - Manual status check (not currently implemented)

3. **Free tier limit only affects NEW items** - Existing items are not affected.

4. **User data is preserved** - Even if subscription expires, all encrypted files remain accessible.

## Recommendations

### For MVP (Current Implementation)

**✅ This is acceptable for launch:**
- Items are not deleted (good for user trust)
- Free tier limit prevents abuse
- User can restore purchases to regain access
- Simpler implementation (no receipt validation needed)

### For Production (Optional Enhancement)

Consider adding:

1. **Receipt validation on app start** - Check if subscription is still active
2. **Periodic status checks** - Verify subscription status periodically
3. **App Store Server Notifications** - Listen for subscription status changes (requires backend)

However, the current implementation is **safe and user-friendly** - it prioritizes preserving user data over strict subscription enforcement.

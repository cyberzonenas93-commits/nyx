# Apple Subscription Setup Guide for Nyx

This guide will walk you through setting up in-app subscriptions in App Store Connect for the Nyx app.

## Product IDs

The app uses the following subscription product IDs:
- **Monthly Subscription**: `nyx_unlimited_monthly`
- **Yearly Subscription**: `nyx_unlimited_yearly`

## App Capabilities Required

When setting up your app in Xcode (Project Settings → Signing & Capabilities), you need to enable:

### ✅ Required:
- **In-App Purchase** - Required for subscriptions to work

### ⚠️ If "In-App Purchase" doesn't appear in Xcode:

The capability might not show up if:

1. **App ID not configured**: You must enable it in Apple Developer Portal first
   - Go to [developer.apple.com/account/resources/identifiers/list](https://developer.apple.com/account/resources/identifiers/list)
   - Find your App ID (or create one for your Bundle ID)
   - Edit it and check "In-App Purchase" capability
   - Save and regenerate provisioning profiles

2. **Wildcard Bundle ID**: Your Bundle ID cannot be a wildcard (e.g., `com.example.*`)
   - Must be explicit: `com.angelonartey.nyx`
   - Check in Xcode: Target → General → Bundle Identifier

3. **Paid Apps Agreement not signed**:
   - Go to App Store Connect → Agreements, Tax, and Banking
   - Complete the Paid Apps Agreement
   - Add banking and tax information

4. **Wrong permissions**: You need Admin or Account Holder role
   - Not just Team Member
   - Contact your account holder if needed

### ❌ Not Required (don't select these):
- Push Notifications
- HealthKit
- HomeKit
- Maps
- Background Modes
- Any other capabilities - the app only needs In-App Purchase

The app uses `flutter_secure_storage` which automatically handles keychain access, so you don't need to manually enable Keychain Sharing.

### Where to find it in Xcode:
1. Open `ios/Runner.xcworkspace` (not `.xcodeproj`) in Xcode
2. Select the **Runner** target in the left sidebar
3. Click the **Signing & Capabilities** tab
4. Click the **"+ Capability"** button (top left of the tab)
5. In the popup, type "In-App Purchase" or scroll to find it
6. Double-click it to add

**Note**: If you're looking at a list in App Store Connect, that's different - you need to configure it in Xcode first.

## Step-by-Step Setup

### Step 1: Access App Store Connect

1. Go to [App Store Connect](https://appstoreconnect.apple.com/)
2. Sign in with your Apple Developer account
3. Click on **"My Apps"** and select your **Nyx** app
   - If you haven't created the app yet, click **"+"** to create a new app

### Step 2: Navigate to Subscriptions

1. In your app's dashboard, click on **"Features"** tab
2. Scroll down to **"In-App Purchases"**
3. Click **"+"** to create a new in-app purchase
4. Select **"Auto-Renewable Subscription"**

### Step 3: Create Subscription Group

1. Create a new subscription group (or use existing)
   - Name it: **"Nyx Unlimited"**
   - This groups your subscriptions together

### Step 4: Create Monthly Subscription

1. Click **"+"** in your subscription group
2. Fill in the subscription details:

   **Reference Name**: `Nyx Unlimited - Monthly`
   
   **Product ID**: `nyx_unlimited_monthly` ⚠️ **Must match exactly**
   
   **Subscription Duration**: 1 Month

3. Click **"Create"**

4. **Set Pricing**:
   - Click on the subscription
   - Under **"Pricing and Availability"**
   - Click **"Add Subscription Pricing"**
   - Select **"United States"**
   - Set price to **$3.99**
   - Click **"Add"** and **"Save"**

5. **Add Subscription Display Information**:
   - **Subscription Display Name**: `Nyx Monthly`
   - **Description**: `Monthly subscription for unlimited storage in Nyx vault. Automatically renews monthly unless cancelled.`

### Step 5: Create Yearly Subscription

1. In the same subscription group, click **"+"** again
2. Fill in the subscription details:

   **Reference Name**: `Nyx Unlimited - Yearly`
   
   **Product ID**: `nyx_unlimited_yearly` ⚠️ **Must match exactly**
   
   **Subscription Duration**: 1 Year

3. Click **"Create"**

4. **Set Pricing**:
   - Click on the subscription
   - Under **"Pricing and Availability"**
   - Click **"Add Subscription Pricing"**
   - Select **"United States"**
   - Set price to **$39.99**
   - Click **"Add"** and **"Save"**

5. **Set Free Trial**:
   - Scroll to **"Subscription Duration"** section
   - Find **"Free Trial"** option (may be labeled as "Introductory Offer" or "Free Trial")
   - Click **"Edit"** or **"+"** next to Free Trial
   - Select **"7 days"** from the dropdown
   - Click **"Save"**
   - **Note**: If you don't see the Free Trial option, ensure the subscription status is "Ready to Submit" and your Paid Apps Agreement is completed

6. **Add Subscription Display Information**:
   - **Subscription Display Name**: `Nyx Premium - Annual (Best Value)`
   - **Description**: `Try free for 7 days, then $39.99/year ($3.33/month). Best value - save 33% compared to monthly. Unlimited storage for photos, videos, and documents. Access to browser, media downloads, WiFi transfer, and all premium features. Automatically renews yearly unless cancelled at least 24 hours before the end of the current period.`

### Step 6: Configure Subscription Group

1. Go to your **"Nyx Unlimited"** subscription group
2. Set the **"Subscription Group Name"**: `Nyx Unlimited`
3. Arrange subscriptions (Yearly should be above Monthly for better visibility)

### Step 7: Add Localizations (Optional but Recommended)

For each subscription, add localization:
1. Click on the subscription
2. Scroll to **"Localizations"**
3. Click **"+"** to add languages
4. Add at minimum:
   - **English (U.S.)**
   - **Display Name**: `Nyx Monthly` or `Nyx Yearly`
   - **Description**: Subscription description

### Step 8: Review and Submit

1. Review all subscription information
2. Ensure product IDs match exactly:
   - `nyx_unlimited_monthly`
   - `nyx_unlimited_yearly`
3. Ensure pricing is set correctly:
   - Monthly: $4.99 (with 7-day free trial)
   - Yearly: $39.99 (with 7-day free trial)
4. Click **"Save"** on each subscription

### Step 9: Testing in Sandbox

1. In App Store Connect, go to **"Users and Access"**
2. Click **"Sandbox Testers"**
3. Create a test account:
   - Email: `test.nyx@example.com` (use your own email domain)
   - Password: (choose a test password)
   - Country: United States
4. **Important**: Use this test account on a device to test purchases
   - Sign out of your real Apple ID on the device
   - When prompted during purchase, sign in with sandbox account

### Step 10: Enable In-App Purchases in Your App

1. In your app's **"App Information"** tab
2. Scroll to **"App Store Information"**
3. Ensure **"In-App Purchases"** is enabled

### Step 11: Enable In-App Purchase Capability

**Option A: Enable in Apple Developer Portal (Recommended First Step)**

1. Go to [developer.apple.com/account/resources/identifiers/list](https://developer.apple.com/account/resources/identifiers/list)
2. Find your App ID (Bundle ID: `com.angelonartey.nyx`) or create a new one
3. Click on it to edit
4. Scroll down to **Capabilities**
5. Check the box for **In-App Purchase**
6. Click **Save**
7. This enables the capability for your App ID

**Option B: Enable in Xcode**

1. Open `ios/Runner.xcworkspace` in Xcode (NOT `.xcodeproj`)
2. Select the **Runner** target in the left sidebar
3. Click the **Signing & Capabilities** tab
4. Click **"+ Capability"** button (top left)
5. Search for or scroll to find **In-App Purchase**
6. Double-click it to add (or click once then click outside the popup)
7. You should see "In-App Purchase" appear in your capabilities list

**Note**: If it still doesn't appear, make sure:
- Your Bundle ID is explicit (not wildcard)
- You've completed Paid Apps Agreement in App Store Connect
- You have Admin or Account Holder role on the developer account

### Step 12: Build and Test

1. Build your app with the subscriptions configured
2. Test in sandbox mode using the sandbox test account
3. Verify:
   - Products load correctly
   - Purchases complete successfully
   - Subscription status updates correctly
   - Restore purchases works

## Important Notes

⚠️ **Product IDs Must Match Exactly**
- The product IDs in App Store Connect must exactly match:
  - `nyx_unlimited_monthly`
  - `nyx_unlimited_yearly`
- Any mismatch will cause purchases to fail

⚠️ **Sandbox Testing**
- All purchases in sandbox are free
- Use sandbox test accounts, not your real Apple ID
- Sandbox subscriptions expire after short periods (1 minute for testing)

⚠️ **Production Release**
- Subscriptions must be approved before going live
- Review process typically takes 1-2 days
- Once approved, real customers can purchase

## Troubleshooting

**Products not loading?**
- Verify product IDs match exactly
- Ensure subscriptions are in "Ready to Submit" status
- Check that app is signed with correct provisioning profile

**Purchase fails?**
- Verify you're using a sandbox account for testing
- Check internet connection
- Ensure subscriptions are approved in App Store Connect

**Restore purchases not working?**
- Ensure sandbox account has made test purchases
- Check that purchase history is being queried correctly

## Additional Resources

- [Apple In-App Purchase Documentation](https://developer.apple.com/in-app-purchase/)
- [App Store Connect Help](https://help.apple.com/app-store-connect/)
- [Testing In-App Purchases](https://developer.apple.com/documentation/storekit/in-app_purchase/testing_in-app_purchases_with_sandbox)

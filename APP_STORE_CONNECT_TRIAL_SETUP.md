# App Store Connect - Free Trial Setup Guide

## Overview
This guide walks you through enabling the 7-day free trial for both monthly and annual subscriptions in App Store Connect.

## Prerequisites
- App Store Connect account with Admin or Account Holder access
- Subscriptions already created (Monthly and Annual)
- Paid Apps Agreement completed

## Step-by-Step: Enable Free Trial

### Step 1: Access Your Subscriptions

1. Go to [App Store Connect](https://appstoreconnect.apple.com/)
2. Sign in with your Apple Developer account
3. Click **"My Apps"** → Select **"Nyx"**
4. Click **"Features"** tab
5. Scroll to **"In-App Purchases"**
6. Click on your subscription group (e.g., **"Nyx Unlimited"**)

### Step 2: Enable Free Trial for Monthly Subscription

1. Click on **"Nyx Unlimited - Monthly"** subscription
2. Scroll down to **"Subscription Duration"** section
3. Find **"Free Trial"** option
4. Click **"Edit"** or **"+"** next to Free Trial
5. Select **"7 days"** from the dropdown
6. Click **"Save"**

**Visual Guide:**
```
Subscription Duration
├── Duration: 1 Month
└── Free Trial: [Edit] → Select "7 days" → Save
```

### Step 3: Enable Free Trial for Annual Subscription

1. Click on **"Nyx Unlimited - Yearly"** subscription
2. Scroll down to **"Subscription Duration"** section
3. Find **"Free Trial"** option
4. Click **"Edit"** or **"+"** next to Free Trial
5. Select **"7 days"** from the dropdown
6. Click **"Save"**

**Note:** Both subscriptions should have the same free trial duration (7 days).

### Step 4: Verify Free Trial is Enabled

For each subscription, verify:
- ✅ Free Trial shows "7 days"
- ✅ Status is "Ready to Submit" or "Waiting for Review"
- ✅ No errors or warnings displayed

## Step-by-Step: Update Subscription Descriptions

### Step 1: Update Monthly Subscription Description

1. In **"Nyx Unlimited - Monthly"** subscription
2. Scroll to **"Subscription Display Information"** section
3. Click **"Edit"** next to **"Description"**
4. Update the description to:

```
Try free for 7 days, then $4.99/month. Unlimited storage for photos, videos, and documents. Access to browser, media downloads, WiFi transfer, and all premium features. Automatically renews monthly unless cancelled at least 24 hours before the end of the current period.
```

5. Click **"Save"**

### Step 2: Update Annual Subscription Description

1. In **"Nyx Unlimited - Yearly"** subscription
2. Scroll to **"Subscription Display Information"** section
3. Click **"Edit"** next to **"Description"**
4. Update the description to:

```
Try free for 7 days, then $39.99/year ($3.33/month). Best value - save 33% compared to monthly. Unlimited storage for photos, videos, and documents. Access to browser, media downloads, WiFi transfer, and all premium features. Automatically renews yearly unless cancelled at least 24 hours before the end of the current period.
```

5. Click **"Save"**

### Step 3: Update Subscription Display Names (Optional but Recommended)

**Monthly Display Name:**
```
Nyx Premium - Monthly
```

**Annual Display Name:**
```
Nyx Premium - Annual (Best Value)
```

## Alternative Description Options

### Option 1: Concise Version

**Monthly:**
```
7-day free trial, then $4.99/month. Unlimited storage and all premium features. Cancel anytime.
```

**Annual:**
```
7-day free trial, then $39.99/year. Save 33% vs monthly. Unlimited storage and all premium features. Cancel anytime.
```

### Option 2: Feature-Focused Version

**Monthly:**
```
Start with a 7-day free trial. Then $4.99/month for unlimited storage, private browser with media downloads, WiFi file transfer, media converter, and all premium features. Automatically renews monthly.
```

**Annual:**
```
Start with a 7-day free trial. Then $39.99/year ($3.33/month) for unlimited storage, private browser with media downloads, WiFi file transfer, media converter, and all premium features. Save 33% compared to monthly. Automatically renews yearly.
```

### Option 3: Value-Focused Version

**Monthly:**
```
Try Premium free for 7 days! Then $4.99/month for unlimited secure storage, browser access, media tools, and all premium features. No commitment - cancel anytime.
```

**Annual:**
```
Try Premium free for 7 days! Then $39.99/year ($3.33/month) for unlimited secure storage, browser access, media tools, and all premium features. Best value - save 33% vs monthly. No commitment - cancel anytime.
```

## Important Notes

### Free Trial Behavior
- **Trial starts immediately** when user subscribes
- **No charge** during the 7-day trial period
- **Auto-converts** to paid subscription after trial ends
- **User can cancel** during trial to avoid charges
- **One trial per user** (Apple tracks this automatically)

### Description Requirements
- Must mention the free trial period
- Must include pricing after trial
- Must mention auto-renewal
- Must mention cancellation policy
- Keep under 170 characters for best display (though longer descriptions are allowed)

### Testing Free Trial
1. Use **Sandbox Test Account** (not your real Apple ID)
2. Create test account in App Store Connect → Users and Access → Sandbox Testers
3. Sign out of your real Apple ID on test device
4. When prompted during purchase, sign in with sandbox account
5. Trial will be active immediately (no charge)
6. Trial expires after 1 minute in sandbox (for testing purposes)

## Troubleshooting

### Free Trial Option Not Showing?
- **Check subscription status**: Must be "Ready to Submit" or "Waiting for Review"
- **Check Paid Apps Agreement**: Must be completed
- **Check account permissions**: Need Admin or Account Holder role
- **Try refreshing**: Sometimes UI needs refresh to show options

### Description Not Saving?
- **Check character limit**: Descriptions can be long, but check for errors
- **Check required fields**: All required fields must be filled
- **Try different browser**: Sometimes browser cache causes issues
- **Check for special characters**: Some characters may cause issues

### Trial Not Working in App?
- **Verify product IDs match**: Must match exactly (`nyx_unlimited_monthly`, `nyx_unlimited_yearly`)
- **Check subscription status**: Must be approved in App Store Connect
- **Test in sandbox**: Use sandbox account for testing
- **Check app code**: Verify trial logic is implemented correctly

## Verification Checklist

Before submitting for review, verify:

- [ ] Monthly subscription has 7-day free trial enabled
- [ ] Annual subscription has 7-day free trial enabled
- [ ] Monthly description mentions "7-day free trial"
- [ ] Annual description mentions "7-day free trial"
- [ ] Both descriptions include pricing after trial
- [ ] Both descriptions mention auto-renewal
- [ ] Both descriptions mention cancellation policy
- [ ] Subscription status is "Ready to Submit"
- [ ] No errors or warnings displayed
- [ ] Tested in sandbox environment

## After Enabling Free Trial

1. **Submit for Review**: Once trial is enabled and descriptions updated, submit subscriptions for review
2. **Wait for Approval**: Apple typically reviews subscriptions within 1-2 days
3. **Test in Sandbox**: Use sandbox account to test trial flow
4. **Monitor**: Check subscription analytics in App Store Connect

## Additional Resources

- [Apple Subscription Documentation](https://developer.apple.com/in-app-purchase/)
- [App Store Connect Help](https://help.apple.com/app-store-connect/)
- [Testing Subscriptions Guide](https://developer.apple.com/documentation/storekit/in-app_purchase/testing_in-app_purchases_with_sandbox)

---

**Quick Reference:**
- **Free Trial Duration**: 7 days
- **Monthly Price**: $4.99/month (after trial)
- **Annual Price**: $39.99/year (after trial)
- **Product IDs**: `nyx_unlimited_monthly`, `nyx_unlimited_yearly`

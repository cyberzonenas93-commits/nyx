# Quick Setup Guide - Based on Your Current App Store Connect View

## Current Status
From your screenshots, I can see:
- ✅ Both subscriptions are created (Monthly and Annual)
- ✅ They're in the "Nyx Unlimited" group
- ⚠️ Both show "Missing Metadata" status (yellow warning)
- 📝 Monthly subscription has localization with "Nyx Unlimited" display name

## Step 1: Enable 7-Day Free Trial

### For Monthly Subscription:

1. **You're currently on:** Monthly subscription page (`/subscriptions/6757954987`)
2. **Scroll down** to find **"Subscription Duration"** section
3. Look for **"Free Trial"** or **"Introductory Offers"** section
   - It may be below the "Subscription Duration" dropdown
   - Or in a separate section called "Introductory Offers"
4. **Click "Edit"** or **"+"** next to Free Trial
5. **Select "7 days"** from the dropdown
6. **Click "Save"** (top right)

**If you don't see Free Trial option:**
- Make sure you've scrolled down past the "Availability" section
- It might be labeled as "Introductory Offer" instead
- Check if there's a "+" button to add an introductory offer

### For Annual Subscription:

1. **Go back** to the subscription group page (click "< Subscriptions" breadcrumb)
2. **Click on "Annual subscription"** (the second row in the table)
3. **Repeat the same steps** as above to enable 7-day free trial

## Step 2: Update Subscription Descriptions

### For Monthly Subscription (Current Page):

1. **You're already on the right page** - Monthly subscription detail page
2. **Scroll to "Localization" section** (you can see it in your screenshot)
3. **Click on "English (U.S.)"** row in the table
4. **Update the "Subscription Description"** field:

**Current:** `Store unlimited photos, videos, and documents securely`

**Replace with:**
```
Try free for 7 days, then $4.99/month. Unlimited storage for photos, videos, and documents. Access to browser, media downloads, WiFi transfer, and all premium features. Automatically renews monthly unless cancelled at least 24 hours before the end of the current period.
```

5. **Click "Save"** (top right)

### For Annual Subscription:

1. **Go to Annual subscription page** (click "< Subscriptions" → "Annual subscription")
2. **Scroll to "Localization" section**
3. **Click on "English (U.S.)"** row
4. **Update the "Subscription Description"** field:

**Replace with:**
```
Try free for 7 days, then $39.99/year ($3.33/month). Best value - save 33% compared to monthly. Unlimited storage for photos, videos, and documents. Access to browser, media downloads, WiFi transfer, and all premium features. Automatically renews yearly unless cancelled at least 24 hours before the end of the current period.
```

5. **Click "Save"**

## Step 3: Update Display Names (Optional but Recommended)

### Monthly Subscription:
- **Display Name:** Change from "Nyx Unlimited" to `Nyx Premium - Monthly`

### Annual Subscription:
- **Display Name:** Change to `Nyx Premium - Annual (Best Value)`

## Step 4: Fix "Missing Metadata" Status

The yellow "Missing Metadata" warning means you need to complete required fields. After updating:

1. ✅ **Free Trial** - Enable 7 days
2. ✅ **Description** - Update with trial information
3. ✅ **Display Name** - Update (optional but recommended)
4. ✅ **Pricing** - Should already be set ($4.99/$39.99)

After completing these, the status should change from "Missing Metadata" to "Ready to Submit".

## Visual Guide Based on Your Screenshot

From your current page view:

```
┌─────────────────────────────────────────┐
│ Monthly subscription                    │
│                                         │
│ [Availability Section]                 │
│ ✓ 170 of 175 countries selected        │
│                                         │
│ [Subscription Duration] ← LOOK HERE    │
│ Duration: 1 month                       │
│ Free Trial: [Edit] → Select "7 days"    │
│                                         │
│ [Subscription Prices]                   │
│ Current Pricing...                      │
│                                         │
│ [Localization] ← UPDATE HERE            │
│ English (U.S.)                          │
│ Display Name: Nyx Premium - Monthly     │
│ Description: [Update with trial info]   │
└─────────────────────────────────────────┘
```

## Quick Checklist

### Monthly Subscription:
- [ ] Enable 7-day free trial
- [ ] Update description to mention trial
- [ ] Update display name (optional)
- [ ] Click Save

### Annual Subscription:
- [ ] Enable 7-day free trial
- [ ] Update description to mention trial
- [ ] Update display name (optional)
- [ ] Click Save

### Both:
- [ ] Verify status changes from "Missing Metadata" to "Ready to Submit"
- [ ] Submit for review when ready

## Troubleshooting

**Can't find Free Trial option?**
- It might be under "Introductory Offers" instead
- Make sure subscription status allows editing
- Try refreshing the page

**Description too long?**
- Apple allows longer descriptions, but you can use the concise version:
  - Monthly: `7-day free trial, then $4.99/month. Unlimited storage and all premium features. Cancel anytime.`
  - Annual: `7-day free trial, then $39.99/year. Save 33% vs monthly. Unlimited storage and all premium features. Cancel anytime.`

**Status still shows "Missing Metadata"?**
- Make sure all required fields are filled
- Check that pricing is set
- Verify localization is complete
- Try saving again

## After Setup

Once both subscriptions have:
- ✅ 7-day free trial enabled
- ✅ Updated descriptions
- ✅ Status shows "Ready to Submit"

You can submit them for review. Apple typically reviews within 1-2 days.

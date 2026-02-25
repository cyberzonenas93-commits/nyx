# iCloud Backup Setup for Nyx

This guide explains how to enable iCloud backup for vault data so it can be restored when switching devices.

## Overview

The app now stores vault data in iCloud Drive, allowing automatic backup and sync across devices. When you set up the app on a new device with the same Apple ID, your vault data will be automatically restored.

## Xcode Configuration

### Step 1: Enable iCloud Capability

1. Open `ios/Runner.xcworkspace` in Xcode
2. Select the **Runner** target
3. Go to **Signing & Capabilities** tab
4. Click **"+ Capability"**
5. Add **iCloud** capability
6. Under iCloud, check **CloudKit** (or **iCloud Documents**)

### Step 2: Configure iCloud Container

1. In the **Signing & Capabilities** tab, under iCloud:
2. Click **"+ Container"**
3. Select or create: `iCloud.com.angelonartey.nyx`
4. Ensure the container identifier matches your Bundle ID

### Step 3: Verify Entitlements

The `ios/Runner/Runner.entitlements` file should contain:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.$(CFBundleIdentifier)</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudDocuments</string>
</array>
```

## How It Works

1. **Automatic Backup**: Vault data is stored in iCloud Drive and automatically synced
2. **Device Transfer**: When you install the app on a new device:
   - Sign in with the same Apple ID
   - Open the app and unlock with your PIN
   - Vault data will be automatically restored from iCloud
3. **Fallback**: If iCloud is not available (e.g., not signed in), the app falls back to local storage

## Requirements

- iOS device signed in to iCloud
- iCloud Drive enabled in Settings
- Sufficient iCloud storage space
- Same Apple ID on all devices

## Privacy & Security

- All vault data remains encrypted with your PIN
- iCloud only stores encrypted files
- Your PIN is never stored in iCloud
- Zero-knowledge architecture maintained

## Troubleshooting

### Vault data not syncing

1. Check iCloud Drive is enabled: Settings → [Your Name] → iCloud → iCloud Drive
2. Ensure you're signed in with the same Apple ID
3. Check available iCloud storage space
4. Wait a few minutes for sync to complete

### iCloud not available

- The app will automatically use local storage
- Your data is still secure and encrypted
- You can manually export/import if needed

## Testing

1. Add files to vault on Device A
2. Wait for iCloud sync (usually within minutes)
3. Install app on Device B with same Apple ID
4. Sign in and unlock with PIN
5. Vault data should appear automatically

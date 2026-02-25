# iOS Setup Guide for Nyx

This guide covers the complete iOS setup for the Nyx app, including configuration, permissions, and App Store requirements.

## Prerequisites

- macOS with Xcode installed (latest version recommended)
- Apple Developer Account ($99/year)
- CocoaPods installed (`sudo gem install cocoapods`)

## Initial Setup

### 1. Install Dependencies

```bash
cd ios
pod install
cd ..
```

### 2. Open in Xcode

```bash
open ios/Runner.xcworkspace
```

**Important**: Always open `.xcworkspace`, not `.xcodeproj`

## Bundle Identifier Configuration

### Step 1: Set Bundle ID in Xcode

1. Open `ios/Runner.xcworkspace` in Xcode
2. Select **Runner** target in the left sidebar
3. Go to **General** tab
4. Under **Identity**, set **Bundle Identifier** to:
   ```
   com.angelonartey.nyx
   ```

### Step 2: Create App ID in Apple Developer Portal

1. Go to [developer.apple.com/account/resources/identifiers/list](https://developer.apple.com/account/resources/identifiers/list)
2. Click **"+"** to create a new App ID
3. Select **App** type
4. Enter:
   - **Description**: `Nyx`
   - **Bundle ID**: `com.angelonartey.nyx` (must match Xcode)
5. Enable **In-App Purchase** capability
6. Click **Continue** and **Register**

## Capabilities Setup

### Required Capabilities

In Xcode, go to **Signing & Capabilities** tab and add:

1. **In-App Purchase**
   - Click **"+ Capability"**
   - Add **In-App Purchase**
   - Required for subscriptions

### Optional Capabilities (Not Required)

- Keychain Sharing (handled automatically by `flutter_secure_storage`)
- Push Notifications (not used)
- Background Modes (optional, for encryption processing)

## Permissions Configuration

All permissions are configured in `ios/Runner/Info.plist`:

### ✅ Already Configured:

- **Photo Library Access** (`NSPhotoLibraryUsageDescription`)
- **Photo Library Add** (`NSPhotoLibraryAddUsageDescription`)
- **Camera Access** (`NSCameraUsageDescription`)
- **Face ID** (`NSFaceIDUsageDescription`)

### Security Settings:

- **Portrait-only orientation** (enforced)
- **Screenshot prevention** (handled in AppDelegate)
- **Background processing** (for encryption)

## Signing & Certificates

### Step 1: Automatic Signing (Recommended)

1. In Xcode, select **Runner** target
2. Go to **Signing & Capabilities** tab
3. Check **"Automatically manage signing"**
4. Select your **Team** (Apple Developer account)
5. Xcode will automatically create certificates and provisioning profiles

### Step 2: Manual Signing (If Needed)

If automatic signing fails:

1. Uncheck **"Automatically manage signing"**
2. Download certificates from Apple Developer Portal
3. Import into Keychain
4. Select appropriate provisioning profile

## App Store Connect Setup

### Step 1: Create App Record

1. Go to [App Store Connect](https://appstoreconnect.apple.com/)
2. Click **"My Apps"** → **"+"** → **"New App"**
3. Fill in:
   - **Platform**: iOS
   - **Name**: `Nyx`
   - **Primary Language**: English (U.S.)
   - **Bundle ID**: Select the App ID you created
   - **SKU**: `nyx-app` (or your preferred SKU)
   - **User Access**: Full Access

### Step 2: Complete App Information

1. **App Information**:
   - Category: Utilities or Productivity
   - Privacy Policy URL: (required for App Store)
   
2. **Pricing and Availability**:
   - Set price (Free with in-app purchases)
   - Select countries

3. **App Privacy**:
   - Declare data collection practices
   - Since Nyx uses zero-knowledge encryption, you can state:
     - No data collected
     - All data encrypted on-device

## Build Configuration

### Debug Build

```bash
flutter build ios --debug
```

### Release Build

```bash
flutter build ios --release
```

### Archive for App Store

1. Open `ios/Runner.xcworkspace` in Xcode
2. Select **Any iOS Device** as target
3. Go to **Product** → **Archive**
4. Wait for archive to complete
5. Click **Distribute App**
6. Follow prompts to upload to App Store Connect

## Testing

### Simulator Testing

```bash
flutter run -d ios
```

### Physical Device Testing

1. Connect iPhone via USB
2. Trust the computer on iPhone
3. In Xcode, select your device
4. Run the app

**Note**: In-app purchases require:
- Physical device (not simulator)
- Sandbox test account
- TestFlight or development build

## In-App Purchase Setup

See `APPLE_SUBSCRIPTION_SETUP.md` for detailed subscription configuration.

### Quick Checklist:

- ✅ In-App Purchase capability enabled
- ✅ Product IDs configured:
  - `nyx_unlimited_monthly`
  - `nyx_unlimited_yearly`
- ✅ Subscriptions created in App Store Connect
- ✅ Sandbox test account created

## Security Features

### Screenshot Prevention

The app includes screenshot prevention when:
- App goes to background
- User switches apps
- Screen recording is detected

This is handled in `AppDelegate.swift` with a security overlay.

### Encryption

- All files encrypted with AES-256-GCM
- Keys derived using PBKDF2
- No plaintext data stored
- Zero-knowledge architecture

## Troubleshooting

### "In-App Purchase capability not found"

1. Enable in Apple Developer Portal first
2. Then add in Xcode
3. Clean build folder: `Product` → `Clean Build Folder`

### "No provisioning profile found"

1. Check Team is selected in Signing & Capabilities
2. Ensure Bundle ID matches App ID in Developer Portal
3. Try automatic signing first

### "Products not loading"

1. Ensure subscriptions are created in App Store Connect
2. Product IDs must match exactly
3. Test on physical device (not simulator)
4. Use sandbox test account

### Build Errors

```bash
# Clean and rebuild
cd ios
rm -rf Pods Podfile.lock
pod install
cd ..
flutter clean
flutter pub get
flutter build ios
```

## Version Information

- **Minimum iOS Version**: 13.0
- **Target iOS Version**: Latest
- **Flutter Version**: 3.0.0+
- **Xcode Version**: 14.0+

## Next Steps

1. ✅ Complete App Store Connect setup
2. ✅ Configure subscriptions (see `APPLE_SUBSCRIPTION_SETUP.md`)
3. ✅ Test on physical device
4. ✅ Submit for App Store review

## Resources

- [Apple Developer Documentation](https://developer.apple.com/documentation/)
- [App Store Connect Help](https://help.apple.com/app-store-connect/)
- [Flutter iOS Setup](https://docs.flutter.dev/deployment/ios)

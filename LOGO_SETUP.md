# Nyx Logo Setup Guide

## Step 1: Save the Logo Image

You need to save the Nyx logo image you have to:
```
assets/icon/icon.png
```

**Requirements:**
- Format: PNG (transparent background preferred)
- Size: 1024x1024 pixels (minimum)
- Quality: High resolution

If your logo image is larger than 1024x1024, that's fine - it will be automatically resized.

## Step 2: Generate Icons and Splash Screen

Once the logo file is saved at `assets/icon/icon.png`, run these commands:

```bash
# Generate app icons for iOS and Android
flutter pub run flutter_launcher_icons

# Generate splash screen for iOS and Android
flutter pub run flutter_native_splash:create
```

This will:
- ✅ Generate all icon sizes for iOS and Android
- ✅ Create a splash screen with the Nyx logo
- ✅ Update AndroidManifest.xml to use the new icon
- ✅ Update iOS Assets to include the new icon
- ✅ Configure launch screens for both platforms

## Step 3: Verify

After running the commands:

1. **Check Android**: The app icon should now be the Nyx logo instead of the generic Flutter icon
2. **Check iOS**: The app icon should now be the Nyx logo
3. **Check Splash Screen**: When you launch the app, you should see the Nyx logo centered on a dark background (`#0E0E11`)

## Current Configuration

The `pubspec.yaml` is configured with:
- **App Icon**: `assets/icon/icon.png`
- **Splash Screen**: Same logo image
- **Background Color**: `#0E0E11` (dark charcoal, matching app theme)
- **Adaptive Icon Background**: `#0E0E11`

## Troubleshooting

If icons don't update:
1. Uninstall the app from your device/emulator
2. Run `flutter clean`
3. Run the icon generation commands again
4. Rebuild and install the app

## Files That Will Be Modified

After running the commands, these files will be automatically updated:
- `android/app/src/main/res/mipmap-*/` (icon images)
- `android/app/src/main/res/drawable/launch_background.xml` (splash screen)
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/` (iOS icons)
- `ios/Runner/Base.lproj/LaunchScreen.storyboard` (iOS splash screen)

## Notes

- The splash screen will show the logo centered on a dark background
- The app icon will be automatically generated for all required sizes
- iOS and Android will use the same logo for consistency
- The dark theme (`#0E0E11`) matches your app's design

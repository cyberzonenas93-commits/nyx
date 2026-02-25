# Update Splash Screen Only

## Current Setup

- **App Icon**: Uses `assets/icon/icon.png` (stays the same)
- **Splash Screen**: Will use `assets/icon/splash.png` (new transparent logo)

## Step 1: Save Transparent Logo for Splash Screen

Save your transparent Nyx logo as:
```
assets/icon/splash.png
```

**Requirements:**
- Format: PNG with transparent background
- Size: 1024x1024 pixels (or larger - will be resized automatically)
- This will be used ONLY for the splash screen

**Important:** Keep `assets/icon/icon.png` as is - this is still used for the app icon.

## Step 2: Regenerate Splash Screens

After saving `splash.png`, run:

```bash
flutter pub run flutter_native_splash:create
```

This will:
- ✅ Update splash screens with transparent logo
- ✅ Keep app icons unchanged (still using `icon.png`)

## Step 3: Clean and Rebuild

```bash
flutter clean
flutter run
```

## What Changes

**Splash Screen:**
- Will use the new transparent logo from `splash.png`
- Logo appears on dark background (`#0E0E11`)
- Transparent areas show the dark background

**App Icon:**
- Stays the same (uses `icon.png`)
- No changes to app icon on home screen

## Current Configuration

In `pubspec.yaml`:
- `flutter_launcher_icons.image_path`: `assets/icon/icon.png` (app icon)
- `flutter_native_splash.image`: `assets/icon/splash.png` (splash screen)

These are now separate, so you can update the splash screen independently!

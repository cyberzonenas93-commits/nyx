# Splash Screen Setup for Nyx

## Current Configuration ✅

The `flutter_native_splash` package is already configured in `pubspec.yaml`:

```yaml
flutter_native_splash:
  color: "#0E0E11"
  image: assets/icon/icon.png
  color_dark: "#0E0E11"
  image_dark: assets/icon/icon.png
  android_12:
    color: "#0E0E11"
    image: assets/icon/icon.png
    color_dark: "#0E0E11"
    image_dark: assets/icon/icon.png
  ios: true
  android: true
  web: false
  remove: true
```

## Next Steps

### Step 1: Add Logo Image

You need to save your Nyx logo image to:
```
assets/icon/icon.png
```

**Requirements:**
- Format: PNG
- Size: 1024x1024 pixels (recommended)
- Background: Transparent (recommended)
- The logo should be centered and visible on a dark background (`#0E0E11`)

### Step 2: Generate Splash Screens

Once `assets/icon/icon.png` exists, run:

```bash
flutter pub run flutter_native_splash:create
```

This command will:
- ✅ Generate splash screen images for all Android densities
- ✅ Update `android/app/src/main/res/drawable/launch_background.xml`
- ✅ Update `ios/Runner/Base.lproj/LaunchScreen.storyboard`
- ✅ Configure Android 12+ splash screens
- ✅ Set up iOS splash screen with your logo

### Step 3: Verify

After running the command, check:

**Android:**
- `android/app/src/main/res/drawable/launch_background.xml` should show your logo
- `android/app/src/main/res/mipmap-*/` should contain splash images

**iOS:**
- `ios/Runner/Base.lproj/LaunchScreen.storyboard` should be updated with your logo
- `ios/Runner/Assets.xcassets/LaunchImage.imageset/` should contain splash images

### Configuration Details

**Background Color:** `#0E0E11` (dark charcoal, matches app theme)
**Logo Image:** Centered on the background
**Platforms:** iOS and Android (web disabled)
**Android 12+:** Configured with same logo and colors

### Troubleshooting

If splash screens don't appear:
1. Make sure `assets/icon/icon.png` exists before running the command
2. Run `flutter clean` if icons don't update
3. Rebuild the app completely (`flutter run` or build from scratch)
4. On iOS, ensure `LaunchScreen.storyboard` is set in `Info.plist` (already configured)

### Current Status

✅ Package installed: `flutter_native_splash: ^2.3.10`
✅ Configuration added to `pubspec.yaml`
⏳ Waiting for `assets/icon/icon.png` file
⏳ Waiting for splash screen generation command

Once you add the logo file and run `flutter pub run flutter_native_splash:create`, the splash screens will be automatically configured!

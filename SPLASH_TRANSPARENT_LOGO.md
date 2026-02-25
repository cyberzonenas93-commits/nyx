# Using Transparent Logo for Splash Screen

## Current Setup

Your `pubspec.yaml` is already configured to use the logo at `assets/icon/icon.png` for the splash screen. The configuration includes:

- **Background color**: `#0E0E11` (dark charcoal)
- **Logo image**: `assets/icon/icon.png`
- Works on both iOS and Android

## Steps to Use Transparent Logo

### Step 1: Save the Transparent Logo

Save your transparent Nyx logo as:
```
assets/icon/icon.png
```

**Requirements:**
- Format: PNG with transparency
- Size: 1024x1024 pixels (or larger - will be resized)
- Make sure it's transparent (no background)

### Step 2: Regenerate Splash Screens

Once you've saved the transparent logo, run:

```bash
flutter pub run flutter_native_splash:create
```

This will regenerate all splash screens with your transparent logo on the dark background (`#0E0E11`).

### Step 3: Clean and Rebuild (Important!)

After regenerating, clean and rebuild to see changes:

```bash
flutter clean
flutter run
```

## How It Will Look

With a transparent logo:
- **Background**: Dark charcoal (`#0E0E11`) - solid color
- **Logo**: Your transparent Nyx logo (shield with moon and stars)
- **Result**: Clean logo on dark background, no white box around it

This is perfect for the Nyx brand - the logo will look great on the dark background!

## Current Configuration

The splash screen is configured in `pubspec.yaml`:
```yaml
flutter_native_splash:
  color: "#0E0E11"
  image: assets/icon/icon.png
  ...
```

This setup will work perfectly with your transparent logo.

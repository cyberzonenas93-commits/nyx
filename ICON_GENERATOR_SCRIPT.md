# Quick Icon Generation Guide

## Option 1: Using flutter_launcher_icons (Recommended)

1. **Create or obtain a 1024x1024 PNG icon**
   - Design it following `ICON_DESIGN.md`
   - Save as `assets/icon/icon.png`

2. **Configure pubspec.yaml** (already done)
   - The `flutter_launcher_icons` package is already added

3. **Add icon configuration to pubspec.yaml**:
   ```yaml
   flutter_launcher_icons:
     android: true
     ios: true
     image_path: "assets/icon/icon.png"
     min_sdk_android: 21
     remove_alpha_ios: true
   ```

4. **Generate icons**:
   ```bash
   flutter pub get
   flutter pub run flutter_launcher_icons
   ```

## Option 2: Using Online Tools

### AppIcon.co
1. Visit https://www.appicon.co/
2. Upload your 1024x1024 icon
3. Select platforms (iOS, Android)
4. Download the generated icons
5. Extract and place in:
   - iOS: `ios/Runner/Assets.xcassets/AppIcon.appiconset/`
   - Android: `android/app/src/main/res/mipmap-*/`

### IconKitchen
1. Visit https://icon.kitchen/
2. Upload your icon
3. Customize settings
4. Download and extract to appropriate folders

## Option 3: Manual Design Tools

### Figma (Free)
1. Create a 1024x1024 frame
2. Design your icon following the spec
3. Export as PNG
4. Use one of the methods above to generate sizes

### Canva (Free)
1. Create custom size: 1024x1024
2. Design your icon
3. Download as PNG
4. Use icon generator tools

## Design Inspiration for Nyx

### Key Elements to Include:
- **Lock/Vault**: Security symbol
- **Calculator**: Subtle grid or numbers
- **Dark Theme**: Purple/indigo colors
- **Moon/Night**: Reference to Nyx (Greek goddess of night)

### Color Palette:
- Primary: Dark purple/indigo (#1A1B2E, #2D1B69)
- Accent: Bright purple (#7B2CBF, #9D4EDD)
- Background: Deep black or dark blue

### Style:
- Modern, minimalist
- High contrast
- Recognizable at small sizes
- Professional and secure appearance

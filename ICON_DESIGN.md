# Nyx App Icon Design Specification

## Design Concept
The Nyx icon should represent **security, privacy, and hidden protection** - fitting the app's identity as a secure vault disguised as a calculator.

## Visual Elements

### Primary Symbol
- **Lock/Vault Icon**: A stylized lock or vault door
- **Calculator Integration**: Subtle calculator elements (numbers or grid pattern) integrated into the design
- **Moon/Night Theme**: Reference to "Nyx" (Greek goddess of night) - dark, mysterious aesthetic

### Color Scheme
Based on the app's theme (`AppTheme`):
- **Primary Background**: Deep charcoal/near-black (#0E0E11)
- **Surface**: Dark slate (#17171C)
- **Accent Color**: Emerald/Teal (#2EE6A6) - the app's primary accent
- **Secondary**: Dark slate variants for depth
- **Highlights**: Subtle glow or gradient for premium feel

### Design Options

#### Option 1: Lock with Calculator Grid (Recommended)
- Central lock icon in emerald/teal (#2EE6A6)
- Calculator number grid pattern as background texture in dark slate
- Deep charcoal background (#0E0E11)
- Minimalist, modern, instantly recognizable

#### Option 2: Vault Door with Keypad
- Stylized vault door with emerald accent
- Calculator keypad visible through door
- Dark theme with teal highlights
- Professional, secure appearance

#### Option 3: Shield with Moon
- Shield representing security in emerald
- Moon crescent (Nyx reference) in dark slate
- Calculator elements integrated subtly
- Deep charcoal gradient background

#### Option 4: Lock + Calculator Hybrid
- Lock icon with calculator button grid inside
- Emerald/teal lock on dark background
- Numbers visible on lock surface
- Modern, unique design

## Technical Requirements

### Dimensions
- **Source Image**: 1024x1024 pixels (square)
- **Format**: PNG with transparency (or solid background)
- **Background**: Can be transparent or solid dark color (#0E0E11)
- **Safe Zone**: Keep important elements within 80% of the icon (safe area for rounded corners)

### Design Guidelines
1. **Simple & Recognizable**: Should be clear even at small sizes (20x20px)
2. **High Contrast**: Ensure visibility on various backgrounds
3. **No Text**: Avoid using "Nyx" text in the icon itself
4. **Rounded Corners**: Design should work with iOS rounded corners
5. **Scalable**: Should look good from 20x20 to 1024x1024
6. **Color Consistency**: Use the app's color scheme (#0E0E11, #17171C, #2EE6A6)

## Recommended Tools
- **Figma**: Free design tool, great for icon design
- **Adobe Illustrator**: Professional vector design
- **Canva**: Simple online design tool
- **Icon Generator**: Use online tools like AppIcon.co or IconKitchen

## Implementation
Once you have a 1024x1024 PNG icon:
1. Save it as `assets/icon/icon.png`
2. Run `flutter pub get`
3. Run `flutter pub run flutter_launcher_icons`
4. Icons will be automatically generated for iOS and Android

## Quick Start (Using Online Generator)
1. Go to https://www.appicon.co/ or https://icon.kitchen/
2. Upload a 1024x1024 icon
3. Download generated icons
4. Place in appropriate folders:
   - iOS: `ios/Runner/Assets.xcassets/AppIcon.appiconset/`
   - Android: `android/app/src/main/res/mipmap-*/`

## Design Inspiration

### Key Visual Elements:
- **Security**: Lock, shield, vault door
- **Calculator**: Number grid, keypad pattern
- **Night/Privacy**: Dark theme, subtle moon reference
- **Modern**: Clean lines, minimalist approach

### Color Reference:
- Primary: `#0E0E11` (Deep charcoal)
- Surface: `#17171C` (Dark slate)
- Accent: `#2EE6A6` (Emerald/Teal)
- Text: `#F5F5F7` (Off-white)

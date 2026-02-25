# Quick Start: Generate Nyx App Icon

## Step 1: Create Your Icon Design

You have three options:

### A. Use an Online Icon Generator
1. Visit **https://www.appicon.co/** or **https://icon.kitchen/**
2. Design a simple icon using their tools
3. Download as 1024x1024 PNG

### B. Use a Design Tool
1. Use **Figma** (free) or **Canva** (free)
2. Create a 1024x1024 design following the spec in `ICON_DESIGN.md`
3. Export as PNG

### C. Hire a Designer
- Use Fiverr, 99designs, or similar
- Share `ICON_DESIGN.md` as the design brief

## Step 2: Place the Icon

1. Save your 1024x1024 PNG icon as:
   ```
   assets/icon/icon.png
   ```

## Step 3: Generate All Icon Sizes

Run these commands:

```bash
flutter pub get
flutter pub run flutter_launcher_icons
```

That's it! All icon sizes will be automatically generated for iOS and Android.

## Design Quick Reference

**Theme**: Dark, secure, privacy-focused
**Colors**: Dark purple (#1A1B2E) background, bright purple (#7B2CBF) accent
**Elements**: Lock/vault + subtle calculator reference
**Style**: Modern, minimalist, recognizable at small sizes

See `ICON_DESIGN.md` for full design specifications.

# iOS Build Fix for MLImage Framework

## Issue
Building for iOS simulator fails with:
```
Error: Building for 'iOS-simulator', but linking in object file
(/Users/.../MLImage.framework/MLImage[arm64]) built for 'iOS'
```

## Cause
The `mobile_scanner` package uses Google ML Kit, which includes `MLImage.framework`. This framework may have architecture mismatches when building for iOS simulator, especially on Apple Silicon Macs.

## Solution Applied

### 1. Updated Podfile
Added build settings in `post_install` hook to:
- Set `BUILD_LIBRARY_FOR_DISTRIBUTION = YES` for all pods
- Set `ONLY_ACTIVE_ARCH = NO` to build for all architectures
- Clear `EXCLUDED_ARCHS` for simulator builds

### 2. Clean Build
```bash
cd ios
rm -rf Pods Podfile.lock
pod install
cd ..
flutter clean
flutter pub get
```

## Alternative Solutions (if issue persists)

### Option 1: Exclude arm64 for Intel Macs
If building on Intel Mac, you may need to exclude arm64:
```ruby
config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'arm64'
```

### Option 2: Update mobile_scanner
Check for newer version of mobile_scanner that fixes this:
```yaml
mobile_scanner: ^5.2.3  # Check for newer version
```

### Option 3: Use physical device
Build for physical iOS device instead of simulator:
```bash
flutter run -d <device-id>
```

## Testing
After applying the fix:
1. Clean build: `flutter clean`
2. Get dependencies: `flutter pub get`
3. Install pods: `cd ios && pod install`
4. Build for simulator: `flutter build ios --simulator`

## Status
✅ Podfile updated with architecture fixes
✅ Pods reinstalled successfully
⚠️ If build still fails, try building on physical device or check mobile_scanner version

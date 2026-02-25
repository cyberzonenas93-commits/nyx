# Share Extension Setup Guide

This document explains how to set up share extension support for iOS and Android to allow users to save photos/videos directly from browsers and other apps.

## Current Implementation

The app includes `ShareHandlerService` which can handle shared files when the app is opened via share intent. However, full share extension support requires platform-specific configuration.

## iOS Setup

### 1. Add Share Extension Target

1. Open Xcode project
2. File → New → Target
3. Select "Share Extension"
4. Name it "NyxShareExtension"
5. Configure the extension

### 2. Update Info.plist

Add to `ios/Runner/Info.plist`:

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key>
    <string>Images</string>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>public.image</string>
      <string>public.jpeg</string>
      <string>public.png</string>
      <string>public.heic</string>
    </array>
  </dict>
  <dict>
    <key>CFBundleTypeName</key>
    <string>Videos</string>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>public.movie</string>
      <string>public.mpeg-4</string>
      <string>public.avi</string>
    </array>
  </dict>
</array>
```

### 3. Share Extension Code

The share extension needs to:
1. Receive shared files
2. Open the main app with file paths
3. Main app imports files via `ShareHandlerService`

## Android Setup

### 1. Update AndroidManifest.xml

Add intent filters to `android/app/src/main/AndroidManifest.xml`:

```xml
<activity
    android:name=".MainActivity"
    android:launchMode="singleTop"
    ...>
    
    <!-- Share Intent Filter -->
    <intent-filter>
        <action android:name="android.intent.action.SEND" />
        <category android:name="android.intent.category.DEFAULT" />
        <data android:mimeType="image/*" />
    </intent-filter>
    
    <intent-filter>
        <action android:name="android.intent.action.SEND" />
        <category android:name="android.intent.category.DEFAULT" />
        <data android:mimeType="video/*" />
    </intent-filter>
    
    <intent-filter>
        <action android:name="android.intent.action.SEND_MULTIPLE" />
        <category android:name="android.intent.category.DEFAULT" />
        <data android:mimeType="image/*" />
    </intent-filter>
    
    <intent-filter>
        <action android:name="android.intent.action.SEND_MULTIPLE" />
        <category android:name="android.intent.category.DEFAULT" />
        <data android:mimeType="video/*" />
    </intent-filter>
</activity>
```

### 2. Handle Intent in MainActivity

The MainActivity needs to:
1. Check if app was opened via share intent
2. Extract file URIs from intent
3. Pass to Flutter via method channel
4. Flutter calls `ShareHandlerService.handleSharedFiles()`

## Implementation Status

✅ **Service Created**: `ShareHandlerService` is ready
✅ **Import Logic**: Can handle shared files
⏳ **Platform Integration**: Requires native code setup
⏳ **iOS Share Extension**: Needs Xcode configuration
⏳ **Android Intent Handling**: Needs MainActivity updates

## Next Steps

1. Configure iOS Share Extension in Xcode
2. Update Android MainActivity to handle share intents
3. Add method channel to pass file paths from native to Flutter
4. Test share functionality from browser and other apps

## Testing

Once configured, users should be able to:
1. Open a photo/video in browser
2. Tap "Share" button
3. Select "Nyx" from share sheet
4. File is automatically imported to vault

# Media Privacy Vault

A secure, zero-knowledge media privacy vault application built with Flutter.

## Security Features

- Zero-knowledge architecture
- On-device encryption (AES-256-GCM)
- Argon2id password hashing
- Decoy vault system
- Intrusion detection (screenshot/recording blocking)
- Biometric authentication support

## Building

```bash
flutter pub get
flutter run
```

## Platform Configuration

### iOS

Update `ios/Runner/Info.plist` for photo library access and biometric permissions.

### Android

Update `android/app/src/main/AndroidManifest.xml` for storage and biometric permissions.

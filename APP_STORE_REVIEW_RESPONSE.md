# App Store Review Response

## Submission ID: 9ae371df-dab4-4635-a15d-4df86b8187a5

Thank you for reviewing our app. We have addressed both issues raised in your review:

---

## Issue 1: Guideline 2.5.4 - UIBackgroundModes Audio

**Response:**

Our app includes a media player feature that allows users to play audio files stored in their secure vault. The background audio mode is required for this functionality to work properly when the app is minimized or when users navigate away from the player screen.

**How to locate the feature:**

1. Open the app and unlock the vault
2. Navigate to the vault home page
3. Select an audio file (any file with audio format like .mp3, .m4a, etc.)
4. The audio player will appear at the bottom of the screen
5. Tap the play button to start playback
6. Minimize the app or navigate away - the audio will continue playing in the background
7. You can control playback from the lock screen controls or Control Center

**Technical Implementation:**
- The app uses the `audioplayers` package with `PlayerMode.mediaPlayer` for background audio playback
- Audio session is configured in `AppDelegate.swift` with `.playback` category
- This is a standard implementation for media player apps

If you prefer, we can remove the background audio mode, but this would significantly degrade the user experience as audio playback would stop whenever the app is minimized.

---

## Issue 2: Guideline 2.5.1 - Photos API Usage

**Response:**

We have removed the PhotoManager deletion functionality that was flagged in your review. The app no longer uses `PhotoManager.editor.deleteWithIds()` to delete photos from the user's photo library.

**Changes made:**
- Removed all calls to `PhotoManager.editor.deleteWithIds()` from the codebase
- Files saved to the photo library will now remain there as expected
- The app still uses PhotoManager for legitimate purposes:
  - Requesting photo library access permissions
  - Saving images and videos to the photo library (with user permission)
  - Reading photos from the library to import into the vault

**Clarification on Decoy Vault:**
The "decoy vault" feature is simply a separate encrypted storage area within the app. It does not use the Photos API to hide or manipulate photos in the user's photo library. It is a software-only feature that creates a separate encrypted storage space, similar to having multiple user accounts. No Photos API calls are made for the decoy vault functionality.

**Current PhotoManager Usage:**
- ✅ Requesting permissions (standard use)
- ✅ Saving files to photo library (standard use, with user permission)
- ✅ Reading files from photo library (standard use, with user permission)
- ❌ No longer deleting files (removed as requested)

---

## Summary

We have:
1. Removed the PhotoManager deletion functionality that violated API guidelines
2. Clarified that background audio mode is used for legitimate media playback functionality
3. Provided clear instructions on how to test the background audio feature

The app now complies with Apple's API usage guidelines while maintaining core functionality. We appreciate your review and look forward to approval.

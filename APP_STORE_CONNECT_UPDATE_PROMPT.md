# AI Prompt: Update Nyx on App Store Connect (Autonomous)

Use this prompt with an AI/agent that can browse the web. The user will log in to App Store Connect first; you have full access to handle any additional authentication (2FA, session prompts, etc.) and to navigate and edit the site autonomously.

---

## Your task

1. **Navigate** to [App Store Connect](https://appstoreconnect.apple.com/) and ensure you are logged in (user will have logged in beforehand; complete any 2FA or session prompts as they appear).
2. **Open the Nyx app** in App Store Connect (app name: Nyx; it may be under "My Apps" or the app list).
3. **Update the following fields** with the exact text provided below. Save after each section if the UI requires it.
4. **For the version that is in review or the next version you are editing:** update **App Information** and **Version Information** (Description, Promotional Text, Keywords, What’s New, and **App Review Information → Notes**) so they all match the post-review changes.

**Summary of changes to reflect:**  
The app no longer has any calculator or disguise. There is no decoy functionality; the app does not hide the user’s photos (Photos API is used only for import/export with permission; the app does not delete or modify the device photo library). Background audio is only for playing vault audio when the app is minimised or from the lock screen (media player use). All copy below reflects these changes.

---

## Fields to update

### 1. App Store listing – Description (full)

**Where:** App Store Connect → Nyx → [Your version, e.g. 1.0.1] → App Store tab → **Description** (under “Version Information” or “App Information”).

**Paste this exactly:**

```
Nyx – Secure File Vault & Privacy Manager

Nyx is a privacy vault that protects and organises your personal files with strong on‑device encryption. Enter your PIN to access an encrypted vault where you can store photos, videos, documents and other files securely on your device.

Privacy & Security First
All content you import is stored locally using industry‑standard encryption. Nyx never uploads your data or shares it with anyone else; your privacy remains entirely under your control.

Comprehensive File Support

Photos and Videos: import from your gallery or camera and organise automatically

Audio Files: store and play recordings or music

Documents: keep PDFs, Word/Excel files and other formats safe

Any File Type: secure whatever matters to you

Organise with Ease

Smart and custom albums for flexible organisation

Swipe navigation and powerful search/filter to find items quickly

Built‑in Private Browser

Browse privately and download media directly into your vault

Bookmark favourite sites, manage tabs and resume sessions

Redirect protection for safer browsing

Media Tools

Built‑in video and audio player

Convert videos to audio format

Background audio playback: play vault audio when the app is minimised or from the lock screen and Control Center

Animated thumbnails for quick previews

File Transfer & Backup

Transfer files wirelessly over your local Wi‑Fi network via a simple web interface

Use a QR code for quick connection; no cloud required

Secure Access

Protect your vault with a PIN; optional Face ID or Touch ID

Automatic locking when the app goes into the background

Choose your preferred unlock method

Additional Features

Rename files, share them securely or export them back to your device

Files you export to your photo library remain there; the app does not delete or modify your device gallery

Full‑screen viewing, dark theme and interactive tutorial for first‑time users

Bulk import/export for efficiency

Perfect For

Securing sensitive documents and personal files

Organising important photos and videos

Creating local backups without using the cloud

Keeping private content separate from your main gallery

Transferring files between devices securely

Downloading and managing media from the web

Your files stay on your device, with no tracking or data collection. Download Nyx today and take control of your digital privacy.
```

---

### 2. Promotional Text (170 characters max)

**Where:** Same version → **Promotional Text** (often at top of the same page as Description).

**Paste this exactly:**

```
Secure privacy vault for photos, videos, documents, and files. Advanced encryption on your device. Your data stays on your device—we never see it.
```

---

### 3. Keywords (100 characters max, comma-separated, no spaces after commas)

**Where:** Same version → **Keywords**.

**Paste this exactly:**

```
privacy,vault,secure,encryption,photos,videos,documents,organize,backup,private,lock,files
```

---

### 4. What’s New (optional; use if you are editing “What’s New in This Version”)

**Where:** Same version → **What’s New in This Version** (or equivalent).

**Paste this exactly:**

```
Welcome to Nyx!

Nyx is your secure privacy vault, designed to protect and organize your personal files with advanced encryption.

Key Features:
• Secure file storage with industry-standard encryption
• Support for photos, videos, audio, and documents
• Built-in private browser for downloading media
• WiFi file transfer between devices
• Media tools including video/audio player (with background playback) and converter
• Smart albums and organization features
• PIN and biometric authentication

All files are stored locally on your device. No cloud sync, no data collection. Your privacy is our priority.
```

---

### 5. App Review Information → Notes (critical for review)

**Where:** Same version → **App Review Information** (often at bottom of the version page or under a “App Review Information” link) → **Notes** (the large text field for reviewers).

**Paste this exactly:**

```
App Review Notes (Demo Video Walkthrough)

This screen recording shows Nyx running on an iOS device from first launch through storing media in the secure vault. Reviewers create their own unlock method during onboarding; no test credentials are needed.

First launch and onboarding
– When the app is first opened, it shows the Nyx welcome/onboarding flow. There is no calculator or disguise interface.
– During onboarding you set up your vault access and create your own unlock method (e.g. a PIN). After completing this step, the app shows the vault home or login screen.
– The app does not use any “decoy” or “disguise” functionality. It does not hide or manipulate the user’s photos in the device photo library.

Permissions shown in the video
– Face ID / Touch ID: used only to authenticate and access the vault if biometric unlock is enabled.
– Photos: used only when the user chooses to import photos/videos into the vault or to export vault items back to the device. The app does not delete, hide, or modify photos in the user’s photo library. Files exported to the photo library remain there.
– Local Network (if prompted): used only for Wi‑Fi Transfer so a computer on the same network can connect.

Unlocking the vault
– From the app’s login screen, enter the PIN (or use Face ID/Touch ID if enabled). On successful authentication, the app opens the Vault Home screen.

Vault Home (core functionality)
– The vault displays stored items in a grid or list.
– Items show thumbnails for quick browsing; videos display a duration overlay.
– Tap any item to view it full‑screen; swipe left/right to navigate between items.

Adding media to the vault (importing)
– Tap the “Add/Import” action in the vault.
– Select photos, videos or files from the system picker.
– Selected media is copied into Nyx’s encrypted storage and then appears in the vault. The app does not remove or hide the originals from the user’s photo library.
– If a photo/video is in iCloud, Nyx may show “Downloading from iCloud…” while it is prepared for import.

Viewing media securely
– Tap an imported photo or video to open it in the built‑in viewer.
– A static thumbnail loads first; then the full image or video loads.
– Videos play from the file path. Swiping between items is supported.

Background audio
– When playing an audio file (or video with audio) from the vault, playback can continue when the app is minimised or from the lock screen and Control Center. This is standard media player behaviour; there is no background audio recording.

Wi‑Fi Transfer (optional)
– From the vault, open Wi‑Fi Transfer and start the server. Nyx displays a local URL and a QR code.
– From a computer on the same Wi‑Fi network, open the URL to upload or download vault files via a simple web interface. All transfers are on the local network only; no cloud.

Summary for reviewers
Nyx is a privacy‑focused file vault. Users set up a secure PIN and can import photos, videos and files into the vault, browse them, and view or play them in the app. The vault is protected by the user’s unlock method and optional biometrics. All data stays on device. The Photos API is used only when the user chooses to import or export media; the app does not use any decoy or hide-the-user’s-photos functionality and does not delete or modify the device photo library.

Demo video (unlisted): https://www.youtube.com/watch?v=fz1zFWgMBlo
```

---

## Instructions for the AI/agent

- You have **full access** to handle credentials: accept 2FA, re-authentication, or session timeouts as they appear. Do not stop for login unless the session is clearly logged out.
- Navigate to App Store Connect, open **Nyx**, then open the **correct app version** (the one in review or the one you are preparing for submission).
- For each field above: locate the corresponding input on the page, clear any existing value if needed, and paste the exact text from this document. Save or submit the form when the UI requires it (e.g. “Save” or “Done”).
- **App Review Notes** are especially important: ensure the Notes field for the version is updated with the new text so reviewers see that the app no longer has decoy/disguise and uses the Photos API only for import/export.
- After all edits, confirm on the page that Description, Promotional Text, Keywords, What’s New (if used), and App Review Notes show the new content. If the site shows a “Submit for Review” or “Save” at version level, save so changes are stored.
- If you cannot find a field (e.g. “Promotional Text” in a different locale), update all fields you can find and report which ones were updated and which were not found.

---

## Checklist (for you or the AI to confirm)

- [ ] Description updated (no calculator, no disguise; includes line about export not deleting/modifying photo library).
- [ ] Promotional Text updated (no calculator/disguise).
- [ ] Keywords updated (no “calculator”; includes “files”).
- [ ] What’s New updated (no calculator/disguise) if that field is used.
- [ ] App Review Notes updated (no calculator/disguise; clear that there is no decoy, no hiding of user’s photos; Photos API only for import/export; background audio is playback only; demo video link included).

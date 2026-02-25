# WebView Authentication Challenge Fix

## Problem
iOS WebView crashes with: "Could not cast value of type 'NSNull' to 'AuthenticationChallengeResponse'"

This happens when a website requires HTTP authentication and the Flutter side doesn't provide a response handler.

## Solution
The fix patches the `webview_flutter_wkwebview` plugin to handle NSNull gracefully instead of crashing.

## How to Apply the Fix

1. After running `pod install`, run the patch script:
   ```bash
   cd ios
   bash patch_webview_auth.sh
   ```

2. Or manually patch the file:
   - Find: `Pods/webview_flutter_wkwebview/darwin/webview_flutter_wkwebview/Sources/webview_flutter_wkwebview/WebKitLibrary.g.swift`
   - Search for: `let result = listResponse[0] as! AuthenticationChallengeResponse`
   - Replace with: `guard let result = listResponse[0] as? AuthenticationChallengeResponse else { completion(.failure(PigeonError(code: "cast-error", message: "Failed to cast authentication challenge response", details: ""))); return }`

## Note
This patch needs to be reapplied after each `pod install` or `pod update`.

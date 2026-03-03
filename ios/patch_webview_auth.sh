#!/bin/bash
# Patch webview_flutter_wkwebview to handle NSNull in authentication challenges

# Try multiple possible locations
FILE_PATHS=(
  "Pods/webview_flutter_wkwebview/darwin/webview_flutter_wkwebview/Sources/webview_flutter_wkwebview/WebKitLibrary.g.swift"
  "$HOME/.pub-cache/hosted/pub.dev/webview_flutter_wkwebview-3.23.5/darwin/webview_flutter_wkwebview/Sources/webview_flutter_wkwebview/WebKitLibrary.g.swift"
)

FILE_PATH=""
for path in "${FILE_PATHS[@]}"; do
  if [ -f "$path" ]; then
    FILE_PATH="$path"
    break
  fi
done

if [ -n "$FILE_PATH" ]; then
  # Replace force cast with safe cast using Python for better string handling
  python3 << EOF
import re

file_path = "$FILE_PATH"
with open(file_path, 'r') as f:
    content = f.read()

# Check if already patched
if "guard let result = listResponse[0] as? AuthenticationChallengeResponse" in content:
    print("✅ File already patched")
else:
    # Replace the force cast with a safe cast
    old_pattern = "let result = listResponse[0] as! AuthenticationChallengeResponse"
    new_replacement = """guard let result = listResponse[0] as? AuthenticationChallengeResponse else {
          completion(.failure(PigeonError(code: "cast-error", message: "Failed to cast authentication challenge response", details: "")))
          return
        }"""
    
    if old_pattern in content:
        content = content.replace(old_pattern, new_replacement)
        with open(file_path, 'w') as f:
            f.write(content)
        print("✅ Patched WebKitLibrary.g.swift to handle NSNull in authentication challenge")
        print("   Location: $FILE_PATH")
    else:
        print("⚠️  Pattern not found - file may have changed")
        print("   Looking for: let result = listResponse[0] as! AuthenticationChallengeResponse")
EOF
else
  echo "⚠️  WebKitLibrary.g.swift not found"
  echo "   Checked locations:"
  for path in "${FILE_PATHS[@]}"; do
    echo "     - $path"
  done
fi

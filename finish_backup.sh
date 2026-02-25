#!/bin/bash
# Add android, ios, macos and push. Run in Terminal; may take 10–20 min on iCloud.
set -e
cd "$(dirname "$0")"
echo "==> Adding android, ios, macos (this can take a while on iCloud)..."
git add android ios macos
echo "==> Committing..."
git commit -m "Add android, ios, macos"
echo "==> Pushing..."
git push
echo "Done. Full backup at: https://github.com/cyberzonenas93-commits/privacy-app"

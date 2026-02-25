#!/bin/bash
# Run this AFTER completing GitHub device login in your browser.
set -e
cd "$(dirname "$0")"

echo "==> Checking GitHub login..."
gh auth status || { echo "Run: gh auth login -h github.com -p https -w"; exit 1; }

REPO_NAME="${1:-privacy-app}"

echo "==> Creating GitHub repo '$REPO_NAME' and pushing..."
gh repo create "$REPO_NAME" --private --source=. --remote=origin --push

echo ""
echo "Done. Your app is at: https://github.com/$(gh api user -q .login)/$REPO_NAME"
echo ""
echo "To add the remaining code (lib, android, ios, macos) later, run:"
echo "  git add -A && git commit -m 'Add app code' && git push"
echo ""

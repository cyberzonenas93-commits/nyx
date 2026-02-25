#!/bin/bash
# Back up Privacy app to GitHub
# Run this from the project folder in Terminal (may be slow on iCloud).

set -e
cd "$(dirname "$0")"

echo "==> Ensuring git is initialized..."
if [ ! -d .git ]; then
  git init
fi

echo "==> Staging all files..."
git add -A

echo "==> Creating initial commit (if needed)..."
if [ -z "$(git status --porcelain)" ] && [ -n "$(git rev-parse HEAD 2>/dev/null)" ]; then
  echo "Nothing to commit; already up to date."
else
  git commit -m "Back up: Privacy app" || true
fi

echo ""
echo "==> Next: create a repo on GitHub and push"
echo "1. Go to https://github.com/new"
echo "2. Create a new repository (e.g. name: privacy-app)"
echo "3. Do NOT initialize with README (you already have one)"
echo "4. Run these commands (replace YOUR_USERNAME and REPO_NAME):"
echo ""
echo "   git remote add origin https://github.com/YOUR_USERNAME/REPO_NAME.git"
echo "   git branch -M main"
echo "   git push -u origin main"
echo ""
echo "If the repo already exists and you only need to push:"
echo "   git remote add origin https://github.com/YOUR_USERNAME/REPO_NAME.git"
echo "   git push -u origin main"
echo ""

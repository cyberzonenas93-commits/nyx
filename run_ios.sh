#!/bin/bash
# Run Privacy app on iOS Simulator (use after iOS Simulator runtime is installed)
set -e
cd "$(dirname "$0")"

echo "Checking for iOS devices..."
if ! flutter devices | grep -q "iPhone\|iPad\|ios"; then
  echo "No iOS simulator found. Launching iOS Simulator..."
  flutter emulators --launch apple_ios_simulator
  sleep 10
fi

echo "Running app on iOS..."
flutter run -d ios

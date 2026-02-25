#!/bin/bash
# Open Xcode for iOS Simulator testing (recommended when "flutter run -d ios" fails)
cd "$(dirname "$0")"
open ios/Runner.xcworkspace
echo "Xcode opened. Select 'iPhone 17 Pro' (or any simulator) as the run destination and press Cmd+R to build and run."

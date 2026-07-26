#!/bin/sh
set -e

echo "Installing Flutter stable for Xcode Cloud..."
git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"
export PATH="$HOME/flutter/bin:$PATH"

flutter --version
flutter pub get

echo "Installing iOS pods..."
cd ios
pod install --repo-update

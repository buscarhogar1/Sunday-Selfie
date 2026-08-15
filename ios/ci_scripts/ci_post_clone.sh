#!/bin/sh
set -e

echo "Preparing Flutter project for Xcode Cloud..."

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$REPO_ROOT"

echo "Cleaning generated Flutter and CocoaPods files..."
rm -f .flutter-plugins-dependencies
rm -rf .dart_tool ios/.symlinks ios/Pods ios/Podfile.lock

if [ ! -d "$HOME/flutter" ]; then
  echo "Installing Flutter stable..."
  git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"
fi

export PATH="$HOME/flutter/bin:$PATH"

flutter --version
flutter precache --ios
flutter pub get

echo "Installing iOS pods..."
cd "$REPO_ROOT/ios"
pod install --repo-update

echo "CocoaPods installation completed. Xcode will use the real plugin modules."

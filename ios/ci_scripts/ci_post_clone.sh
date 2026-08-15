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
echo "Disabling Flutter Swift Package Manager integration for Xcode Cloud..."
flutter config --no-enable-swift-package-manager
rm -rf ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm

flutter precache --ios
flutter pub get

echo "Generating Flutter iOS build configuration with CocoaPods..."
flutter build ios --release --config-only --no-codesign

echo "Forcing iOS deployment target to 15.5..."
for xcconfig in \
  ios/Flutter/Debug.xcconfig \
  ios/Flutter/Release.xcconfig \
  ios/Flutter/Profile.xcconfig
do
  if [ -f "$xcconfig" ]; then
    grep -v '^IPHONEOS_DEPLOYMENT_TARGET=' "$xcconfig" > "$xcconfig.tmp" || true
    printf '\nIPHONEOS_DEPLOYMENT_TARGET=15.5\n' >> "$xcconfig.tmp"
    mv "$xcconfig.tmp" "$xcconfig"
  fi
done

echo "Installing iOS pods..."
cd "$REPO_ROOT/ios"
pod install --repo-update

echo "CocoaPods installation completed. Xcode will use the real plugin modules."

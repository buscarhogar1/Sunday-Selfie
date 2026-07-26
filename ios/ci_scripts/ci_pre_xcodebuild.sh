#!/bin/sh
set -e

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"

if [ ! -f "$REPO_ROOT/ios/Flutter/Generated.xcconfig" ] || [ ! -d "$REPO_ROOT/ios/Pods" ]; then
  echo "Flutter or Pods files are missing. Preparing project before xcodebuild..."
  "$REPO_ROOT/ios/ci_scripts/ci_post_clone.sh"
else
  echo "Flutter and Pods files are ready."
fi

echo "Patching Flutter xcconfig files with explicit Pods build settings..."
REPO_ROOT="$REPO_ROOT" ruby "$REPO_ROOT/ios/ci_scripts/patch_runner_pods_settings.rb"

echo "Prebuilding CocoaPods targets so Swift plugin modules are available..."
cd "$REPO_ROOT/ios"
xcodebuild \
  -project Pods/Pods.xcodeproj \
  -target Pods-Runner \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO \
  build

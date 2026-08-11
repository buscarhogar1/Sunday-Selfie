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

add_flutter_plugin_header() {
  module_name="$1"
  header_name="$2"
  class_name="$3"
  header_path="$REPO_ROOT/ios/Pods/Headers/Public/$module_name/$header_name"

  mkdir -p "$(dirname "$header_path")"
  cat > "$header_path" <<EOF
#import <Flutter/Flutter.h>

@interface $class_name : NSObject <FlutterPlugin>
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
@end
EOF
}

echo "Adding compatibility headers for Flutter plugins..."
add_flutter_plugin_header "camera_avfoundation" "CameraPlugin.h" "CameraPlugin"
add_flutter_plugin_header "cloud_firestore" "FLTFirebaseFirestorePlugin.h" "FLTFirebaseFirestorePlugin"
add_flutter_plugin_header "cloud_functions" "FirebaseFunctionsPlugin.h" "FirebaseFunctionsPlugin"
add_flutter_plugin_header "firebase_app_check" "FLTFirebaseAppCheckPlugin.h" "FLTFirebaseAppCheckPlugin"
add_flutter_plugin_header "firebase_auth" "FLTFirebaseAuthPlugin.h" "FLTFirebaseAuthPlugin"
add_flutter_plugin_header "firebase_core" "FLTFirebaseCorePlugin.h" "FLTFirebaseCorePlugin"
add_flutter_plugin_header "firebase_messaging" "FLTFirebaseMessagingPlugin.h" "FLTFirebaseMessagingPlugin"
add_flutter_plugin_header "firebase_storage" "FLTFirebaseStoragePlugin.h" "FLTFirebaseStoragePlugin"
add_flutter_plugin_header "google_mlkit_commons" "GoogleMlKitCommonsPlugin.h" "GoogleMlKitCommonsPlugin"
add_flutter_plugin_header "google_mlkit_face_detection" "GoogleMlKitFaceDetectionPlugin.h" "GoogleMlKitFaceDetectionPlugin"
add_flutter_plugin_header "google_mobile_ads" "FLTGoogleMobileAdsPlugin.h" "FLTGoogleMobileAdsPlugin"
add_flutter_plugin_header "google_sign_in_ios" "FLTGoogleSignInPlugin.h" "FLTGoogleSignInPlugin"
add_flutter_plugin_header "image_picker_ios" "FLTImagePickerPlugin.h" "FLTImagePickerPlugin"
add_flutter_plugin_header "share_plus" "FPPSharePlusPlugin.h" "FPPSharePlusPlugin"
add_flutter_plugin_header "webview_flutter_wkwebview" "WebViewFlutterPlugin.h" "WebViewFlutterPlugin"

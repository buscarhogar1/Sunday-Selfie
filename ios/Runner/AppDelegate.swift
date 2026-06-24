import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaSaverChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    mediaSaverChannel = FlutterMethodChannel(
      name: "sunday_selfie/media_saver",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    mediaSaverChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "saveImagesToGallery" else {
        result(FlutterMethodNotImplemented)
        return
      }

      self?.saveImagesToPhotos(arguments: call.arguments, result: result)
    }
  }

  private func saveImagesToPhotos(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let args = arguments as? [String: Any],
      let files = args["files"] as? [[String: Any]]
    else {
      result(FlutterError(
        code: "invalid-arguments",
        message: "Missing media saver arguments",
        details: nil
      ))
      return
    }

    requestPhotoAddAuthorization { [weak self] authorized in
      guard let self = self else { return }
      guard authorized else {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "photo-permission-denied",
            message: "Photo Library permission denied",
            details: nil
          ))
        }
        return
      }

      self.writeImagesToPhotos(files: files, result: result)
    }
  }

  private func requestPhotoAddAuthorization(completion: @escaping (Bool) -> Void) {
    if #available(iOS 14, *) {
      let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
      switch status {
      case .authorized, .limited:
        completion(true)
      case .notDetermined:
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
          completion(newStatus == .authorized || newStatus == .limited)
        }
      default:
        completion(false)
      }
    } else {
      let status = PHPhotoLibrary.authorizationStatus()
      switch status {
      case .authorized:
        completion(true)
      case .notDetermined:
        PHPhotoLibrary.requestAuthorization { newStatus in
          completion(newStatus == .authorized)
        }
      default:
        completion(false)
      }
    }
  }

  private func writeImagesToPhotos(files: [[String: Any]], result: @escaping FlutterResult) {
    let validFileUrls = files.compactMap { fileData -> URL? in
      guard
        let path = fileData["path"] as? String,
        !path.isEmpty,
        FileManager.default.fileExists(atPath: path)
      else {
        return nil
      }

      return URL(fileURLWithPath: path)
    }

    guard !validFileUrls.isEmpty else {
      DispatchQueue.main.async {
        result(FlutterError(
          code: "no-files-saved",
          message: "No images were saved",
          details: nil
        ))
      }
      return
    }

    PHPhotoLibrary.shared().performChanges({
      for fileUrl in validFileUrls {
        let creationRequest = PHAssetCreationRequest.forAsset()
        creationRequest.addResource(with: .photo, fileURL: fileUrl, options: nil)
      }
    }) { success, error in
      DispatchQueue.main.async {
        if success {
          result(validFileUrls.count)
        } else {
          result(FlutterError(
            code: "no-files-saved",
            message: error?.localizedDescription ?? "No images were saved",
            details: nil
          ))
        }
      }
    }
  }
}

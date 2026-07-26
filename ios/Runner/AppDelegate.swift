import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaSaverChannel: FlutterMethodChannel?
  private var volumeButtonsChannel: FlutterMethodChannel?
  private var volumeButtonCaptureEnabled = false
  private var captureEventInteraction: UIInteraction?
  private weak var captureEventView: UIView?
  private var outputVolumeObservation: NSKeyValueObservation?
  private var fallbackVolumeView: MPVolumeView?
  private weak var fallbackVolumeSlider: UISlider?
  private var fallbackOriginalVolume: Float?
  private var ignoringProgrammaticVolumeChange = false
  private var lastObservedOutputVolume = AVAudioSession.sharedInstance().outputVolume
  private let fallbackCaptureVolume: Float = 0.5

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

    volumeButtonsChannel = FlutterMethodChannel(
      name: "sunday_selfie/volume_buttons",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    volumeButtonsChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setCaptureEnabled" else {
        result(FlutterMethodNotImplemented)
        return
      }

      let args = call.arguments as? [String: Any]
      let enabled = args?["enabled"] as? Bool ?? false
      self?.setVolumeButtonCaptureEnabled(enabled)
      result(nil)
    }
  }

  private var flutterRootView: UIView? {
    let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in windowScenes {
      if let view = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController?.view {
        return view
      }
    }

    return window?.rootViewController?.view
  }

  private func setVolumeButtonCaptureEnabled(_ enabled: Bool) {
    guard volumeButtonCaptureEnabled != enabled else { return }

    volumeButtonCaptureEnabled = enabled
    if enabled {
      startVolumeButtonCapture()
    } else {
      stopVolumeButtonCapture()
    }
  }

  private func startVolumeButtonCapture() {
    if startCaptureEventInteraction() {
      return
    }

    startOutputVolumeFallback()
  }

  private func stopVolumeButtonCapture() {
    stopCaptureEventInteraction()
    stopOutputVolumeFallback()
  }

  private func startCaptureEventInteraction() -> Bool {
    if #available(iOS 17.2, *) {
      if captureEventInteraction != nil {
        return true
      }

      guard let view = flutterRootView else {
        return false
      }

      let interaction = AVCaptureEventInteraction { [weak self] event in
        guard event.phase == .began else { return }
        self?.sendVolumeButtonPressed()
      }
      interaction.isEnabled = true

      view.addInteraction(interaction)
      captureEventInteraction = interaction
      captureEventView = view
      return true
    }

    return false
  }

  private func stopCaptureEventInteraction() {
    guard let interaction = captureEventInteraction else { return }

    captureEventView?.removeInteraction(interaction)
    captureEventInteraction = nil
    captureEventView = nil
  }

  private func startOutputVolumeFallback() {
    guard outputVolumeObservation == nil else { return }

    let session = AVAudioSession.sharedInstance()
    fallbackOriginalVolume = session.outputVolume
    do {
      try session.setActive(true)
    } catch {
      // The observer can still work on some routes even if activation fails.
    }

    addFallbackVolumeView()
    lastObservedOutputVolume = session.outputVolume
    outputVolumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
      DispatchQueue.main.async {
        self?.handleOutputVolumeChange(session.outputVolume)
      }
    }
    setFallbackSystemVolume(fallbackCaptureVolume)
  }

  private func stopOutputVolumeFallback() {
    outputVolumeObservation?.invalidate()
    outputVolumeObservation = nil

    if let originalVolume = fallbackOriginalVolume {
      setFallbackSystemVolume(originalVolume)
    }
    fallbackOriginalVolume = nil
    fallbackVolumeView?.removeFromSuperview()
    fallbackVolumeView = nil
    fallbackVolumeSlider = nil
    ignoringProgrammaticVolumeChange = false

    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      // No user-visible action is needed if the temporary session cannot be deactivated.
    }
  }

  private func addFallbackVolumeView() {
    guard fallbackVolumeView == nil, let view = flutterRootView else { return }

    let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    volumeView.alpha = 0.01
    volumeView.showsRouteButton = false
    volumeView.showsVolumeSlider = true
    view.addSubview(volumeView)
    volumeView.layoutIfNeeded()

    fallbackVolumeView = volumeView
    fallbackVolumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
  }

  private func handleOutputVolumeChange(_ volume: Float) {
    guard volumeButtonCaptureEnabled else { return }

    if ignoringProgrammaticVolumeChange {
      lastObservedOutputVolume = volume
      return
    }

    let difference = abs(volume - lastObservedOutputVolume)
    lastObservedOutputVolume = volume
    guard difference > 0.001 else { return }

    sendVolumeButtonPressed()
    setFallbackSystemVolume(fallbackCaptureVolume)
  }

  private func setFallbackSystemVolume(_ volume: Float) {
    guard let slider = fallbackVolumeSlider else { return }

    ignoringProgrammaticVolumeChange = true
    slider.setValue(min(1, max(0, volume)), animated: false)
    slider.sendActions(for: .valueChanged)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self = self else { return }
      self.lastObservedOutputVolume = AVAudioSession.sharedInstance().outputVolume
      self.ignoringProgrammaticVolumeChange = false
    }
  }

  private func sendVolumeButtonPressed() {
    guard volumeButtonCaptureEnabled else { return }
    volumeButtonsChannel?.invokeMethod("volumeButtonPressed", arguments: nil)
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

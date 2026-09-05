import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import Photos
import PhotosUI
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaSaverChannel: FlutterMethodChannel?
  private var volumeButtonsChannel: FlutterMethodChannel?
  private var profilePhotoPickerChannel: FlutterMethodChannel?
  private var deepLinksChannel: FlutterMethodChannel?
  private var deepLinksEventChannel: FlutterEventChannel?
  private let deepLinksStreamHandler = SundayDeepLinksStreamHandler()
  private var initialDeepLink: String?
  private var latestDeepLink: String?
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
  private var pendingProfilePhotoPickerResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let url = Self.deepLinkURL(from: launchOptions) {
      recordDeepLink(url)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()

    deepLinksChannel = FlutterMethodChannel(
      name: "sunday_selfie/deep_links",
      binaryMessenger: messenger
    )
    deepLinksChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "getInitialLink" else {
        result(FlutterMethodNotImplemented)
        return
      }

      result(self?.initialDeepLink ?? self?.latestDeepLink)
    }

    deepLinksEventChannel = FlutterEventChannel(
      name: "sunday_selfie/deep_links/events",
      binaryMessenger: messenger
    )
    deepLinksEventChannel?.setStreamHandler(deepLinksStreamHandler)

    mediaSaverChannel = FlutterMethodChannel(
      name: "sunday_selfie/media_saver",
      binaryMessenger: messenger
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
      binaryMessenger: messenger
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

    profilePhotoPickerChannel = FlutterMethodChannel(
      name: "sunday_selfie/profile_photo_picker",
      binaryMessenger: messenger
    )
    profilePhotoPickerChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "pickProfilePhoto" else {
        result(FlutterMethodNotImplemented)
        return
      }

      self?.presentProfilePhotoPicker(result: result)
    }
  }

  override func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    let handledDeepLink = recordDeepLink(url)
    return super.application(application, open: url, options: options) || handledDeepLink
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    let handledDeepLink: Bool
    if let url = userActivity.webpageURL {
      handledDeepLink = recordDeepLink(url)
    } else {
      handledDeepLink = false
    }

    return super.application(
      application,
      continue: userActivity,
      restorationHandler: restorationHandler
    ) || handledDeepLink
  }

  @discardableResult
  func recordDeepLink(_ url: URL) -> Bool {
    guard Self.isSundaySelfieDeepLink(url) else { return false }

    let value = url.absoluteString
    if initialDeepLink == nil {
      initialDeepLink = value
    }
    latestDeepLink = value
    deepLinksStreamHandler.send(value)
    return true
  }

  private static func deepLinkURL(
    from launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> URL? {
    guard let launchOptions = launchOptions else { return nil }

    if let url = launchOptions[.url] as? URL {
      return url
    }

    if let activities = launchOptions[.userActivityDictionary] as? [AnyHashable: Any] {
      for value in activities.values {
        if let activity = value as? NSUserActivity, let url = activity.webpageURL {
          return url
        }
      }
    }

    return nil
  }

  private static func isSundaySelfieDeepLink(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https" else { return false }

    let host = url.host?.lowercased()
    guard host == "sundayselfie.app" || host == "www.sundayselfie.app" else {
      return false
    }

    let firstPathComponent = url.pathComponents.dropFirst().first?.lowercased()
    return ["j", "join", "invite"].contains(firstPathComponent ?? "")
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

  private var flutterRootViewController: UIViewController? {
    let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in windowScenes {
      if let viewController = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
        return viewController
      }
    }

    return window?.rootViewController
  }

  private func presentProfilePhotoPicker(result: @escaping FlutterResult) {
    guard pendingProfilePhotoPickerResult == nil else {
      result(
        FlutterError(
          code: "picker_in_progress",
          message: "Ya se está eligiendo una foto de perfil.",
          details: nil
        )
      )
      return
    }

    guard #available(iOS 14, *), let presenter = flutterRootViewController else {
      result(
        FlutterError(
          code: "picker_unavailable",
          message: "No se pudo abrir el selector de fotos.",
          details: nil
        )
      )
      return
    }

    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 1
    // Ask iOS for a broadly compatible representation. The Flutter plugin's
    // data-representation path can fail for some HEIC assets from Photos.
    configuration.preferredAssetRepresentationMode = .compatible

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    pendingProfilePhotoPickerResult = result
    presenter.present(picker, animated: true)
  }

  private func completeProfilePhotoPicker(with value: Any?) {
    let result = pendingProfilePhotoPickerResult
    pendingProfilePhotoPickerResult = nil
    result?(value)
  }

  private func saveProfilePhotoPickerImage(_ image: UIImage) -> String? {
    guard image.size.width > 0, image.size.height > 0 else { return nil }

    let maxDimension: CGFloat = 1600
    let originalMaxDimension = max(image.size.width, image.size.height)
    let scale = min(1, maxDimension / originalMaxDimension)
    let outputSize = CGSize(
      width: max(1, floor(image.size.width * scale)),
      height: max(1, floor(image.size.height * scale))
    )

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    let normalizedImage = UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
      UIColor.white.setFill()
      UIRectFill(CGRect(origin: .zero, size: outputSize))
      image.draw(in: CGRect(origin: .zero, size: outputSize))
    }

    guard let jpegData = normalizedImage.jpegData(compressionQuality: 0.88) else {
      return nil
    }

    let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sunday_profile_\(UUID().uuidString).jpg")
    do {
      try jpegData.write(to: destinationURL, options: .atomic)
      return destinationURL.path
    } catch {
      return nil
    }
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

@available(iOS 14, *)
extension AppDelegate: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true) { [weak self] in
      guard let self else { return }
      guard let selection = results.first else {
        self.completeProfilePhotoPicker(with: nil)
        return
      }

      let itemProvider = selection.itemProvider
      guard itemProvider.canLoadObject(ofClass: UIImage.self) else {
        self.completeProfilePhotoPicker(
          with: FlutterError(
            code: "unsupported_image",
            message: "No se pudo leer la imagen seleccionada.",
            details: nil
          )
        )
        return
      }

      itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
        DispatchQueue.main.async {
          guard let self else { return }
          guard let image = object as? UIImage, let path = self.saveProfilePhotoPickerImage(image) else {
            self.completeProfilePhotoPicker(
              with: FlutterError(
                code: "invalid_image",
                message: error?.localizedDescription ?? "No se pudo preparar la imagen seleccionada.",
                details: nil
              )
            )
            return
          }

          self.completeProfilePhotoPicker(with: path)
        }
      }
    }
  }
}

private final class SundayDeepLinksStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func send(_ value: String) {
    eventSink?(value)
  }
}

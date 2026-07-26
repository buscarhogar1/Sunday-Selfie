import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      for context in connectionOptions.urlContexts {
        appDelegate.recordDeepLink(context.url)
      }

      for activity in connectionOptions.userActivities {
        if let url = activity.webpageURL {
          appDelegate.recordDeepLink(url)
        }
      }
    }

    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(
    _ scene: UIScene,
    continue userActivity: NSUserActivity
  ) {
    if
      let appDelegate = UIApplication.shared.delegate as? AppDelegate,
      let url = userActivity.webpageURL
    {
      appDelegate.recordDeepLink(url)
    }

    super.scene(scene, continue: userActivity)
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      for context in URLContexts {
        appDelegate.recordDeepLink(context.url)
      }
    }

    super.scene(scene, openURLContexts: URLContexts)
  }
}

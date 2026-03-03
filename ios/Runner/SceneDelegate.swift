import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private let securityViewTag = 9999

  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    guard let windowScene = scene as? UIWindowScene,
          let window = windowScene.windows.first else { return }
    let securityView = UIView(frame: window.bounds)
    securityView.backgroundColor = UIColor.black
    securityView.tag = securityViewTag
    securityView.isUserInteractionEnabled = false
    window.addSubview(securityView)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    guard let windowScene = scene as? UIWindowScene,
          let window = windowScene.windows.first else { return }
    window.subviews.forEach { view in
      if view.tag == securityViewTag {
        view.removeFromSuperview()
      }
    }
  }
}

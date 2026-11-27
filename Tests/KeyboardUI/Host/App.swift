import UIKit
@main class AppHarness: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
        configuration.delegateClass = HarnessScene.self
        return configuration
    }
}
final class HarnessScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let text = TargetView(frame: CGRect(x: 30, y: 160, width: 320, height: 120))
        text.accessibilityIdentifier = "target"
        controller.view.addSubview(text)
        window.rootViewController = controller
        self.window = window
        window.makeKeyAndVisible()
        text.becomeFirstResponder()
    }
}
private final class TargetView: UITextView {
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.last { $0.primaryLanguage == "zh-Hans" } ?? super.textInputMode
    }
}

import UIKit
@main class AppHarness: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let text = TargetView(frame: CGRect(x: 30, y: 160, width: 320, height: 120))
        text.accessibilityIdentifier = "target"
        controller.view.addSubview(text)
        window.rootViewController = controller
        self.window = window
        window.makeKeyAndVisible()
        text.becomeFirstResponder()
        return true
    }
}
private final class TargetView: UITextView {
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.last { $0.primaryLanguage == "zh-Hans" } ?? super.textInputMode
    }
}

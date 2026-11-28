import SwiftUI
import UIKit

enum YahTheme {
    static let accentUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 114 / 255, green: 183 / 255, blue: 255 / 255, alpha: 1)
            : UIColor(red: 18 / 255, green: 104 / 255, blue: 211 / 255, alpha: 1)
    }

    static let accent = Color(uiColor: accentUIColor)
    static let mutedAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 70 / 255, green: 103 / 255, blue: 148 / 255, alpha: 1)
            : UIColor(red: 174 / 255, green: 205 / 255, blue: 247 / 255, alpha: 1)
    })
    static let accentBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 30 / 255, green: 45 / 255, blue: 67 / 255, alpha: 1)
            : UIColor(red: 234 / 255, green: 243 / 255, blue: 255 / 255, alpha: 1)
    })
}

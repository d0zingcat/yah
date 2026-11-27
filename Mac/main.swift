import Cocoa
import Carbon
import InputMethodKit

if CommandLine.arguments.contains("--install") || CommandLine.arguments.contains("--uninstall") {
    let installing = CommandLine.arguments.contains("--install")
    let bundleID = Bundle.main.bundleIdentifier!
    if installing {
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        print("Register \(bundleID): \(status)")
    }

    let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
    let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
    if sources.isEmpty {
        print("No input sources found for \(bundleID)")
    }
    // Enable only; switching to Yah is left to the user (Ctrl-Space or the input menu).
    for source in sources {
        let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "<unknown>"
        let status = installing ? TISEnableInputSource(source) : TISDisableInputSource(source)
        print("\(installing ? "Enable" : "Disable") \(id): \(status)")
    }
    exit(0)
}

@objc(YahController)
class YahController: IMKInputController {
    private var composition = Composition()
    private let replacement = NSRange(location: NSNotFound, length: 0)

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput, let event, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let key = event.characters ?? ""
        if key.count == 1, let c = key.first, ("a"..."z").contains(c) {
            composition.append(c)
        } else {
            guard !composition.spelling.isEmpty else { return false }
            switch event.keyCode {
            case 116: composition.page(backward: true)  // Page Up
            case 121: composition.page(backward: false) // Page Down
            case 51: composition.backspace()
            case 53: composition.clear()
            default:
                let index = key == " " || event.keyCode == 36 ? 0 : (Int(key) ?? 0) - 1
                guard composition.candidates.indices.contains(index) else {
                    commitComposition(sender)
                    return false
                }
                if let word = composition.select(index) {
                    client.insertText(word, replacementRange: replacement)
                    return true
                }
            }
        }
        let menu = composition.candidates.enumerated().map { "\($0.offset + 1)\($0.element)" }.joined(separator: " ")
        let marked = composition.spelling.isEmpty ? "" : composition.spelling + "  " + menu
        client.setMarkedText(marked, selectionRange: NSRange(location: marked.utf16.count, length: 0), replacementRange: replacement)
        return true
    }

    override func commitComposition(_ sender: Any!) {
        if let client = sender as? IMKTextInput, !composition.spelling.isEmpty {
            let raw = composition.spelling
            let word = composition.select(0) ?? raw
            composition.clear()
            client.insertText(word, replacementRange: replacement)
        }
    }
}

let app = NSApplication.shared
let server = IMKServer(name: "Yah_Connection", bundleIdentifier: Bundle.main.bundleIdentifier!)
app.run()

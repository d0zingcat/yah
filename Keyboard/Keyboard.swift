import UIKit

@objc(KeyboardController)
final class KeyboardController: UIInputViewController {
    private var composition = Composition()
    private let suggestions = UIStackView()
    private var cursorAnchor: CGFloat = 0
    private let spelling = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5
        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        let preferredHeight = view.heightAnchor.constraint(equalToConstant: 268)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([preferredHeight,
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: guide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -2)])

        spelling.font = .preferredFont(forTextStyle: .caption1)
        spelling.textColor = .secondaryLabel
        spelling.lineBreakMode = .byTruncatingHead
        let header = UIStackView(arrangedSubviews: [spelling])
        header.axis = .vertical
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        header.addArrangedSubview(scroll)
        scroll.addSubview(suggestions)
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            suggestions.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            suggestions.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            suggestions.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            suggestions.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            suggestions.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            header.heightAnchor.constraint(equalToConstant: 52)])
        stack.addArrangedSubview(header)

        let rows = UIStackView()
        rows.axis = .vertical
        rows.distribution = .fillEqually
        stack.addArrangedSubview(rows)
        for keys in ["qwertyuiop", "asdfghjkl", "zxcvbnm"] {
            let row = UIStackView()
            row.distribution = .fillEqually
            for key in keys {
                row.addArrangedSubview(button(String(key), style: .letter) { $0.composition.append(key) })
            }
            if keys == "zxcvbnm" {
                let delete = button("⌫", style: .control) { keyboard in
                    if keyboard.composition.spelling.isEmpty { keyboard.textDocumentProxy.deleteBackward() }
                    else { keyboard.composition.backspace() }
                }
                delete.accessibilityLabel = "退格"
                row.addArrangedSubview(delete)
            }
            rows.addArrangedSubview(row)
        }

        let controls = UIStackView()
        if needsInputModeSwitchKey {
            let globe = styledButton("◎", style: .control)
            globe.setImage(UIImage(systemName: "globe"), for: .normal)
            globe.setTitle(nil, for: .normal)
            globe.accessibilityLabel = "切换键盘"
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            controls.addArrangedSubview(globe)
            globe.widthAnchor.constraint(equalTo: controls.widthAnchor, multiplier: 0.16).isActive = true
        }
        let space = button("空格", style: .space) { $0.insert(defaultText: " ") }
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(moveCursor(_:)))
        drag.delegate = self
        space.addGestureRecognizer(drag)
        controls.addArrangedSubview(space)
        let enter = button("回车", style: .accent) { $0.insert(defaultText: "\n") }
        controls.addArrangedSubview(enter)
        enter.widthAnchor.constraint(equalTo: controls.widthAnchor, multiplier: 0.24).isActive = true
        rows.addArrangedSubview(controls)
    }

    @objc private func moveCursor(_ gesture: UILongPressGestureRecognizer) {
        let x = gesture.location(in: view).x
        if gesture.state == .began { cursorAnchor = x }
        guard gesture.state == .changed else { return }
        let step: CGFloat = 12
        let offset = Int((x - cursorAnchor) / step)
        guard offset != 0 else { return }
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        cursorAnchor += CGFloat(offset) * step
    }

    private enum KeyStyle { case letter, control, space, accent, candidate }

    private func styledButton(_ title: String, style: KeyStyle) -> UIButton {
        let key = UIButton(type: .custom)
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = style == .accent ? .white : .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 1, bottom: 0, trailing: 1)
        let size: CGFloat = style == .letter ? 22 : (style == .candidate ? 18 : 16)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = UIFont.systemFont(ofSize: size)
            return result
        }
        // Only inset the painted cap. The button occupies the entire cell.
        config.background.cornerRadius = 6
        config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 3, leading: 2, bottom: 3, trailing: 2)
        let color: UIColor
        switch style {
        case .letter, .space: color = .systemBackground
        case .control: color = .systemGray3
        case .accent: color = .systemIndigo
        case .candidate:
            color = .clear
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 9)
        }
        config.background.backgroundColor = color
        key.configuration = config
        key.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = button.isHighlighted ? .systemGray2 : color
        }
        return key
    }

    private func insert(defaultText: String) {
        if composition.spelling.isEmpty { textDocumentProxy.insertText(defaultText) }
        else if let word = composition.select(0) { textDocumentProxy.insertText(word) }
    }

    private func button(_ title: String, style: KeyStyle = .candidate,
                        action: @escaping (KeyboardController) -> Void) -> UIButton {
        let key = styledButton(title, style: style)
        key.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            action(self)
            self.refresh()
        }, for: .touchUpInside)
        return key
    }

    private func refresh() {
        spelling.text = composition.spelling
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if composition.canPage(backward: true) {
            let previous = button("‹") { $0.composition.page(backward: true) }
            previous.accessibilityLabel = "上一页候选"
            suggestions.addArrangedSubview(previous)
        }
        for (i, word) in composition.candidates.enumerated() {
            suggestions.addArrangedSubview(button(word) { keyboard in
                if let selected = keyboard.composition.select(i) { keyboard.textDocumentProxy.insertText(selected) }
            })
        }
        if composition.canPage(backward: false) {
            let next = button("›") { $0.composition.page(backward: false) }
            next.accessibilityLabel = "下一页候选"
            suggestions.addArrangedSubview(next)
        }
    }
}

extension KeyboardController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        composition.spelling.isEmpty
    }
}

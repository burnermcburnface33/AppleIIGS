import SwiftUI
import UIKit

/// Hosts a UIResponder whose `inputAccessoryView` is the custom Apple-II key
/// row. Becoming first responder also summons the native iOS keyboard, so the
/// user sees [accessory bar] + [iOS QWERTY]. On hardware-keyboard contexts the
/// accessory bar still pins to the bottom — the canonical "Messages.app"
/// pattern.
struct KeyboardInputArea: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyboardInputController {
        KeyboardInputController()
    }
    func updateUIViewController(_ vc: KeyboardInputController, context: Context) {}
}

final class KeyboardInputController: UIViewController, UIKeyInput {

    private let bridge = EmulatorBridge.shared()

    // ADB scancodes (Apple Desktop Bus, used by KEGS adb.cpp)
    private enum ADB {
        static let escape:    Int32 = 0x35
        static let tab:       Int32 = 0x30
        static let `return`:  Int32 = 0x24
        static let delete:    Int32 = 0x33
        static let space:     Int32 = 0x31
        static let leftArrow: Int32 = 0x3B
        static let rightArrow:Int32 = 0x3C
        static let upArrow:   Int32 = 0x3E
        static let downArrow: Int32 = 0x3D
        static let shift:     Int32 = 0x38
        static let control:   Int32 = 0x36
        static let openApple: Int32 = 0x37
        static let solidApple:Int32 = 0x3A
        static let f1:        Int32 = 0x7A
        static let f2:        Int32 = 0x78
        static let f3:        Int32 = 0x63
        static let f4:        Int32 = 0x76
        static let f5:        Int32 = 0x60
        static let f6:        Int32 = 0x61
        static let f7:        Int32 = 0x62
        static let f8:        Int32 = 0x64
        static let f9:        Int32 = 0x65
        static let f10:       Int32 = 0x6D
        static let f11:       Int32 = 0x67
        static let f12:       Int32 = 0x6F
    }

    private var ctrlLatched = false
    private var openAppleLatched = false
    private var closedAppleLatched = false

    private lazy var accessoryBar: UIView = makeAccessoryBar()

    // MARK: UIResponder

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { accessoryBar }

    // MARK: UIKeyInput
    var hasText: Bool { false }

    func insertText(_ text: String) {
        if text == "\n" {
            sendKey(ADB.return)
            return
        }
        if ctrlLatched {
            bridge.keyDown(ADB.control)
            bridge.typeText(text)
            bridge.keyUp(ADB.control)
        } else {
            bridge.typeText(text)
        }
    }

    func deleteBackward() {
        sendKey(ADB.delete)
    }

    // Hardware-keyboard support. UIKeyInput.insertText only fires for the
    // *software* keyboard on custom responders; for an attached hardware
    // keyboard (Mac trackpad sim, iPad Magic Keyboard) we need pressesBegan.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if handleHardwareKey(key) {
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    private func handleHardwareKey(_ key: UIKey) -> Bool {
        switch key.keyCode {
        case .keyboardLeftArrow:   sendKey(ADB.leftArrow);  return true
        case .keyboardRightArrow:  sendKey(ADB.rightArrow); return true
        case .keyboardUpArrow:     sendKey(ADB.upArrow);    return true
        case .keyboardDownArrow:   sendKey(ADB.downArrow);  return true
        case .keyboardEscape:      sendKey(ADB.escape);     return true
        case .keyboardTab:         sendKey(ADB.tab);        return true
        case .keyboardReturnOrEnter: sendKey(ADB.return);   return true
        case .keyboardDeleteOrBackspace: sendKey(ADB.delete); return true
        default: break
        }
        let chars = key.characters
        if chars.isEmpty { return false }
        if key.modifierFlags.contains(.control) {
            bridge.keyDown(ADB.control)
            bridge.typeText(chars)
            bridge.keyUp(ADB.control)
            return true
        }
        bridge.typeText(chars)
        return true
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Defer so SwiftUI's hosting view has settled.
        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    // MARK: Send helpers

    private func sendKey(_ adb: Int32) {
        bridge.keyDown(adb)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.bridge.keyUp(adb)
        }
    }

    private func sendModifier(_ adb: Int32, latched: Bool) {
        if latched { bridge.keyDown(adb) } else { bridge.keyUp(adb) }
    }

    // MARK: Accessory bar

    private func makeAccessoryBar() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0,
                                            width: UIScreen.main.bounds.width,
                                            height: 92),
                              inputViewStyle: .keyboard)
        bar.backgroundColor = UIColor(white: 0.13, alpha: 1.0)
        bar.allowsSelfSizing = true
        bar.autoresizingMask = .flexibleWidth

        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
        ])

        // Row 1: esc | tab | ctrl | ⌘A | ⌥A | F1..F5 | RESET
        let row1 = UIStackView()
        row1.axis = .horizontal
        row1.distribution = .fillEqually
        row1.spacing = 4
        row1.addArrangedSubview(softKey("esc")  { [weak self] in self?.sendKey(ADB.escape) })
        row1.addArrangedSubview(softKey("tab")  { [weak self] in self?.sendKey(ADB.tab) })
        row1.addArrangedSubview(toggleKey("ctrl") { [weak self] on in
            self?.ctrlLatched = on
            self?.sendModifier(ADB.control, latched: on)
        })
        row1.addArrangedSubview(toggleKey("⌘A") { [weak self] on in
            self?.openAppleLatched = on
            self?.sendModifier(ADB.openApple, latched: on)
        })
        row1.addArrangedSubview(toggleKey("⌥A") { [weak self] on in
            self?.closedAppleLatched = on
            self?.sendModifier(ADB.solidApple, latched: on)
        })
        for (label, code) in [("F1",ADB.f1),("F2",ADB.f2),("F3",ADB.f3),("F4",ADB.f4),("F5",ADB.f5)] {
            row1.addArrangedSubview(softKey(label) { [weak self] in self?.sendKey(code) })
        }
        row1.addArrangedSubview(softKey("RESET", danger: true) { [weak self] in
            self?.bridge.reset()
        })
        stack.addArrangedSubview(row1)

        // Row 2: ◀︎ ▼ ▲ ▶︎ | F6..F12
        let row2 = UIStackView()
        row2.axis = .horizontal
        row2.distribution = .fillEqually
        row2.spacing = 4
        row2.addArrangedSubview(softKey("◀︎") { [weak self] in self?.sendKey(ADB.leftArrow) })
        row2.addArrangedSubview(softKey("▼") { [weak self] in self?.sendKey(ADB.downArrow) })
        row2.addArrangedSubview(softKey("▲") { [weak self] in self?.sendKey(ADB.upArrow) })
        row2.addArrangedSubview(softKey("▶︎") { [weak self] in self?.sendKey(ADB.rightArrow) })
        for (label, code) in [("F6",ADB.f6),("F7",ADB.f7),("F8",ADB.f8),("F9",ADB.f9),
                              ("F10",ADB.f10),("F11",ADB.f11),("F12",ADB.f12)] {
            row2.addArrangedSubview(softKey(label) { [weak self] in self?.sendKey(code) })
        }
        stack.addArrangedSubview(row2)

        return bar
    }

    private func softKey(_ title: String, danger: Bool = false,
                         action: @escaping () -> Void) -> UIButton {
        let b = AccessoryButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        b.backgroundColor = danger
            ? UIColor.systemRed.withAlphaComponent(0.5)
            : UIColor(white: 0.25, alpha: 1.0)
        b.setTitleColor(.white, for: .normal)
        b.layer.cornerRadius = 6
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func toggleKey(_ title: String,
                           onChange: @escaping (Bool) -> Void) -> UIButton {
        let b = AccessoryButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        b.backgroundColor = UIColor(white: 0.25, alpha: 1.0)
        b.setTitleColor(.white, for: .normal)
        b.layer.cornerRadius = 6
        var on = false
        b.addAction(UIAction { _ in
            on.toggle()
            b.backgroundColor = on ? UIColor.systemBlue : UIColor(white: 0.25, alpha: 1.0)
            onChange(on)
        }, for: .touchUpInside)
        return b
    }
}

private final class AccessoryButton: UIButton {
    override var intrinsicContentSize: CGSize {
        var s = super.intrinsicContentSize
        s.height = max(s.height, 36)
        return s
    }
}

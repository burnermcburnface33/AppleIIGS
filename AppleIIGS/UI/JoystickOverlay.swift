import SwiftUI
import UIKit

/// iDOS 3-style joystick + two action buttons. Touch the stick to move,
/// touch the buttons to fire open-apple / closed-apple. Multitouch is
/// supported (you can move the stick with one finger while pressing buttons
/// with another).
struct JoystickOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> JoystickUIView { JoystickUIView() }
    func updateUIView(_ uiView: JoystickUIView, context: Context) {}
}

final class JoystickUIView: UIView {

    private let bridge = EmulatorBridge.shared()

    // The analog stick on the left
    private let stickBase = UIView()
    private let stickKnob = UIView()
    private var stickTouch: UITouch?
    private var stickCenter: CGPoint = .zero
    private let stickRadius: CGFloat = 70

    // Two fire buttons on the right
    private let openAppleBtn = UIButton(type: .system)
    private let closedAppleBtn = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        // Stick base
        stickBase.backgroundColor = UIColor(white: 1.0, alpha: 0.10)
        stickBase.layer.cornerRadius = stickRadius
        stickBase.layer.borderColor = UIColor(white: 1.0, alpha: 0.4).cgColor
        stickBase.layer.borderWidth = 1
        stickBase.isUserInteractionEnabled = false
        addSubview(stickBase)

        // Stick knob
        stickKnob.backgroundColor = UIColor(white: 1.0, alpha: 0.35)
        stickKnob.layer.cornerRadius = 36
        stickKnob.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        stickKnob.layer.borderWidth = 1
        stickKnob.isUserInteractionEnabled = false
        addSubview(stickKnob)

        // Buttons
        configureButton(openAppleBtn,  title: "⌘A", action: #selector(openAppleDown), up: #selector(openAppleUp))
        configureButton(closedAppleBtn, title: "⌥A", action: #selector(closedAppleDown), up: #selector(closedAppleUp))
        addSubview(openAppleBtn)
        addSubview(closedAppleBtn)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureButton(_ b: UIButton, title: String, action: Selector, up: Selector) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 24, weight: .bold)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor(white: 1.0, alpha: 0.15)
        b.layer.cornerRadius = 36
        b.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        b.layer.borderWidth = 1
        b.addTarget(self, action: action, for: [.touchDown, .touchDragEnter])
        b.addTarget(self, action: up,     for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    @objc private func openAppleDown()   { bridge.setJoystickButton(0, pressed: true) }
    @objc private func openAppleUp()     { bridge.setJoystickButton(0, pressed: false) }
    @objc private func closedAppleDown() { bridge.setJoystickButton(1, pressed: true) }
    @objc private func closedAppleUp()   { bridge.setJoystickButton(1, pressed: false) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let leftCenter = CGPoint(x: 100, y: h - 100)
        stickCenter = leftCenter
        stickBase.frame = CGRect(x: leftCenter.x - stickRadius, y: leftCenter.y - stickRadius,
                                 width: stickRadius * 2, height: stickRadius * 2)
        recenter()

        let btnSize: CGFloat = 72
        let rightX = bounds.width - 30 - btnSize
        let leftX  = rightX - btnSize - 16
        let btnY   = h - 110
        closedAppleBtn.frame = CGRect(x: leftX,  y: btnY, width: btnSize, height: btnSize)
        openAppleBtn.frame   = CGRect(x: rightX, y: btnY, width: btnSize, height: btnSize)
    }

    private func recenter() {
        stickKnob.frame = CGRect(x: stickCenter.x - 36, y: stickCenter.y - 36, width: 72, height: 72)
        bridge.setJoystickX(0, y: 0)
    }

    private func updateStick(_ p: CGPoint) {
        var dx = p.x - stickCenter.x
        var dy = p.y - stickCenter.y
        let mag = sqrt(dx*dx + dy*dy)
        if mag > stickRadius {
            dx = dx / mag * stickRadius
            dy = dy / mag * stickRadius
        }
        let knob = CGPoint(x: stickCenter.x + dx, y: stickCenter.y + dy)
        stickKnob.frame = CGRect(x: knob.x - 36, y: knob.y - 36, width: 72, height: 72)
        bridge.setJoystickX(Float(dx / stickRadius), y: Float(dy / stickRadius))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let loc = touch.location(in: self)
            // Only claim touches on the left half - buttons handle themselves
            if loc.x < bounds.width / 2 {
                stickTouch = touch
                updateStick(loc)
            }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = stickTouch, touches.contains(t) else { return }
        updateStick(t.location(in: self))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = stickTouch, touches.contains(t) {
            stickTouch = nil
            recenter()
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

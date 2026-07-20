import SwiftUI
import UIKit

/// SwiftUI view that displays the emulator framebuffer using CGImage backed
/// by the shared framebuffer pointer. Updated each VBL via a CADisplayLink.
struct EmulatorScreenView: UIViewRepresentable {

    func makeUIView(context: Context) -> EmulatorScreenUIView {
        EmulatorScreenUIView()
    }

    func updateUIView(_ uiView: EmulatorScreenUIView, context: Context) {}
}

final class EmulatorScreenUIView: UIView, EmulatorBridgeDelegate {

    private var displayLink: CADisplayLink?
    private let imageLayer = CALayer()
    private var colorSpace = CGColorSpaceCreateDeviceRGB()
    private var dataProvider: CGDataProvider?
    private var lastUpdate = CACurrentMediaTime()
    private let bridge = EmulatorBridge.shared()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(imageLayer)
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .linear
        imageLayer.backgroundColor = UIColor.black.cgColor
        bridge.delegate = self
        setupDisplayLink()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        displayLink?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Preserve 4:3-ish (640x400) aspect ratio
        let aspect = CGFloat(bridge.frameWidth) / CGFloat(bridge.frameHeight)
        let bw = bounds.width
        let bh = bounds.height
        var w = bw
        var h = w / aspect
        if h > bh {
            h = bh
            w = h * aspect
        }
        let x = (bw - w) / 2.0
        let y = (bh - h) / 2.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(x: x, y: y, width: w, height: h)
        CATransaction.commit()
    }

    private func setupDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if now - lastUpdate < 1.0/60.0 { return }
        lastUpdate = now
        refreshImage()
    }

    private func refreshImage() {
        let w = bridge.frameWidth
        let h = bridge.frameHeight
        let stride = bridge.frameBytesPerRow
        guard let ptr = bridge.frameBufferPtr else { return }

        let length = stride * h
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr),
                        count: length,
                        deallocator: .none)
        let provider = CGDataProvider(data: data as CFData)
        guard let provider = provider,
              let image = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    // MARK: EmulatorBridgeDelegate
    func emulatorDidUpdateFrame() {
        // Frame ready - displayLink will pick it up
    }

    func emulatorDidChangeDiskLight(_ on: Bool, slot: Int, drive: Int, track: Int) {
        // UI handles this via Combine through EmulatorController
    }
}

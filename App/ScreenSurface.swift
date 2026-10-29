import SwiftUI

struct ScreenSurface: UIViewRepresentable {
    var image: UIImage?
    var enabled: Bool
    var fill: Bool = false
    var optionHeld: Bool = false
    var key: (UInt32, Bool) -> Void
    var pointer: (CGPoint, UInt8) -> Void
    func makeUIView(context: Context) -> RemoteCanvas { RemoteCanvas() }
    func updateUIView(_ view: RemoteCanvas, context: Context) {
        view.remoteOptionHeld = optionHeld; view.fill = fill; view.image = image; view.key = key; view.pointer = pointer
        view.isUserInteractionEnabled = enabled
        if enabled && !view.isFirstResponder { view.becomeFirstResponder() }
    }
}

final class RemoteCanvas: UIView {
    var remoteOptionHeld = false
    var fill = false { didSet { setNeedsDisplay() } }
    var image: UIImage? { didSet { setNeedsDisplay() } }
    var key: ((UInt32, Bool) -> Void)?
    var pointer: ((CGPoint, UInt8) -> Void)?
    private var held: [Int: UInt32] = [:]
    private var scrollOrigin: CGFloat = 0
    override var canBecomeFirstResponder: Bool { true }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        contentMode = .redraw
        clipsToBounds = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2
        addGestureRecognizer(tap); addGestureRecognizer(drag); addGestureRecognizer(scroll)
        isAccessibilityElement = true
        accessibilityLabel = "맥 화면. 탭으로 클릭, 한 손가락으로 드래그, 두 손가락으로 스크롤"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var imageRect: CGRect {
        guard let image, bounds.width > 0, bounds.height > 0 else { return .zero }
        let horizontal = bounds.width / image.size.width
        let vertical = bounds.height / image.size.height
        let scale = fill ? max(horizontal, vertical) : min(horizontal, vertical)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ rect: CGRect) { image?.draw(in: imageRect) }
    private func remote(_ recognizer: UIGestureRecognizer) -> CGPoint? {
        guard let image, imageRect.width > 0 else { return nil }
        let point = recognizer.location(in: self)
        if recognizer.state == .began || recognizer is UITapGestureRecognizer {
            guard imageRect.contains(point) else { return nil }
        }
        return CGPoint(x: max(0, min(image.size.width - 1, (point.x - imageRect.minX) / imageRect.width * image.size.width)),
                       y: max(0, min(image.size.height - 1, (point.y - imageRect.minY) / imageRect.height * image.size.height)))
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard let point = remote(gesture) else { return }
        pointer?(point, 1); pointer?(point, 0)
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let point = remote(gesture) else { return }
        pointer?(point, gesture.state == .began || gesture.state == .changed ? 1 : 0)
    }
    @objc private func scroll(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { scrollOrigin = 0 }
        guard let point = remote(gesture) else { return }
        let distance = gesture.translation(in: self).y - scrollOrigin
        if abs(distance) > 16 {
            pointer?(point, distance > 0 ? 8 : 16); pointer?(point, 0)
            scrollOrigin = gesture.translation(in: self).y
        }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // UIPress sets are unordered: transmit modifiers before the key they modify.
        let ordered = presses.sorted {
            let left = $0.key.map { (224...231).contains($0.keyCode.rawValue) } ?? false
            let right = $1.key.map { (224...231).contains($0.keyCode.rawValue) } ?? false
            return left && !right
        }
        for press in ordered {
            guard let input = press.key else { continue }
            let hid = input.keyCode.rawValue
            let option = remoteOptionHeld || held[230] != nil
            let symbol = PhysicalKey.symbol(hid: hid, shift: input.modifierFlags.contains(.shift), option: option)
            if let symbol { held[hid] = symbol; key?(symbol, true) }
        }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { release(presses) }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { release(presses) }
    private func release(_ presses: Set<UIPress>) {
        for press in presses.sorted(by: {
            ($0.key?.keyCode.rawValue ?? 0) < ($1.key?.keyCode.rawValue ?? 0)
        }) {
            if let hid = press.key?.keyCode.rawValue, let symbol = held.removeValue(forKey: hid) {
                key?(symbol, false)
            }
        }
    }
    override func resignFirstResponder() -> Bool {
        held.values.forEach { key?($0, false) }; held.removeAll()
        return super.resignFirstResponder()
    }
}

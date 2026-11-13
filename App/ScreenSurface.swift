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
        // Frame updates must not steal first responder from a sheet, alert, or text field.
        view.setKeyCaptureEnabled(enabled)
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
    private var keyCaptureEnabled = false
    private var allowKeyCapture = false
    private var keyCaptureArmed = false
    private var updatingKeyCapture = false
    // Cached so UIKit can ask during a responder transition without walking the chain.
    override var canBecomeFirstResponder: Bool { allowKeyCapture }
    func setKeyCaptureEnabled(_ enabled: Bool) {
        keyCaptureEnabled = enabled
        refreshKeyCapture()
        armKeyCaptureFollowUp()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshKeyCapture()
        if window != nil { armKeyCaptureFollowUp() }
    }
    @objc private func textInputChanged() {
        refreshKeyCapture()
        armKeyCaptureFollowUp()
    }
    private func capture() -> KeyboardCapture {
        let presented = interfacePresented
        let textFocused = !presented && !isFirstResponder && Self.hasFocusedTextInput(window)
        return KeyboardCapture(enabled: keyCaptureEnabled && window != nil, interfacePresented: presented, textInputFocused: textFocused, isFirstResponder: isFirstResponder)
    }
    private var interfacePresented: Bool {
        if let root = window?.rootViewController, Self.presentsInterface(root) { return true }
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController, controller.presentedViewController != nil { return true }
            responder = current.next
        }
        return false
    }
    private static func presentsInterface(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.children.contains(where: presentsInterface)
    }
    private static func hasFocusedTextInput(_ view: UIView?) -> Bool {
        guard let view else { return false }
        if view.isFirstResponder, view is UIKeyInput { return true }
        return view.subviews.contains(where: hasFocusedTextInput)
    }
    private func refreshKeyCapture() {
        guard !updatingKeyCapture else { return }
        updatingKeyCapture = true
        defer { updatingKeyCapture = false }
        let state = capture()
        allowKeyCapture = state.forwardsToRemote
        switch state.action {
        case .become: becomeFirstResponder()
        case .resign: resignFirstResponder()
        case .stay: break
        }
    }
    private func armKeyCaptureFollowUp() {
        guard !keyCaptureArmed else { return }
        keyCaptureArmed = true
        DispatchQueue.main.async { [weak self] in self?.refreshKeyCapture() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.keyCaptureArmed = false
            self.refreshKeyCapture()
            let state = self.capture()
            if self.keyCaptureEnabled, state.interfacePresented || state.textInputFocused { self.armKeyCaptureFollowUp() }
        }
    }
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
        let rightClick = SecondaryClickRecognizer(target: self, action: #selector(rightClick(_:)))
        rightClick.numberOfTouchesRequired = 1
        rightClick.minimumPressDuration = 0.5
        // A long press is only a right click. Tap and drag wait until it fails.
        tap.require(toFail: rightClick)
        drag.require(toFail: rightClick)
        addGestureRecognizer(tap); addGestureRecognizer(drag); addGestureRecognizer(scroll); addGestureRecognizer(rightClick)
        isAccessibilityElement = true
        accessibilityLabel = "맥 화면. 탭으로 클릭, 길게 눌러 우클릭, 한 손가락으로 드래그, 두 손가락으로 스크롤"
        let center = NotificationCenter.default
        for name in [UITextField.textDidBeginEditingNotification, UITextField.textDidEndEditingNotification, UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification] {
            center.addObserver(self, selector: #selector(textInputChanged), name: name, object: nil)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
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
        click(point, button: PointerButtons.left)
    }
    @objc private func rightClick(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, gesture.numberOfTouches == 1, let point = remote(gesture) else { return }
        click(point, button: PointerButtons.right)
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let point = remote(gesture) else { return }
        pointer?(point, gesture.state == .began || gesture.state == .changed ? PointerButtons.left : PointerButtons.none)
    }
    @objc private func scroll(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { scrollOrigin = 0 }
        guard let point = remote(gesture) else { return }
        let distance = gesture.translation(in: self).y - scrollOrigin
        if abs(distance) > 16 {
            pointer?(point, distance > 0 ? PointerButtons.wheelUp : PointerButtons.wheelDown)
            pointer?(point, PointerButtons.none)
            scrollOrigin = gesture.translation(in: self).y
        }
    }
    private func click(_ point: CGPoint, button: UInt8) {
        for mask in PointerButtons.click(button) { pointer?(point, mask) }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard capture().forwardsToRemote else { super.pressesBegan(presses, with: event); return }
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
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard capture().forwardsToRemote || !held.isEmpty else { super.pressesEnded(presses, with: event); return }
        release(presses)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard capture().forwardsToRemote || !held.isEmpty else { super.pressesCancelled(presses, with: event); return }
        release(presses)
    }
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

/// One-finger long press. A second finger on the screen fails it, so a two-finger scroll cannot also right-click.
final class SecondaryClickRecognizer: UILongPressGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        failIfAnotherFinger(event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        failIfAnotherFinger(event)
    }
    private func failIfAnotherFinger(_ event: UIEvent) {
        guard state == .possible, let view else { return }
        let active = event.touches(for: view)?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
        if active > numberOfTouchesRequired { state = .failed }
    }
}

import SwiftUI

struct ScreenSurface: UIViewRepresentable {
    var image: UIImage?
    var enabled: Bool
    var fill: Bool = false
    var optionHeld: Bool = false
    var suspendKeyCapture = false
    var cursor: RemoteCursor?
    var cursorHidden = false
    var key: (UInt32, Bool) -> Void
    var pointer: (CGPoint, UInt8) -> Void
    func makeUIView(context: Context) -> RemoteCanvas { RemoteCanvas() }
    func updateUIView(_ view: RemoteCanvas, context: Context) {
        view.remoteOptionHeld = optionHeld
        view.fill = fill
        view.image = image
        view.key = key
        view.pointer = pointer
        view.suspendKeyCapture = suspendKeyCapture
        if view.serverCursor != cursor { view.serverCursor = cursor }
        if view.serverCursorHidden != cursorHidden { view.serverCursorHidden = cursorHidden }
        view.isUserInteractionEnabled = enabled
        // Frame updates must not steal first responder from a sheet, alert, or text field.
        view.setKeyCaptureEnabled(enabled)
    }
}

final class RemoteCanvas: UIView, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    var remoteOptionHeld = false
    var fill = false { didSet { setNeedsDisplay() } }
    var image: UIImage? { didSet { setNeedsDisplay(); updateCursorLayer() } }
    var key: ((UInt32, Bool) -> Void)?
    var pointer: ((CGPoint, UInt8) -> Void)?
    var suspendKeyCapture = false
    var serverCursor: RemoteCursor? { didSet { cachedServerCursor = nil; updateCursorLayer() } }
    var serverCursorHidden = false { didSet { updateCursorLayer() } }
    private var held: [Int: UInt32] = [:]
    private var scrollOrigin: CGFloat = 0
    private var keyCaptureEnabled = false
    private var allowKeyCapture = false
    private var keyCaptureArmed = false
    private var updatingKeyCapture = false
    private var pointerPresses: [PointerPressRecognizer] = []
    private var pointerRecognizers: [UIGestureRecognizer] = []
    private var wheelPendingX: Double = 0
    private var wheelPendingY: Double = 0
    private var lastPoint: CGPoint?
    private var suppressPointerTap = false
    private var suppressGeneration = 0
    private var coalescer = PointerCoalescer()
    private var flushTicket = 0
    private var pointerActive = false
    private var pointerLocation: CGPoint?
    private let cursorLayer = CALayer()
    private var cachedServerCursor: (RemoteCursor, CGImage)?
    private static let localArrow = LocalArrow.make()
    // Cached so UIKit can ask during a responder transition without walking the chain.
    override var canBecomeFirstResponder: Bool { allowKeyCapture }
    /// Finger and Pencil stay on the original gestures. Pointer clicks are a different touch type
    /// once UIApplicationSupportsIndirectInputEvents is set, so a mouse-down is not a long press.
    private static let directTouches = [
        NSNumber(value: UITouch.TouchType.direct.rawValue),
        NSNumber(value: UITouch.TouchType.pencil.rawValue)
    ]
    private static let pointerTouches = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
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
        let presented = suspendKeyCapture || interfacePresented
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
        installTouchGestures()
        installPointerGestures()
        cursorLayer.contentsGravity = .resize
        cursorLayer.isHidden = true
        layer.addSublayer(cursorLayer)
        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityLabel = "맥 화면. 탭으로 클릭, 길게 눌러 우클릭, 한 손가락으로 드래그, 두 손가락으로 스크롤. 마우스나 트랙패드로 포인터를 움직이고 클릭하고 스크롤"
        let center = NotificationCenter.default
        for name in [UITextField.textDidBeginEditingNotification, UITextField.textDidEndEditingNotification, UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification] {
            center.addObserver(self, selector: #selector(textInputChanged), name: name, object: nil)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func installTouchGestures() {
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
        for recognizer in [tap, drag, scroll, rightClick] as [UIGestureRecognizer] {
            recognizer.allowedTouchTypes = Self.directTouches
            addGestureRecognizer(recognizer)
        }
    }
    private func installPointerGestures() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheel(_:)))
        wheel.allowedScrollTypesMask = UIScrollTypeMask.all
        // Touch pans stay on the finger recognizers. Zero touches keeps this recognizer on
        // wheel and trackpad scroll events, which report no UITouch.
        wheel.minimumNumberOfTouches = 0
        wheel.maximumNumberOfTouches = 0
        let buttons: [UIEvent.ButtonMask] = [.primary, .secondary, UIEvent.ButtonMask.button(3)]
        var presses: [PointerPressRecognizer] = []
        var taps: [UITapGestureRecognizer] = []
        for mask in buttons {
            let press = PointerPressRecognizer(requiredButton: mask, target: self, action: #selector(pointerPress(_:)))
            let tap = UITapGestureRecognizer(target: self, action: #selector(pointerTap(_:)))
            tap.buttonMaskRequired = mask
            tap.allowedTouchTypes = Self.pointerTouches
            presses.append(press)
            taps.append(tap)
        }
        pointerPresses = presses
        pointerRecognizers = [hover, wheel] + presses + taps
        for recognizer in pointerRecognizers {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            addGestureRecognizer(recognizer)
        }
    }

    private var imageRect: CGRect {
        guard let image,
              let frame = PointerMapping.displayedFrame(viewWidth: Double(bounds.width), viewHeight: Double(bounds.height), imageWidth: Double(image.size.width), imageHeight: Double(image.size.height), fill: fill)
        else { return .zero }
        return CGRect(x: CGFloat(frame.x), y: CGFloat(frame.y), width: CGFloat(frame.width), height: CGFloat(frame.height))
    }
    override func draw(_ rect: CGRect) { image?.draw(in: imageRect) }
    override func layoutSubviews() {
        super.layoutSubviews()
        updateCursorLayer()
    }
    private func framebufferPoint(_ viewPoint: CGPoint, clamp: Bool) -> CGPoint? {
        guard let image,
              let point = PointerMapping.framebufferPoint(viewX: Double(viewPoint.x), viewY: Double(viewPoint.y), viewWidth: Double(bounds.width), viewHeight: Double(bounds.height), imageWidth: Double(image.size.width), imageHeight: Double(image.size.height), fill: fill, clamp: clamp)
        else { return nil }
        return CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
    }
    private func remote(_ recognizer: UIGestureRecognizer) -> CGPoint? {
        let requireInside = recognizer.state == .began || recognizer is UITapGestureRecognizer
        return framebufferPoint(recognizer.location(in: self), clamp: !requireInside)
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
        emit(point, gesture.state == .began || gesture.state == .changed ? PointerButtons.left : PointerButtons.none)
    }
    @objc private func scroll(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { scrollOrigin = 0 }
        guard let point = remote(gesture) else { return }
        let distance = gesture.translation(in: self).y - scrollOrigin
        if abs(distance) > 16 {
            emit(point, distance > 0 ? PointerButtons.wheelUp : PointerButtons.wheelDown)
            emit(point, PointerButtons.none)
            scrollOrigin = gesture.translation(in: self).y
        }
    }
    private var heldButtons: UInt8 {
        let raw = pointerPresses.reduce(0) { partial, press in
            guard press.state == .began || press.state == .changed else { return partial }
            return partial | press.requiredButton.rawValue
        }
        return PointerButtons.mask(uiButtonMask: raw)
    }
    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            notePointer(gesture.location(in: self), active: true)
            guard heldButtons == 0, let point = framebufferPoint(gesture.location(in: self), clamp: false) else { return }
            emit(point, PointerButtons.none)
        case .ended, .cancelled, .failed:
            if heldButtons == 0 { notePointer(gesture.location(in: self), active: false) }
        default:
            break
        }
    }
    @objc private func pointerPress(_ gesture: PointerPressRecognizer) {
        switch gesture.state {
        case .began, .changed:
            notePointer(gesture.location(in: self), active: true)
            guard let point = remote(gesture) else { return }
            claimPointerClick()
            gesture.deliveredDown = true
            let required = PointerButtons.mask(uiButtonMask: gesture.requiredButton.rawValue)
            let reported = PointerButtons.mask(uiButtonMask: gesture.buttonMask.rawValue)
            emit(point, heldButtons | (reported & required))
        case .ended, .cancelled, .failed:
            let delivered = gesture.deliveredDown
            if delivered, let point = remote(gesture) ?? lastPoint {
                emit(point, heldButtons)
            }
            gesture.deliveredDown = false
            // Only the press that actually sent a button may clear the tap guard.
            // A second button that fails must not drop a click still in progress.
            guard delivered else { return }
            let generation = suppressGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.suppressGeneration == generation else { return }
                self.suppressPointerTap = false
            }
        default:
            break
        }
    }
    @objc private func pointerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, !suppressPointerTap else { return }
        guard let point = framebufferPoint(gesture.location(in: self), clamp: false) else { return }
        click(point, button: PointerButtons.mask(uiButtonMask: gesture.buttonMaskRequired.rawValue))
    }
    @objc private func wheel(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed || gesture.state == .ended || gesture.state == .cancelled else { return }
        if gesture.state != .cancelled { notePointer(gesture.location(in: self), active: true) }
        if gesture.state == .began {
            wheelPendingX = 0
            wheelPendingY = 0
        }
        let translation = gesture.translation(in: self)
        wheelPendingX += Double(translation.x)
        wheelPendingY += Double(translation.y)
        gesture.setTranslation(.zero, in: self)
        let finishing = gesture.state == .ended || gesture.state == .cancelled
        let ticks = PointerScroll.ticks(deltaX: wheelPendingX, deltaY: wheelPendingY, held: heldButtons, flushRemainder: finishing)
        guard !ticks.masks.isEmpty else { return }
        guard let point = framebufferPoint(gesture.location(in: self), clamp: false) ?? lastPoint else { return }
        wheelPendingX -= ticks.consumedX
        wheelPendingY -= ticks.consumedY
        for mask in ticks.masks { emit(point, mask) }
    }
    private func claimPointerClick() {
        suppressPointerTap = true
        suppressGeneration += 1
    }
    private func emit(_ point: CGPoint, _ buttons: UInt8) {
        lastPoint = point
        let sample = PointerCoalescer.Sample(x: Int(point.x), y: Int(point.y), buttons: buttons)
        deliver(coalescer.submit(sample, nowMs: Self.milliseconds()))
    }
    private func deliver(_ result: PointerCoalescer.Result) {
        for sample in result.send { pointer?(CGPoint(x: sample.x, y: sample.y), sample.buttons) }
        guard let delay = result.flushAfterMs else { return }
        flushTicket += 1
        let ticket = flushTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(delay, 1))) { [weak self] in
            guard let self, self.flushTicket == ticket else { return }
            self.deliver(self.coalescer.flush(nowMs: Self.milliseconds()))
        }
    }
    private static func milliseconds() -> Int { Int(Date().timeIntervalSinceReferenceDate * 1000) }
    private func notePointer(_ location: CGPoint, active: Bool) {
        pointerLocation = location
        pointerActive = active
        updateCursorLayer()
    }
    private var pointsPerPixel: Double {
        guard let image, image.size.width > 0 else { return 1 }
        let rect = imageRect
        guard rect.width > 0 else { return 1 }
        return Double(rect.width / image.size.width)
    }
    private func updateCursorLayer() {
        let glyph = PointerGlyph.choose(pointerInUse: pointerActive, hasServerCursor: serverCursor?.isHidden == false, serverHidCursor: serverCursorHidden)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let location = pointerLocation else { cursorLayer.isHidden = true; return }
        switch glyph {
        case .hidden:
            cursorLayer.isHidden = true
        case .localArrow:
            let arrow = Self.localArrow
            cursorLayer.isHidden = false
            cursorLayer.contents = arrow.image
            cursorLayer.contentsScale = arrow.scale
            cursorLayer.magnificationFilter = .linear
            cursorLayer.frame = CGRect(x: location.x - arrow.hotspot.x, y: location.y - arrow.hotspot.y, width: arrow.size.width, height: arrow.size.height)
        case .server:
            guard let cursor = serverCursor, !cursor.isHidden, let cg = serverImage(cursor),
                  let layout = CursorLayout.frame(pointerX: Double(location.x), pointerY: Double(location.y), hotspotX: cursor.hotspotX, hotspotY: cursor.hotspotY, cursorWidth: cursor.width, cursorHeight: cursor.height, pointScale: pointsPerPixel) else {
                cursorLayer.isHidden = true
                return
            }
            cursorLayer.isHidden = false
            cursorLayer.contents = cg
            cursorLayer.contentsScale = 1
            cursorLayer.magnificationFilter = .nearest
            cursorLayer.frame = CGRect(x: layout.x, y: layout.y, width: layout.width, height: layout.height)
        }
    }
    private func serverImage(_ cursor: RemoteCursor) -> CGImage? {
        if let cached = cachedServerCursor, cached.0 == cursor { return cached.1 }
        guard let provider = CGDataProvider(data: cursor.rgba as CFData),
              let image = CGImage(width: cursor.width, height: cursor.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cursor.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        cachedServerCursor = (cursor, image)
        return image
    }
    private func click(_ point: CGPoint, button: UInt8) {
        for mask in PointerButtons.click(button) { emit(point, mask) }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        guard let press = gestureRecognizer as? PointerPressRecognizer else { return true }
        return event.buttonMask.contains(press.requiredButton)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Scroll events are not touches. Rejecting touches here keeps the wheel pan from delaying a finger drag.
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.maximumNumberOfTouches == 0 { return false }
        if gestureRecognizer is PointerPressRecognizer { return touch.type == .indirectPointer }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        pointerRecognizers.contains { $0 === gestureRecognizer } && pointerRecognizers.contains { $0 === other }
    }
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle.hidden()
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

private enum LocalArrow {
    static func make() -> (image: CGImage, scale: CGFloat, size: CGSize, hotspot: CGPoint) {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let size = CGSize(width: 28, height: 36)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 3, y: 2))
            path.addLine(to: CGPoint(x: 3, y: 24))
            path.addLine(to: CGPoint(x: 8.2, y: 18.8))
            path.addLine(to: CGPoint(x: 12.4, y: 29))
            path.addLine(to: CGPoint(x: 16.6, y: 27.2))
            path.addLine(to: CGPoint(x: 12.2, y: 17))
            path.addLine(to: CGPoint(x: 19.2, y: 16.8))
            path.close()
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.7).cgColor)
            UIColor.white.setStroke()
            path.lineWidth = 3.5
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
            context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.black.setFill()
            path.fill()
        }
        return (image.cgImage!, image.scale, image.size, CGPoint(x: 3, y: 2))
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
        // A connected mouse is not a second finger, so it must not cancel a touch long-press.
        let active = event.touches(for: view)?.filter {
            $0.phase != .ended && $0.phase != .cancelled && $0.type != .indirectPointer
        }.count ?? 0
        if active > numberOfTouchesRequired { state = .failed }
    }
}

/// One physical button, from the moment it goes down through the drag until it comes up.
final class PointerPressRecognizer: UILongPressGestureRecognizer {
    let requiredButton: UIEvent.ButtonMask
    var deliveredDown = false
    init(requiredButton: UIEvent.ButtonMask, target: Any?, action: Selector?) {
        self.requiredButton = requiredButton
        super.init(target: target, action: action)
        minimumPressDuration = 0
        allowableMovement = .greatestFiniteMagnitude
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    }
    override func shouldReceive(_ event: UIEvent) -> Bool {
        super.shouldReceive(event) && event.buttonMask.contains(requiredButton)
    }
    override func reset() {
        deliveredDown = false
        super.reset()
    }
}

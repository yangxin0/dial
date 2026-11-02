import AppKit

/// The floating window: borderless, on every space, never takes the
/// keyboard focus from the app in front. Dragged anywhere but a click.
final class DialPanel: NSPanel {
    let view = DialView(frame: NSRect(x: 0, y: 0, width: DialView.width, height: DialView.height))

    init() {
        super.init(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = view
        restorePosition()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            self?.savePosition()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        orderFrontRegardless()
    }

    private func restorePosition() {
        let defaults = UserDefaults.standard
        if let x = defaults.object(forKey: "dial.x") as? Double, let y = defaults.object(forKey: "dial.y") as? Double,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(NSPoint(x: x, y: y)) }) {
            setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24, y: visible.minY + 24))
    }

    private func savePosition() {
        UserDefaults.standard.set(Double(frame.origin.x), forKey: "dial.x")
        UserDefaults.standard.set(Double(frame.origin.y), forKey: "dial.y")
    }
}

/// The dial itself: an app ring around a microphone button, with what
/// was heard underneath.
final class DialView: NSView {
    static let width: CGFloat = 200
    static let height: CGFloat = 240
    static let outerRadius: CGFloat = 86
    static let innerRadius: CGFloat = 50
    static let buttonRadius: CGFloat = 40
    static let maxSlots = 8

    weak var controller: DialController?

    var ring: [AppInfo] = [] {
        didSet {
            needsDisplay = true
            retarget()
        }
    }
    var activeID: String? {
        didSet {
            needsDisplay = true
            retarget()
        }
    }
    /// The ring's turn, in radians: slot 0 sits at the top plus this. It
    /// follows a drag, and eases to put the active app at the top.
    private var rotation: CGFloat = 0
    private var rotationTarget: CGFloat = 0
    private var spinTimer: Timer?
    var phase: Phase = .idle {
        didSet {
            needsDisplay = true
            pulse(phase == .listening || phase == .thinking)
        }
    }
    var transcript: String = "" { didSet { needsDisplay = true } }
    var hint: String? { didSet { needsDisplay = true } }
    var hintIsError = false { didSet { needsDisplay = true } }
    /// The pointer is over the dial: the keys are the dial's.
    private(set) var armed = false { didSet { needsDisplay = true } }
    /// Which part the pointer is over, lit so the eye follows it.
    enum HoverZone { case none, ring, button }
    private(set) var hover = HoverZone.none {
        didSet { if hover != oldValue { needsDisplay = true } }
    }

    private var pulseTimer: Timer?
    private var pulsePhase: CGFloat = 0
    private var mouseDownAt: NSPoint?
    private var dragging = false
    /// A drag that began on the ring turns it; one that began on the
    /// button moves the dial.
    private var dragZone = HoverZone.none
    private var lastAngle: CGFloat = 0
    private var wheelX: CGFloat = 0
    private var wheelY: CGFloat = 0

    private var center: NSPoint { NSPoint(x: bounds.midX, y: Self.height - 8 - Self.outerRadius) }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        armed = true
        hover = zone(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        armed = false
        hover = .none
    }

    override func mouseMoved(with event: NSEvent) {
        hover = zone(at: convert(event.locationInWindow, from: nil))
    }

    private func zone(at point: NSPoint) -> HoverZone {
        let d = hypot(point.x - center.x, point.y - center.y)
        if d <= Self.buttonRadius { return .button }
        if d <= Self.outerRadius { return .ring }
        return .none
    }

    private func pulse(_ on: Bool) {
        if on, pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.pulsePhase += 0.12
                self.needsDisplay = true
            }
        } else if !on {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulsePhase = 0
        }
    }

    // MARK: - Geometry and the turn

    private var slotCount: Int { min(ring.count, Self.maxSlots) }
    private var slotAngle: CGFloat { slotCount == 0 ? 0 : 2 * .pi / CGFloat(slotCount) }

    /// Slots sit in the middle of the band the eye sees: between the
    /// button's edge and the rim, turned by `rotation`.
    private func slotCenter(_ index: Int, of count: Int) -> NSPoint {
        let angle = CGFloat.pi / 2 - CGFloat(index) * 2 * .pi / CGFloat(count) + rotation
        let radius = (Self.outerRadius + Self.buttonRadius) / 2
        return NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private func slot(at point: NSPoint) -> Int? {
        let d = hypot(point.x - center.x, point.y - center.y)
        guard d > Self.buttonRadius, d <= Self.outerRadius, slotCount > 0 else { return nil }
        let angle = atan2(point.y - center.y, point.x - center.x)
        var turns = (CGFloat.pi / 2 + rotation - angle) / (2 * .pi)  // clockwise from the top
        turns -= turns.rounded(.down)
        return Int((turns * CGFloat(slotCount)).rounded()) % slotCount
    }

    /// The slot nearest the top for the current turn.
    private var slotAtTop: Int? {
        guard slotCount > 0 else { return nil }
        let index = Int((rotation / slotAngle).rounded()) % slotCount
        return index < 0 ? index + slotCount : index
    }

    /// Aims the turn so the active app sits at the top, the short way
    /// round, and eases there unless a drag has the ring.
    private func retarget() {
        guard let active = activeID, let index = ring.firstIndex(where: { $0.id == active }), index < slotCount else { return }
        var target = CGFloat(index) * slotAngle
        while target - rotation > .pi { target -= 2 * .pi }
        while target - rotation < -.pi { target += 2 * .pi }
        rotationTarget = target
        if !(dragging && dragZone == .ring) { spin() }
    }

    private func spin() {
        guard spinTimer == nil else { return }
        spinTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let diff = self.rotationTarget - self.rotation
            if abs(diff) < 0.002 {
                self.rotation = self.rotationTarget
                self.spinTimer?.invalidate()
                self.spinTimer = nil
            } else {
                self.rotation += diff * 0.22
            }
            self.needsDisplay = true
        }
    }

    /// A drag let go: the app nearest the top is the one picked, and the
    /// ring settles on it.
    private func settle() {
        guard let index = slotAtTop else { return }
        let id = ring[index].id
        Log.write("ring let go at slot \(index): \(ring[index].name)")
        if id != activeID {
            controller?.pick(id)
        } else {
            retarget()
        }
    }

    private func inButton(_ point: NSPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= Self.buttonRadius
    }

    // MARK: - Mouse

    private func angle(of point: NSPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        dragging = false
        let point = convert(event.locationInWindow, from: nil)
        dragZone = zone(at: point)
        lastAngle = angle(of: point)
        if dragZone == .ring {
            spinTimer?.invalidate()
            spinTimer = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt else { return }
        if !dragging {
            guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
            dragging = true
            Log.write("drag began in \(dragZone)")
            if dragZone != .ring {
                window?.performDrag(with: event)
                return
            }
        }
        guard dragZone == .ring else { return }
        // The ring follows the pointer round.
        let now = angle(of: convert(event.locationInWindow, from: nil))
        var delta = now - lastAngle
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        lastAngle = now
        rotation += delta
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownAt = nil }
        if dragging {
            if dragZone == .ring {
                dragging = false
                settle()
            }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if inButton(point) {
            controller?.toggleListening()
        } else if let index = slot(at: point), index < ring.count {
            controller?.pick(ring[index].id)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let cg = event.cgEvent, cg.getIntegerValueField(.eventSourceUserData) == Input.scrollTag {
            Log.write("own scroll came back to the dial; dropped")
            return
        }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        wheelX += event.scrollingDeltaX * scale
        wheelY += event.scrollingDeltaY * scale
        if abs(wheelX) >= 40 {
            controller?.turnRing(by: wheelX > 0 ? -1 : 1)
            wheelX = 0
        }
        if abs(wheelY) >= 10 {
            Input.scroll(lines: Int32((wheelY / 10).rounded()))
            wheelY = 0
        }
        if event.phase == .ended || event.momentumPhase == .ended {
            wheelX = 0
            wheelY = 0
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let surface = dark ? NSColor(white: 0.14, alpha: 0.94) : NSColor(white: 0.97, alpha: 0.94)
        let edge = dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)
        let accent = NSColor.controlAccentColor

        // The ring.
        let outer = NSBezierPath(ovalIn: NSRect(x: center.x - Self.outerRadius, y: center.y - Self.outerRadius,
                                                width: Self.outerRadius * 2, height: Self.outerRadius * 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.5 : 0.25)
        shadow.set()
        surface.setFill()
        outer.fill()
        NSGraphicsContext.restoreGraphicsState()
        // The pointer over the ring lights the rim, in a lighter accent
        // than the active app's segment.
        (hover == .ring ? accent.withAlphaComponent(0.5) : edge).setStroke()
        outer.lineWidth = hover == .ring ? 2 : 1
        outer.stroke()

        // The slots; the active app's icon is a fifth larger than the rest.
        let count = min(ring.count, Self.maxSlots)
        for index in 0..<count {
            let app = ring[index]
            let at = slotCenter(index, of: count)
            let size: CGFloat = app.id == activeID ? 36 : 30
            let rect = NSRect(x: at.x - size / 2, y: at.y - size / 2, width: size, height: size)
            if let icon = app.icon {
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let initial = String(app.name.prefix(1)).uppercased()
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                            .foregroundColor: NSColor.labelColor]
                let s = NSAttributedString(string: initial, attributes: attrs)
                let sz = s.size()
                s.draw(at: NSPoint(x: at.x - sz.width / 2, y: at.y - sz.height / 2))
            }
        }
        if count == 0 {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10),
                                                        .foregroundColor: NSColor.tertiaryLabelColor]
            let s = NSAttributedString(string: "← apps →", attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y + Self.innerRadius + 10))
        }

        // The pulse while listening or thinking.
        if phase != .idle {
            let grow = 4 + 4 * (1 + sin(pulsePhase)) / 2
            let glow = NSBezierPath(ovalIn: NSRect(x: center.x - Self.buttonRadius - grow, y: center.y - Self.buttonRadius - grow,
                                                   width: (Self.buttonRadius + grow) * 2, height: (Self.buttonRadius + grow) * 2))
            (phase == .listening ? NSColor.systemRed : NSColor.systemBlue).withAlphaComponent(0.25).setFill()
            glow.fill()
        }

        // The button.
        let button = NSBezierPath(ovalIn: NSRect(x: center.x - Self.buttonRadius, y: center.y - Self.buttonRadius,
                                                 width: Self.buttonRadius * 2, height: Self.buttonRadius * 2))
        let fill: NSColor
        switch phase {
        case .idle: fill = dark ? NSColor(white: 0.24, alpha: 1) : NSColor.white
        case .listening: fill = .systemRed
        case .thinking: fill = .systemBlue
        }
        fill.setFill()
        button.fill()
        // The pointer over the button lights its edge.
        (hover == .button ? accent : edge).setStroke()
        button.lineWidth = hover == .button ? 2 : 1
        button.stroke()
        let symbol = phase == .thinking ? "ellipsis" : "mic.fill"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .medium)) {
            let tinted = image.tinted(phase == .idle ? NSColor.labelColor : .white)
            let sz = NSSize(width: 28, height: 28)
            tinted.draw(in: NSRect(x: center.x - sz.width / 2, y: center.y - sz.height / 2, width: sz.width, height: sz.height),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }

        // What was heard, or a hint, underneath.
        let text = hint ?? transcript
        guard !text.isEmpty else { return }
        let error = hint != nil && hintIsError
        let bubble = NSRect(x: 6, y: 6, width: bounds.width - 12, height: 40)
        let path = NSBezierPath(roundedRect: bubble, xRadius: 10, yRadius: 10)
        (error ? NSColor.systemRed.withAlphaComponent(dark ? 0.35 : 0.18) : surface).setFill()
        path.fill()
        edge.setStroke()
        path.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let s = NSAttributedString(string: text, attributes: attrs)
        let inset = bubble.insetBy(dx: 8, dy: 4)
        let needed = s.boundingRect(with: NSSize(width: inset.width, height: 1000), options: [.usesLineFragmentOrigin])
        let height = min(needed.height, inset.height)
        s.draw(with: NSRect(x: inset.minX, y: inset.midY - height / 2, width: inset.width, height: height),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

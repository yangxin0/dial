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
        tellInputWhereWeAre()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            self?.savePosition()
            self?.tellInputWhereWeAre()
        }
    }

    /// The frame in screen coordinates with the origin at the top left,
    /// for scrolls to steer clear of.
    private func tellInputWhereWeAre() {
        let height = NSScreen.screens.first?.frame.height ?? 0
        Input.dialFrame = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
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
    /// A drag that began on the ring turns it, and the turn scrolls the
    /// app in front; one that began on the button moves the dial.
    private var dragZone = HoverZone.none
    private var lastAngle: CGFloat = 0
    private var turn: CGFloat = 0
    /// Radians of turn per scroll step.
    private static let turnStep = CGFloat.pi / 12
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
        if isOurs(event) || Input.sessionActive { return }
        armed = true
        lastPointer = screenPoint(event)
        noteHome(event)
        hover = zone(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        // While a scroll session hides the cursor, its hops are not the
        // pointer leaving.
        if isOurs(event) || Input.sessionActive { return }
        armed = false
        hover = .none
        // Input.home is kept: a drag that runs off the dial still scrolls,
        // and its own events keep the spot fresh.
    }

    private var lastPointer: CGPoint?

    /// The event's place on screen, origin at the top left.
    private func screenPoint(_ event: NSEvent) -> CGPoint? {
        guard let window else { return nil }
        let p = window.convertPoint(toScreen: event.locationInWindow)
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: height - p.y)
    }

    /// The dial's own synthetic events, and the system's reaction to a
    /// scroll's hop: an event at the scroll's target, or one that jumped
    /// far from where the pointer was a moment ago. The system delivers a
    /// drag at the hop's position during a ring drag, and it carries no
    /// tag, so geometry is what tells it apart.
    private func isOurs(_ event: NSEvent) -> Bool {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Input.scrollTag { return true }
        guard let p = screenPoint(event) else { return false }
        if let t = Input.lastTarget, hypot(p.x - t.x, p.y - t.y) < 6 { return true }
        if let last = lastPointer, hypot(p.x - last.x, p.y - last.y) > 160 { return true }
        return false
    }

    /// Remembers where the pointer is over the dial, for the cursor to
    /// come back to after a scroll.
    private func noteHome(_ event: NSEvent) {
        guard !isOurs(event), let p = screenPoint(event) else { return }
        Input.home = p
        lastPointer = p
    }

    override func mouseMoved(with event: NSEvent) {
        if isOurs(event) || Input.sessionActive { return }
        noteHome(event)
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

    /// A drag let go: the ring springs back home, the active app at the
    /// top.
    private func settle() {
        Log.write("ring let go")
        retarget()
    }

    private func inButton(_ point: NSPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= Self.buttonRadius
    }

    // MARK: - Mouse

    /// Where the pointer is during a drag, in screen coordinates with the
    /// origin at the top left, followed by the mouse's own deltas: a
    /// scroll hops the cursor away and event positions lie meanwhile.
    private var virtualPointer: CGPoint?
    private var dragStart: CGPoint?

    /// The dial's centre on screen, origin at the top left.
    private var centerOnScreen: CGPoint? {
        guard let window else { return nil }
        let p = window.convertPoint(toScreen: convert(center, to: nil))
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: height - p.y)
    }

    /// The angle of a screen point about the dial's centre, counterclockwise
    /// from the right, as on the view.
    private func angleOnScreen(_ p: CGPoint) -> CGFloat {
        guard let c = centerOnScreen else { return 0 }
        return atan2(c.y - p.y, p.x - c.x)
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = screenPoint(event) else { return }
        lastPointer = p
        virtualPointer = p
        dragStart = p
        Input.home = p
        mouseDownAt = event.locationInWindow
        dragging = false
        dragZone = zone(at: convert(event.locationInWindow, from: nil))
        lastAngle = angleOnScreen(p)
        turn = 0
        if dragZone == .ring {
            spinTimer?.invalidate()
            spinTimer = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isOurs(event) { return }
        guard mouseDownAt != nil, var v = virtualPointer, let start = dragStart else { return }
        // Physical motion only: a hop is a jump in position, never a delta
        // this large.
        let dx = event.deltaX, dy = event.deltaY
        if abs(dx) > 120 || abs(dy) > 120 { return }
        v.x += dx
        v.y += dy
        virtualPointer = v
        Input.home = v
        if !dragging {
            guard hypot(v.x - start.x, v.y - start.y) > 4 else { return }
            dragging = true
            Log.write("drag began in \(dragZone)")
            if dragZone != .ring {
                window?.performDrag(with: event)
                return
            }
            Input.holdScrollSession = true
        }
        guard dragZone == .ring else { return }
        // The ring follows the pointer round, and every 15° of turn scrolls
        // the app in front: clockwise down, as a wheel rolled forward does.
        let now = angleOnScreen(v)
        var delta = now - lastAngle
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        lastAngle = now
        rotation += delta
        turn += delta
        while turn >= Self.turnStep {
            turn -= Self.turnStep
            Input.scroll(lines: 3)
        }
        while turn <= -Self.turnStep {
            turn += Self.turnStep
            Input.scroll(lines: -3)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownAt = nil
            virtualPointer = nil
            dragStart = nil
        }
        if dragging {
            if dragZone == .ring {
                dragging = false
                Input.holdScrollSession = false
                Input.endScrollSession()
                if let v = virtualPointer { lastPointer = v }
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
        if isOurs(event) {
            Log.write("own scroll came back to the dial; dropped")
            return
        }
        if !Input.sessionActive { noteHome(event) }
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

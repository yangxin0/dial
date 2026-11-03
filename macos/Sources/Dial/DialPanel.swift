import AppKit
import DialKit

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
            self?.windowMoved()
        }
    }

    /// Where the person put the ring's centre. A big dial near an edge is pushed
    /// back on screen, and this is where it returns to when it shrinks again.
    private var anchor = NSPoint.zero
    private var theme = DialTheme()
    /// The frame `apply` chose, so that move isn't taken for the person's.
    private var appliedFrame = NSRect.zero

    /// Changes the size and transparency. The view keeps its own coordinates
    /// and only its bounds scale, so its drawing and its events need no change.
    func apply(_ theme: DialTheme) {
        self.theme = theme
        view.ringStyle = theme.ringStyle
        layOut()
        alphaValue = theme.alpha
    }

    private func layOut() {
        let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(origin: .zero, size: frame.size)
        appliedFrame = theme.frame(ringCenter: anchor, within: visible)
        setFrame(appliedFrame, display: false)
        view.setBoundsSize(NSSize(width: DialMetrics.width, height: DialMetrics.height))
        view.needsDisplay = true
    }

    private func windowMoved() {
        guard frame != appliedFrame else { return }
        anchor = DialTheme.ringCenter(ofFrame: frame)
        appliedFrame = frame
        savePosition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        orderFrontRegardless()
    }

    private func restorePosition() {
        let defaults = UserDefaults.standard
        func onScreen(_ point: NSPoint) -> Bool {
            NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(point) }
        }
        if let x = defaults.object(forKey: "dial.cx") as? Double, let y = defaults.object(forKey: "dial.cy") as? Double,
           onScreen(NSPoint(x: x, y: y)) {
            anchor = NSPoint(x: x, y: y)
        } else if let x = defaults.object(forKey: "dial.x") as? Double, let y = defaults.object(forKey: "dial.y") as? Double,
                  onScreen(NSPoint(x: x, y: y)) {
            // Saved by an earlier version, as the normal-sized window's corner.
            anchor = DialTheme.ringCenter(ofFrame: NSRect(x: x, y: y, width: DialMetrics.width, height: DialMetrics.height))
        } else if let visible = NSScreen.main?.visibleFrame {
            anchor = DialTheme.ringCenter(ofFrame: NSRect(x: visible.maxX - DialMetrics.width - 24, y: visible.minY + 24,
                                                          width: DialMetrics.width, height: DialMetrics.height))
        }
        layOut()
    }

    private func savePosition() {
        UserDefaults.standard.set(Double(anchor.x), forKey: "dial.cx")
        UserDefaults.standard.set(Double(anchor.y), forKey: "dial.cy")
    }
}

/// The dial itself: an app ring around a microphone button, with what
/// was heard underneath.
final class DialView: NSView {
    static let width = DialMetrics.width
    static let height = DialMetrics.height
    static let outerRadius = DialMetrics.outerRadius
    static let innerRadius = DialMetrics.innerRadius
    static let buttonRadius = DialMetrics.buttonRadius
    static let maxSlots = DialMetrics.maxSlots

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
    /// eases to put the active app at the top.
    private var rotation: CGFloat = 0
    private var rotationTarget: CGFloat = 0
    private var spinTimer: Timer?
    /// What the ring shows as a drag turns it.
    var ringStyle = RingStyle.ticksAndDimple { didSet { needsDisplay = true } }
    /// How far the marks have gone round. They stay where a drag leaves them,
    /// as a wheel does; the icons keep their own places.
    private var marksTurn: CGFloat = 0
    private var trail = RingTrail()
    private var trailTimer: Timer?
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
    private(set) var hover = DialZone.none {
        didSet { if hover != oldValue { needsDisplay = true } }
    }

    private var pulseTimer: Timer?
    private var pulsePhase: CGFloat = 0
    private var mouseDownAt: NSPoint?
    private var dragging = false
    /// A drag that began on the ring scrolls the app in front, with the icons
    /// hidden; one that began on the button moves the dial.
    private var dragZone = DialZone.none
    private var ringDragged: Bool { dragging && dragZone == .ring }
    private var turn = TurnCounter(startAngle: 0)
    private var wheelX: CGFloat = 0
    private var wheelY: CGFloat = 0

    private var center: NSPoint { NSPoint(x: bounds.midX, y: Self.height - DialMetrics.topMargin - Self.outerRadius) }
    private var geometry: RingGeometry { RingGeometry(center: center) }

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
        hover = geometry.zone(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        armed = false
        hover = .none
    }

    override func mouseMoved(with event: NSEvent) {
        hover = geometry.zone(at: convert(event.locationInWindow, from: nil))
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

    /// Aims the turn so the active app sits at the top, the short way
    /// round, and eases there unless a drag has the ring.
    private func retarget() {
        guard let active = activeID, let index = ring.firstIndex(where: { $0.id == active }), index < slotCount else { return }
        rotationTarget = RingGeometry.rotation(puttingSlot: index, of: slotCount, atTopNear: rotation)
        if !ringDragged { spin() }
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

    /// A drag let go: the icons come back where they were.
    private func settle() {
        Log.write("ring let go")
        trail.clear()
        trailTimer?.invalidate()
        trailTimer = nil
        needsDisplay = true
        retarget()
    }

    /// Keeps drawing while the trail fades, as it does when the pointer pauses.
    private func keepTrailFading() {
        guard trailTimer == nil else { return }
        trailTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] timer in
            guard let self else { return }
            self.trail.prune(now: ProcessInfo.processInfo.systemUptime)
            self.needsDisplay = true
            if self.trail.isEmpty {
                timer.invalidate()
                self.trailTimer = nil
            }
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        dragging = false
        let point = convert(event.locationInWindow, from: nil)
        dragZone = geometry.zone(at: point)
        turn = TurnCounter(startAngle: geometry.angle(of: point))
        if dragZone == .ring {
            spinTimer?.invalidate()
            spinTimer = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt else { return }
        if !dragging {
            guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > DialMetrics.clickSlop else { return }
            dragging = true
            if dragZone != .ring {
                window?.performDrag(with: event)
                return
            }
            needsDisplay = true  // The icons hide.
        }
        guard dragZone == .ring else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard geometry.hasMeaningfulAngle(at: point) else { return }
        // Going round scrolls the app in front: clockwise down, as a wheel
        // rolled forward does. The marks go round with the pointer.
        let angle = geometry.angle(of: point)
        let (delta, lines) = turn.move(to: angle)
        marksTurn += delta
        if ringStyle.hasTrail {
            trail.add(angle: angle, at: ProcessInfo.processInfo.systemUptime)
            keepTrailFading()
        }
        for _ in 0..<abs(lines) {
            Input.scroll(lines: lines > 0 ? 1 : -1)
        }
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
        // A click: it means what was pressed, wherever a shaky hand let go.
        guard let start = mouseDownAt else { return }
        let point = convert(start, from: nil)
        if dragZone == .button {
            controller?.toggleListening()
        } else if let index = geometry.icon(at: point, count: slotCount, rotation: rotation), index < ring.count {
            controller?.pick(ring[index].id)
        } else if dragZone == .ring {
            // The press stopped the ring where it was: let it finish easing.
            retarget()
        }
    }

    override func scrollWheel(with event: NSEvent) {
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

    /// The app icon's dimple.
    private static let dimpleTop = NSColor(srgbRed: 0xF2 / 255.0, green: 0x54 / 255.0, blue: 0x1A / 255.0, alpha: 1)
    private static let dimpleBottom = NSColor(srgbRed: 0xFF / 255.0, green: 0x8A / 255.0, blue: 0x4D / 255.0, alpha: 1)

    /// How the ring shows it's turning, only during a drag: at rest it has its
    /// icons, and marks beside them are clutter.
    private func drawMarks(ink: NSColor) {
        guard ringDragged else { return }
        func stroke(_ mark: RingMark, _ color: NSColor, width: CGFloat) {
            let path = NSBezierPath()
            path.move(to: mark.from)
            path.line(to: mark.to)
            path.lineWidth = width
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        }
        if ringStyle.hasTicks {
            for mark in geometry.ticks(turn: marksTurn) {
                stroke(mark, ink.withAlphaComponent(mark.major ? 0.7 : 0.4), width: mark.major ? 1.6 : 1)
            }
        }
        if ringStyle.hasSpokes {
            for mark in geometry.spokes(turn: marksTurn) {
                stroke(mark, ink.withAlphaComponent(0.28), width: 3)
            }
        }
        if ringStyle.hasDimple {
            let at = geometry.dimple(turn: marksTurn), radius = RingMarks.dimpleRadius
            let path = NSBezierPath(ovalIn: NSRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2))
            NSGradient(starting: Self.dimpleTop, ending: Self.dimpleBottom)?.draw(in: path, angle: -90)
        }
        if ringStyle.hasTrail {
            for piece in trail.segments(now: ProcessInfo.processInfo.systemUptime) {
                let mark = RingMark(from: geometry.trailPoint(angle: piece.from), to: geometry.trailPoint(angle: piece.to), major: false)
                stroke(mark, Self.dimpleTop.withAlphaComponent(piece.alpha * 0.8), width: RingMarks.trailWidth)
            }
        }
    }

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

        drawMarks(ink: dark ? .white : .black)

        // The slots; the active app's icon is a fifth larger than the rest.
        let count = min(ring.count, Self.maxSlots)
        for index in 0..<count where !ringDragged {
            let app = ring[index]
            let at = geometry.slotCenter(index, of: count, rotation: rotation)
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

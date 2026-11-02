import AppKit

/// The menu bar icon: the app icon's knob, as a disc with a dimple cut out. A
/// template image, so macOS colours it for the menu bar. Drawn here rather
/// than kept as a picture, so it stays sharp at every scale.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let shape = NSBezierPath(ovalIn: NSRect(x: 1.3, y: 1.3, width: 15.4, height: 15.4))
            // The dimple sits up and to the right, 40 degrees round from the top.
            let angle = 40 * CGFloat.pi / 180
            let hole = NSPoint(x: 9 + 3.9 * sin(angle), y: 9 - 3.9 * cos(angle))
            shape.append(NSBezierPath(ovalIn: NSRect(x: hole.x - 2.2, y: hole.y - 2.2, width: 4.4, height: 4.4)))
            shape.windingRule = .evenOdd
            NSColor.black.setFill()
            shape.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Dial"
        return image
    }
}

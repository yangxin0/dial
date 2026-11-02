import AppKit

/// The dial: a small floating window that listens when clicked, turns an
/// app ring with the arrow keys, and scrolls the app in front. The speech
/// engine, the decision and the learned ring live in dial-core, which this
/// app starts and talks to over the loopback interface.
@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DialController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = DialController()
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

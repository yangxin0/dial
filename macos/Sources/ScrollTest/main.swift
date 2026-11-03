// make test-scroll: drags the real ring of the running dial over real apps,
// and checks what happened: the app scrolled the right way, the pointer
// stayed on the drag's path, and the app stayed in front. Then it clicks the
// ring's icons, and each app must come up showing a window. It takes over the
// pointer for a couple of minutes. Don't touch the mouse while it runs.
//
//   ScrollTest                     every target
//   ScrollTest --only chrome,native
//   SCROLLTEST_SABOTAGE=front|button|old  breaks the run on purpose, to show
//                                  the validity checks and the old-method
//                                  comparison fire. See CLAUDE.md.
//
// Exit: 0 passed, 1 a check failed, 2 the run itself was invalid and proved nothing.
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "fixture-native": runNativeFixture(path: arguments[1])
case "fixture-webkit": runWebKitFixture(path: arguments[1])
case "report": runWheelReporter(path: arguments[1])
default:
    var only: Set<String>?
    if let i = arguments.firstIndex(of: "--only"), i + 1 < arguments.count {
        only = Set(arguments[i + 1].split(separator: ",").map(String.init))
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.global().async { exit(Runner(only: only).run()) }
    app.run()
}

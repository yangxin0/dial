import AppKit

/// An app the ring can show or the voice can name.
struct AppInfo {
    var id: String
    var name: String
    var running: Bool
    var active: Bool
    var icon: NSImage?
    var url: URL?
}

/// The apps: the running ones, most recently used first, and the installed
/// ones for opening by name. Switches and opens them.
final class AppWatcher {
    var onChange: (() -> Void)?

    private(set) var running: [AppInfo] = []
    private(set) var installed: [AppInfo] = []
    /// Bundle ids in most-recently-activated order.
    private var recent: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var pendingChange: DispatchWorkItem?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == NSWorkspace.didActivateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let id = app.bundleIdentifier {
                    self?.recent.removeAll { $0 == id }
                    self?.recent.insert(id, at: 0)
                }
                self?.refresh()
            })
        }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            recent = [front]
        }
        refresh()
        scanInstalled()
    }

    func stop() {
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers = []
    }

    /// Every app, running ones first (they are the ring and the likeliest
    /// targets), then the installed ones by name.
    var all: [AppInfo] { running + installed }

    func app(id: String) -> AppInfo? {
        all.first { $0.id == id }
    }

    private func refresh() {
        let front = NSWorkspace.shared.frontmostApplication
        var list: [AppInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            let name = app.localizedName ?? id
            list.append(AppInfo(id: id, name: name, running: true, active: app == front, icon: app.icon, url: app.bundleURL))
        }
        let order = recent
        list.sort { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        running = list
        let runningIDs = Set(list.map(\.id))
        installed.removeAll { runningIDs.contains($0.id) }
        scheduleChange()
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// The .app bundles in the usual folders, one level deep, on a
    /// background queue: names to open by voice.
    private func scanInstalled() {
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       NSHomeDirectory() + "/Applications"]
        DispatchQueue.global(qos: .utility).async {
            var found: [AppInfo] = []
            var seen = Set<String>()
            let fm = FileManager.default
            for folder in folders {
                guard let items = try? fm.contentsOfDirectory(atPath: folder) else { continue }
                for item in items where item.hasSuffix(".app") {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                    let id = Bundle(url: url)?.bundleIdentifier ?? url.path
                    guard !seen.contains(id) else { continue }
                    seen.insert(id)
                    var name = fm.displayName(atPath: url.path)
                    if name.hasSuffix(".app") { name.removeLast(4) }
                    found.append(AppInfo(id: id, name: name, running: false, active: false, icon: nil, url: url))
                }
            }
            found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if found.count > 200 { found = Array(found.prefix(200)) }
            DispatchQueue.main.async {
                let runningIDs = Set(self.running.map(\.id))
                self.installed = found.filter { !runningIDs.contains($0.id) }
                self.scheduleChange()
            }
        }
    }

    /// Brings the app to the front; opens it when it is not running.
    func activate(id: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id }) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        open(id: id)
    }

    func open(id: String) {
        var url = app(id: id)?.url
        if url == nil {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }
        if url == nil, id.hasPrefix("/") {
            url = URL(fileURLWithPath: id)
        }
        guard let url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The records the core gets.
    var records: [AppRecord] {
        all.map { AppRecord(id: $0.id, name: $0.name, running: $0.running, active: $0.active ? true : nil) }
    }
}

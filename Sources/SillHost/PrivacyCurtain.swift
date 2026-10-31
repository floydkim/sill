import AppKit

/// Physical-screen cover. Sill's windows are excluded by the Desktop capture filter.
@MainActor
final class PrivacyCurtain: NSObject {
    private let excludedDisplay: () -> CGDirectDisplayID?
    private let report: (String?) -> Void
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var enabled = false
    private var devicesPresent = false
    private var revealedLocally = false
    private var exiting = false
    private(set) var needsLock = false
    private var locking: Task<Void, Never>?
    private var globalKeys: Any?
    private var localKeys: Any?
    var isCovering: Bool { !windows.isEmpty }
    private var wanted: Bool { enabled && devicesPresent && !revealedLocally }

    init(excludedDisplay: @escaping () -> CGDirectDisplayID?, report: @escaping (String?) -> Void) {
        self.excludedDisplay = excludedDisplay
        self.report = report
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                             name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // shortcut: this distributed notification is undocumented; verify each supported macOS.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(refresh),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(locked),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isRevealShortcut(event) { Task { @MainActor in self?.revealLocally() } }
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isRevealShortcut(event), self?.isCovering == true { self?.revealLocally(); return nil }
            return event
        }
    }

    private static func isRevealShortcut(_ event: NSEvent) -> Bool {
        event.keyCode == 11 && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function]) == [.control, .option, .command]
    }

    private func revealLocally() {
        guard isCovering, !exiting else { return }
        revealedLocally = true
        locking?.cancel()
        locking = nil
        remove()
        print("Privacy cover: revealed by shortcut for this connection session.")
    }

    func update(enabled: Bool, devicesPresent: Bool) {
        guard !exiting else { return }
        if !self.devicesPresent && devicesPresent { revealedLocally = false }
        self.enabled = enabled
        self.devicesPresent = devicesPresent
        if enabled && devicesPresent {
            needsLock = true
            locking?.cancel()
            locking = nil
            report(nil)
            if !revealedLocally { refresh() }
        } else if needsLock, locking == nil {
            locking = Task { [weak self] in
                guard let self else { return }
                let locked = await SessionLock.shared.lockAndConfirm()
                guard !Task.isCancelled else { return }
                self.locking = nil
                guard !self.enabled || !self.devicesPresent else { return }
                if locked {
                    self.needsLock = false
                    self.remove()
                    print("Privacy cover: Mac locked; cover removed.")
                } else {
                    self.failedToLock()
                }
            }
        }
    }

    /// Normal quit/signal must finish this before the process and its windows disappear.
    func prepareForExit() async -> Bool {
        guard needsLock else { return true }
        exiting = true
        locking?.cancel()
        locking = nil
        if await SessionLock.shared.lockAndConfirm() {
            needsLock = false
            remove()
            return true
        }
        exiting = false
        failedToLock()
        return false
    }

    private func failedToLock() {
        let message = "Could not confirm this Mac is locked. The screen cover remains. Lock the Mac manually, then retry, or use Control–Option–Command–B to reveal locally."
        report(message)
        print("Privacy cover: " + message)
    }

    @objc private func locked() {
        guard needsLock, !enabled || !devicesPresent else { return }
        update(enabled: enabled, devicesPresent: devicesPresent)
    }

    @objc private func refresh() {
        guard wanted || isCovering else { return }
        var visible = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            guard id != excludedDisplay() else { continue }
            visible.insert(id)
            let window: NSWindow
            if let existing = windows[id] {
                window = existing
            } else {
                window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.title = "Sill privacy cover"
                window.isReleasedWhenClosed = false
                window.backgroundColor = .black
                window.isOpaque = true
                window.hasShadow = false
                window.ignoresMouseEvents = true
                window.canHide = false
                window.hidesOnDeactivate = false
                window.level = .screenSaver
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                windows[id] = window
            }
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
        }
        for id in Array(windows.keys) where !visible.contains(id) {
            windows.removeValue(forKey: id)?.close()
        }
    }

    private func remove() {
        for window in windows.values { window.close() }
        windows.removeAll()
        report(nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        if let globalKeys { NSEvent.removeMonitor(globalKeys) }
        if let localKeys { NSEvent.removeMonitor(localKeys) }
    }
}

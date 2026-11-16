import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let library = Library()
    private lazy var displays = DisplayManager(library: library)
    private lazy var mouse = MouseForwarder(displays: displays)
    private var menu: MenuController?
    private var syncTimer: Timer?
    private var lockHotkey: GlobalHotkey?
    private var observers: [NSObjectProtocol] = []
    /// Gründe, aus denen gerade niemand das Wallpaper sehen kann.
    private var asleep = false
    private var locked = false
    private var sessionInactive = false
    private var saverRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ein zweiter Start würde zwei Fenster übereinanderlegen
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        library.reloadFromDisk()
        library.onChange = { [weak self] in self?.libraryChanged() }
        menu = MenuController(library: library, displays: displays, mouse: mouse)
        libraryChanged()
        mouse.setEnabled(Settings.mouseEnabled)
        displays.media.setEnabled(Settings.mediaEnabled)
        SaverInstaller.updateIfNeeded()
        // ⌃⌥⌘L: Bildschirmschoner starten, also „sperren und das Wallpaper läuft weiter“
        lockHotkey = GlobalHotkey(keyCode: GlobalHotkey.lockKeyCode, modifiers: GlobalHotkey.lockModifiers) {
            SaverInstaller.start()
        }
        observeSystem()
        observers.append(Diagnostics.serve(displays))

        // Beim Start und danach alle sechs Stunden nach neuen oder geänderten Wallpapern sehen
        Task { await library.sync() }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.library.sync() }
        }
    }

    private func libraryChanged() {
        // Erster Start: das oberste Wallpaper der Seite auf alle Monitore
        if Settings.defaultWallpaper == nil, let first = library.wallpapers.first {
            Settings.defaultWallpaper = first.id
        }
        displays.refresh()
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func on(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (AppDelegate) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                }
            })
        }

        // Monitor an- oder abgesteckt, Auflösung oder Anordnung geändert
        on(center, NSApplication.didChangeScreenParametersNotification) { $0.displays.refresh() }

        // macOS merkt sich das Hintergrundbild je Space
        on(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.displays.lockScreen.spaceChanged() }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.asleep = true; $0.updateSystemPause() }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.asleep = false; $0.updateSystemPause(); $0.displays.refresh() }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true; $0.updateSystemPause() }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false; $0.updateSystemPause() }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
            updateSystemPause()
        }
        // Läuft der Bildschirmschoner, zeichnet er die Wallpaper selbst: die eigenen Fenster dahinter ruhen so lange
        on(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.saverRunning = true; $0.updateSystemPause() }
        on(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.saverRunning = false; $0.updateSystemPause() }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true; $0.updateSystemPause(); $0.startSaverAfterLock() }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false; $0.updateSystemPause() }
    }

    /// Nach einer normalen Sperre (ctrl + cmd + Q, Touch-ID-Taste) zeigt macOS seinen Sperrbildschirm. Ein danach
    /// gestarteter Bildschirmschoner legt sich darüber, bis jemand Maus oder Tastatur anfasst: das Wallpaper läuft
    /// also auch dann weiter. Nicht, wenn die Monitore schlafen oder der Mac gerade erst aufwacht.
    private func startSaverAfterLock() {
        guard Settings.saverOnLock, SaverInstaller.isInstalled else { return }
        let lockedAt = Date()
        // Kurz warten, bis die Tasten der Sperre losgelassen sind; sie würden den Bildschirmschoner gleich beenden
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.locked, !self.asleep, !self.sessionInactive,
                  // Hat der Mac dazwischen geschlafen, kommt dieser Aufruf erst beim Aufwachen: dann nicht nachholen
                  Date().timeIntervalSince(lockedAt) < 4,
                  CGDisplayIsAsleep(CGMainDisplayID()) == 0,
                  !SaverInstaller.isRunning else { return }
            SaverInstaller.start(after: 0)
        }
    }

    private func updateSystemPause() {
        displays.systemPaused = asleep || locked || sessionInactive || saverRunning
    }
}

import AppKit
import Carbon.HIToolbox
import OSLog

/// Nachzulesen mit: /usr/bin/log show --last 5m --predicate 'subsystem == "cc.reez.wallpapers"'
let appLog = Logger(subsystem: "cc.reez.wallpapers", category: "app")

/// Richtet den Bildschirmschoner ein, der in der App liegt, und startet ihn.
///
/// Über dem Sperrbildschirm zeigt macOS nichts Fremdes. Ein Bildschirmschoner läuft aber auch bei gesperrtem Mac,
/// bis jemand Maus oder Tastatur anfasst; erst dann kommt die Passwortabfrage. „Sperren“ startet ihn sofort. Ob
/// macOS dabei gleich sperrt, legt die Systemeinstellung „Passwort erforderlich nach Beginn des Bildschirmschoners“ fest.
enum SaverInstaller {
    private static let name = "ReeZ Wallpapers.saver"

    /// Fassung, die mit der App ausgeliefert wird.
    private static var embedded: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(name)
    }

    static var installed: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/\(name)")
    }

    static var isAvailable: Bool {
        embedded.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installed.path)
    }

    private static func binary(_ bundle: URL) -> Data? {
        try? Data(contentsOf: bundle.appendingPathComponent("Contents/MacOS/ReeZWallpapersSaver"))
    }

    /// Kopiert den Bildschirmschoner nach ~/Library/Screen Savers (ersetzt eine ältere Fassung).
    static func install() throws {
        guard let embedded, isAvailable else {
            throw NSError(domain: "ReeZWallpapers", code: 3, userInfo: [
                NSLocalizedDescriptionKey: L("This copy of the app has no screen saver inside.", "In dieser Fassung der App liegt kein Bildschirmschoner.")
            ])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: installed.path) { try fm.removeItem(at: installed) }
        try fm.copyItem(at: embedded, to: installed)
        // Ein noch laufender Wirtsprozess (z. B. von der Vorschau in den Systemeinstellungen) hielte die alte Fassung
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        stop.arguments = ["-f", "legacyScreenSaver.appex"]
        try? stop.run()
    }

    /// Nach einem Update der App den eingerichteten Bildschirmschoner nachziehen.
    static func updateIfNeeded() {
        guard isInstalled, let embedded, isAvailable, binary(embedded) != binary(installed) else { return }
        try? install()
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Läuft der Bildschirmschoner von macOS gerade?
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").isEmpty
    }

    /// Startet den in macOS gewählten Bildschirmschoner.
    /// - Parameter delay: Kurz warten: das Loslassen der Tasten des Kürzels würde ihn sonst gleich wieder beenden.
    static func start(after delay: TimeInterval = 0.5) {
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSWorkspace.shared.openApplication(at: engine, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Die Sperre von macOS selbst.
enum SystemLock {
    private typealias LockFunction = @convention(c) () -> Int32

    private static let lockFunction: LockFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    static var isAvailable: Bool { lockFunction != nil }

    /// Sperrt sofort, wie ctrl + cmd + Q. (Interne Funktion von macOS; nur als Rückfall für die übernommene Sperrtaste.)
    static func lockNow() {
        _ = lockFunction?()
    }

    private static var cached: (value: Bool, at: Date)?

    /// Sperrt macOS gleich mit dem Start des Bildschirmschoners? Das ist die Systemeinstellung „Passwort erforderlich
    /// nach Beginn des Bildschirmschoners oder Ausschalten des Displays: Sofort“.
    static func locksWithScreenSaver(maxAge: TimeInterval = 0) -> Bool {
        if let cached, Date().timeIntervalSince(cached.at) < maxAge { return cached.value }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        process.arguments = ["-screenLock", "status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var value = false
        if (try? process.run()) != nil {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            value = output.contains("delay is immediate")
        }
        cached = (value, Date())
        return value
    }
}

/// Die Tastenkürzel zum Sperren mit weiterlaufendem Wallpaper.
@MainActor
final class LockShortcuts {
    static let shared = LockShortcuts()
    private var own: GlobalHotkey?
    private var system: GlobalHotkey?

    /// Stellt die Kürzel so ein, wie die Einstellungen es sagen.
    func apply() {
        if own == nil {
            // ⌃⌥⌘L
            own = GlobalHotkey(id: 1, keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey | cmdKey)) {
                appLog.notice("Sperren über ctrl+alt+cmd+L")
                SaverInstaller.start()
            }
        }
        // ⌃⌘Q ist das Sperr-Kürzel von macOS (auch die Sperrtaste mancher Tastaturen schickt es). Ein eigenes Kürzel
        // darauf hat Vorrang. Nur übernehmen, wenn sich im Zweifel auch echt sperren lässt.
        if Settings.takeOverSystemLockShortcut, SystemLock.isAvailable {
            if system == nil {
                system = GlobalHotkey(id: 2, keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | cmdKey)) {
                    // Eine Sperrtaste muss immer sperren: ohne „Passwort sofort“ oder ohne Bildschirmschoner die echte Sperre
                    if SaverInstaller.isInstalled, SystemLock.locksWithScreenSaver() {
                        appLog.notice("Sperren über ctrl+cmd+Q: Bildschirmschoner")
                        SaverInstaller.start()
                    } else {
                        appLog.notice("Sperren über ctrl+cmd+Q: Sperre von macOS")
                        SystemLock.lockNow()
                    }
                }
                appLog.notice("ctrl+cmd+Q übernommen: \(self.system != nil, privacy: .public)")
            }
        } else {
            system = nil
        }
    }
}

/// Ein systemweites Tastenkürzel (Carbon-Hotkey: braucht keine Freigabe).
final class GlobalHotkey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32

    init?(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = id
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Jedes Kürzel hat seinen eigenen Handler: nur auf das eigene reagieren, die anderen weiterreichen
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.id == hotkey.id else { return OSStatus(eventNotHandledErr) }
            hotkey.action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5245_455A), id: id)
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey) == noErr else { return nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

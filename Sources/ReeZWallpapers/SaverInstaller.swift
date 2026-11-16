import AppKit
import Carbon.HIToolbox

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

    /// Startet den in macOS gewählten Bildschirmschoner.
    static func start() {
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        // Kurz warten: das Loslassen der Tasten des Kürzels würde ihn sonst gleich wieder beenden
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSWorkspace.shared.openApplication(at: engine, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Ein systemweites Tastenkürzel (Carbon-Hotkey: braucht keine Freigabe).
final class GlobalHotkey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// ⌃⌥⌘L
    static let lockKeyCode = UInt32(kVK_ANSI_L)
    static let lockModifiers = UInt32(controlKey | optionKey | cmdKey)

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            if let userData {
                Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x5245_455A), id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr else { return nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

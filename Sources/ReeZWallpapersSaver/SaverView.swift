import AppKit
import OSLog
import ScreenSaver

/// Nachzulesen mit: /usr/bin/log show --last 5m --predicate 'subsystem == "cc.reez.wallpapers.saver"'
private let saverLog = Logger(subsystem: "cc.reez.wallpapers.saver", category: "saver")

/// Der Bildschirmschoner: zeigt auf jedem Monitor das Wallpaper, das die App dort gerade zeigt.
///
/// macOS lädt dieses Bündel in seinen eigenen Prozess (legacyScreenSaver) und legt je Monitor eine Ansicht an.
/// Inhalt und Auswahl kommen aus saver.json der App; die Ansichten selbst sind dieselben wie in der App
/// (die Quelldateien sind in dieses Ziel verlinkt).
@objc(ReeZWallpapersSaverView)
final class SaverView: ScreenSaverView {
    private static let scheme = ProjectSchemeHandler()
    /// Display-UUID → Ansicht, die diesen Monitor für sich festgestellt hat (für gleich große Monitore).
    private static var claims: [String: ObjectIdentifier] = [:]
    private var content: WallpaperContent?
    private var stopObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// Monitor und Wallpaper, die diese Ansicht gerade zeigt.
    private var shownDisplay: String?
    private var shownWallpaper: Wallpaper?
    private var attempts = 0

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // Gezeichnet wird von den Wallpapern selbst, animateOneFrame bleibt leer
        animationTimeInterval = 1
        // macOS beendet den Prozess nach dem Bildschirmschoner nicht von selbst; ohne das liefen die Wallpaper
        // unsichtbar weiter
        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in
            saverLog.notice("beendet")
            self?.content?.removeFromSuperview()
            self?.content = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if screenObserver == nil {
            // Landet das Fenster später auf einem (anderen) Monitor, das Wallpaper nachziehen
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.resolve(final: false)
            }
        }
        guard shownDisplay == nil else { return }
        attempts = 0
        resolve(final: false)
    }

    // MARK: Welcher Monitor?

    private static func describe(_ rect: NSRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
    }

    /// Findet den Monitor, auf dem diese Ansicht liegt.
    ///
    /// macOS zeigt die Ansichten des Bildschirmschoners über einen eigenen Prozess an. Bei externen Monitoren ist
    /// `window.screen` dort leer (jeder bekam deshalb das Wallpaper „für alle“). Deshalb: erst die Angabe des
    /// Fensters, wenn sie zur Größe passt, dann die Lage des Fensters, und wenn nach einer Sekunde nichts davon
    /// greift, ein Monitor passender Größe, den noch keine andere Ansicht hat.
    private func resolve(final: Bool) {
        let size = bounds.size
        let fits: (NSScreen) -> Bool = { abs($0.frame.width - size.width) < 2 && abs($0.frame.height - size.height) < 2 }
        var found: NSScreen?
        var method = "–"
        if isPreview, size.width < 700 {
            // Kleine Vorschau in den Systemeinstellungen (nur dort; macOS meldet „Vorschau“ nicht immer richtig)
            found = NSScreen.main
            method = "Vorschau"
        } else if let screen = window?.screen, fits(screen) {
            found = screen
            method = "Fenster"
        } else if let frame = window?.frame, frame.width > 0 {
            // Im Bildschirmschoner-Prozess steht die Lage des Fensters in Quartz-Koordinaten (Ursprung oben links,
            // externe Monitore über dem Hauptbildschirm haben negatives y), nicht in denen von AppKit. Bei macOS 26
            // beobachtet: Fenster „1728,-895“ für den Monitor, den AppKit bei „1728,932“ führt.
            let area: (NSRect) -> CGFloat = { $0.isNull ? 0 : $0.width * $0.height }
            let quartz: (NSScreen) -> CGFloat = { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 0 }
                return area(CGDisplayBounds(number.uint32Value).intersection(frame))
            }
            let cocoa: (NSScreen) -> CGFloat = { area($0.frame.intersection(frame)) }
            let enough = size.width * size.height * 0.5
            let candidates = NSScreen.screens.filter(fits)
            if let best = candidates.max(by: { quartz($0) < quartz($1) }), quartz(best) > enough {
                found = best
                method = "Lage"
            } else if let best = candidates.max(by: { cocoa($0) < cocoa($1) }), cocoa(best) > enough {
                found = best
                method = "Lage (AppKit)"
            }
        }
        if found == nil, final {
            let candidates = NSScreen.screens.filter(fits)
            let free = candidates.first { screen in
                guard let uuid = screen.displayUUID else { return false }
                return Self.claims[uuid] == nil || Self.claims[uuid] == ObjectIdentifier(self)
            }
            if let screen = free ?? candidates.first {
                found = screen
                method = candidates.count == 1 ? "Größe" : "Reihenfolge"
            } else {
                // Kein Monitor dieser Größe: lieber irgendeines der Wallpaper als ein schwarzes Bild
                found = window?.screen ?? NSScreen.main
                method = "Notbehelf"
            }
        }

        let windowFrame = window.map { Self.describe($0.frame) } ?? "kein Fenster"
        let windowScreen = window?.screen.map { Self.describe($0.frame) } ?? "kein Monitor"
        let uuid = found?.displayUUID
        saverLog.notice("""
            Ansicht \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public) Versuch \(self.attempts, privacy: .public): \
            Fenster \(windowFrame, privacy: .public), dessen Monitor \(windowScreen, privacy: .public) → \
            \(method, privacy: .public) \(uuid?.prefix(8).description ?? "offen", privacy: .public)
            """)

        guard let uuid else {
            // Noch nichts Sicheres: kurz warten, das Fenster wird erst nach dem Anlegen platziert
            attempts += 1
            let last = attempts >= 10
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.shownDisplay == nil else { return }
                self.resolve(final: last)
            }
            return
        }
        guard uuid != shownDisplay else { return }
        Self.claims = Self.claims.filter { $0.value != ObjectIdentifier(self) }
        Self.claims[uuid] = ObjectIdentifier(self)
        shownDisplay = uuid
        load(display: uuid)
    }

    private func load(display uuid: String) {
        if attempts == 0, shownWallpaper == nil {
            let screens = NSScreen.screens.map { "\($0.displayUUID?.prefix(8).description ?? "?") \(Self.describe($0.frame))" }.joined(separator: " | ")
            saverLog.notice("Monitore: \(screens, privacy: .public)")
        }
        guard let config = SaverConfig.read() else {
            saverLog.error("saver.json nicht lesbar unter \(SaverConfig.supportDir.path, privacy: .public)")
            return showNote(L("Open ReeZ Wallpapers once and pick a wallpaper.", "Öffne einmal ReeZ Wallpapers und wähle ein Wallpaper."))
        }
        guard let wallpaper = config.wallpaper(forDisplay: uuid) else {
            // Auf diesem Monitor ist in der App „Aus“ gewählt: schwarz lassen
            saverLog.notice("kein Wallpaper für diesen Monitor")
            content?.removeFromSuperview()
            content = nil
            shownWallpaper = nil
            return
        }
        // Stellt sich der Monitor später als ein anderer heraus, aber mit demselben Wallpaper, bleibt alles stehen
        guard wallpaper != shownWallpaper else { return }
        content?.removeFromSuperview()
        content = nil
        shownWallpaper = wallpaper
        guard FileManager.default.isReadableFile(atPath: wallpaper.root.appendingPathComponent(wallpaper.entry).path) else {
            saverLog.error("Dateien nicht lesbar: \(wallpaper.root.path, privacy: .public)")
            return showNote(L("The wallpaper files can't be read from the screen saver.", "Der Bildschirmschoner kann die Dateien des Wallpapers nicht lesen."))
        }
        saverLog.notice("zeige \(wallpaper.id, privacy: .public)")
        let frame = NSRect(origin: .zero, size: bounds.size)
        let view: WallpaperContent
        switch wallpaper.kind {
        case .web:
            let overrides = config.overrides?[wallpaper.id]?.mapValues(\.any) ?? [:]
            view = WebWallpaperView(wallpaper: wallpaper, scheme: Self.scheme, fpsLimit: config.fps, frame: frame,
                                    ignoresOcclusion: true, overrides: { overrides }, mediaSnapshot: { [] })
        case .video:
            view = VideoWallpaperView(wallpaper: wallpaper, frame: frame)
        }
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        content = view
    }

    private func showNote(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: isPreview ? 10 : 18)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: bounds.midY - 20, width: bounds.width, height: 40)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(label)
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func animateOneFrame() {
        // Die Wallpaper zeichnen sich selbst.
    }
}

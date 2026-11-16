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
    private var content: WallpaperContent?
    private var stopObserver: NSObjectProtocol?

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
        guard window != nil, content == nil else { return }
        load()
    }

    private func load() {
        let size = "\(Int(bounds.width))x\(Int(bounds.height))"
        saverLog.notice("Ansicht \(size, privacy: .public), Vorschau \(self.isPreview, privacy: .public)")
        guard let config = SaverConfig.read() else {
            saverLog.error("saver.json nicht lesbar unter \(SaverConfig.supportDir.path, privacy: .public)")
            return showNote(L("Open ReeZ Wallpapers once and pick a wallpaper.", "Öffne einmal ReeZ Wallpapers und wähle ein Wallpaper."))
        }
        guard let wallpaper = config.wallpaper(forDisplay: window?.screen?.displayUUID) else {
            // Auf diesem Monitor ist in der App „Aus“ gewählt: schwarz lassen
            saverLog.notice("kein Wallpaper für diesen Monitor")
            return
        }
        guard FileManager.default.isReadableFile(atPath: wallpaper.root.appendingPathComponent(wallpaper.entry).path) else {
            saverLog.error("Dateien nicht lesbar: \(wallpaper.root.path, privacy: .public)")
            return showNote(L("The wallpaper files can't be read from the screen saver.", "Der Bildschirmschoner kann die Dateien des Wallpapers nicht lesen."))
        }
        saverLog.notice("zeige \(wallpaper.id, privacy: .public)")
        let frame = NSRect(origin: .zero, size: bounds.size)
        let view: WallpaperContent
        switch wallpaper.kind {
        case .web:
            view = WebWallpaperView(wallpaper: wallpaper, scheme: Self.scheme, fpsLimit: config.fps, frame: frame, ignoresOcclusion: true) { [] }
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

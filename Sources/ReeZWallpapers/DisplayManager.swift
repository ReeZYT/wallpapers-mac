import AppKit

struct DisplayInfo {
    let uuid: String
    let name: String
    let screen: NSScreen
}

/// Ein randloses Fenster auf der Ebene des Schreibtischhintergrunds: über dem macOS-Hintergrundbild,
/// unter den Desktop-Symbolen des Finders und unter allen normalen Fenstern.
final class WallpaperWindow: NSWindow {
    private(set) var content: WallpaperContent?
    private(set) var wallpaper: Wallpaper?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        // Auf allen Spaces, in Mission Control an Ort und Stelle, nicht in Cmd-Tab oder Fensterlisten
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        canHide = false
        isRestorable = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ wallpaper: Wallpaper, content: WallpaperContent) {
        self.wallpaper = wallpaper
        self.content = content
        content.frame = NSRect(origin: .zero, size: frame.size)
        content.autoresizingMask = [.width, .height]
        contentView = content
    }
}

/// Hält je Monitor ein Fenster mit dem gewählten Wallpaper und gleicht es mit Monitoren, Auswahl und Bibliothek ab.
@MainActor
final class DisplayManager {
    private let library: Library
    let media = MediaCenter()
    private(set) lazy var lockScreen = LockScreenMatcher(library: library)
    private let scheme = ProjectSchemeHandler()
    private var windows: [String: WallpaperWindow] = [:]
    private var occlusionObserver: NSObjectProtocol?

    /// Vom Menü gesetzt.
    var userPaused = false { didSet { applyPause() } }
    /// Monitore im Ruhezustand, Bildschirm gesperrt oder anderer Benutzer aktiv.
    var systemPaused = false { didSet { applyPause() } }

    init(library: Library) {
        self.library = library
        media.onEvent = { [weak self] kind, payload in
            self?.windows.values.forEach { $0.content?.media(kind, payload) }
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? WallpaperWindow else { return }
            MainActor.assumeIsolated { self?.applyPause(to: window) }
        }
    }

    // MARK: Monitore

    /// Angeschlossene Monitore von links nach rechts. Gleichnamige (zwei gleiche Dells) bekommen ihre Lage dazu.
    func displays() -> [DisplayInfo] {
        let screens = NSScreen.screens
            .compactMap { screen in screen.displayUUID.map { (uuid: $0, screen: screen) } }
            .sorted { ($0.screen.frame.minX, -$0.screen.frame.minY) < ($1.screen.frame.minX, -$1.screen.frame.minY) }
        // macOS nummeriert gleiche Monitore selbst („DELL (1)“, „DELL (2)“), aber nicht nach ihrer Lage
        let names = screens.map { $0.screen.localizedName.replacingOccurrences(of: " \\(\\d+\\)$", with: "", options: .regularExpression) }
        var byName: [String: [Int]] = [:]
        for (index, name) in names.enumerated() {
            byName[name, default: []].append(index)
        }
        return screens.enumerated().map { index, entry in
            var name = names[index]
            if let same = byName[name], same.count > 1, let position = same.firstIndex(of: index) {
                if same.count == 2 {
                    name += position == 0 ? L(" (left)", " (links)") : L(" (right)", " (rechts)")
                } else {
                    name += " (\(position + 1))"
                }
            }
            return DisplayInfo(uuid: entry.uuid, name: name, screen: entry.screen)
        }
    }

    /// Gewählte Wallpaper-ID für einen Monitor: eigene Zuordnung, sonst die für alle.
    func selection(for uuid: String) -> String? {
        Settings.assignments[uuid] ?? Settings.defaultWallpaper
    }

    func setAll(_ id: String) {
        Settings.assignments = [:]
        Settings.defaultWallpaper = id
        refresh()
    }

    func set(_ id: String, for uuid: String) {
        var assignments = Settings.assignments
        assignments[uuid] = id
        Settings.assignments = assignments
        refresh()
    }

    // MARK: Fenster

    /// Bringt Fenster und Inhalte auf den Stand von Monitoren, Auswahl und Bibliothek.
    /// - Parameter force: Inhalte auch dann neu aufbauen, wenn sich nichts geändert hat („Neu laden“).
    func refresh(force: Bool = false) {
        let current = displays()
        let present = Set(current.map(\.uuid))
        for (uuid, window) in windows where !present.contains(uuid) {
            window.close()
            windows[uuid] = nil
        }

        for display in current {
            guard let wallpaper = library.wallpaper(id: selection(for: display.uuid)) else {
                // Nichts gewählt oder nicht mehr vorhanden: macOS-Hintergrund zeigen
                windows[display.uuid]?.close()
                windows[display.uuid] = nil
                continue
            }
            let window = windows[display.uuid] ?? WallpaperWindow(screen: display.screen)
            windows[display.uuid] = window
            if window.frame != display.screen.frame {
                window.setFrame(display.screen.frame, display: true)
            }
            if force || window.wallpaper != wallpaper {
                window.show(wallpaper, content: makeContent(wallpaper, size: display.screen.frame.size))
            }
            window.orderFront(nil)
            applyPause(to: window)
        }
        lockScreen.update(current.map { LockScreenMatcher.Target(display: $0, window: windows[$0.uuid]) })
        writeSaverConfig(current)
    }

    /// Stand für den Bildschirmschoner ablegen (siehe SaverConfig).
    private func writeSaverConfig(_ current: [DisplayInfo]) {
        var config = SaverConfig()
        config.fps = Settings.fpsLimit
        config.fallback = Settings.defaultWallpaper
        for display in current {
            if let id = selection(for: display.uuid) { config.displays[display.uuid] = id }
        }
        for wallpaper in library.wallpapers {
            config.wallpapers[wallpaper.id] = SaverConfig.Entry(
                title: wallpaper.title, kind: wallpaper.kind.rawValue, root: wallpaper.root.path, entry: wallpaper.entry,
                revision: wallpaper.revision, isLocal: wallpaper.isLocal
            )
        }
        // Geänderte Einstellungen der Wallpaper: der Bildschirmschoner hat keinen Zugriff auf die der App
        var overrides: [String: [String: PropertyValue]] = [:]
        for (id, values) in Settings.propertyOverrides {
            let known = values.compactMapValues(PropertyValue.init)
            if !known.isEmpty { overrides[id] = known }
        }
        config.overrides = overrides.isEmpty ? nil : overrides
        config.write()
    }

    // MARK: Einstellungen der Wallpaper

    /// Die gerade gezeigten Wallpaper, von links nach rechts, jedes einmal.
    var activeWallpapers: [Wallpaper] {
        var seen = Set<String>()
        return windows.values
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap(\.wallpaper)
            .filter { seen.insert($0.id).inserted }
    }

    /// Gibt geänderte Einstellungen an alle Monitore, auf denen das Wallpaper läuft, und an den Bildschirmschoner.
    func apply(properties values: [String: Any], toWallpaper id: String) {
        for window in windows.values where window.wallpaper?.id == id {
            window.content?.properties(values)
        }
        writeSaverConfig(displays())
    }

    private func makeContent(_ wallpaper: Wallpaper, size: NSSize) -> WallpaperContent {
        let frame = NSRect(origin: .zero, size: size)
        switch wallpaper.kind {
        case .web:
            return WebWallpaperView(
                wallpaper: wallpaper, scheme: scheme, fpsLimit: Settings.fpsLimit, frame: frame,
                overrides: { Settings.propertyOverrides[wallpaper.id] ?? [:] },
                mediaSnapshot: { [media] in media.snapshot() }
            )
        case .video:
            return VideoWallpaperView(wallpaper: wallpaper, frame: frame)
        }
    }

    // MARK: Pause und Bildrate

    private func applyPause() {
        windows.values.forEach(applyPause(to:))
    }

    /// Pausiert auch, wenn ein Monitor ganz von anderen Fenstern verdeckt ist: dann sieht das Wallpaper niemand.
    private func applyPause(to window: WallpaperWindow) {
        let hidden = !window.occlusionState.contains(.visible)
        window.content?.setPaused(userPaused || systemPaused || hidden)
    }

    func applyFPSLimit() {
        windows.values.forEach { $0.content?.setFPSLimit(Settings.fpsLimit) }
    }

    // MARK: Diagnose

    /// Schreibt den Zustand aller Fenster nach `dir/report.json`. Ein Bild eines Fensters liefert bei Bedarf
    /// `screencapture -l <windowNumber> bild.png` (WKWebView.takeSnapshot zeichnet 3D-Transformationen falsch).
    func diagnose(into dir: URL, force: Bool, completion: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = Dictionary(uniqueKeysWithValues: displays().map { ($0.uuid, $0.name) })
        var report: [[String: Any]] = []
        let group = DispatchGroup()
        var stills: [String: String] = [:]
        if force {
            // Mit --force auch die Standbilder für den Sperrbildschirm ablegen (ohne sie einzutragen)
            group.enter()
            lockScreen.writeStills(to: dir) { result in
                stills = result
                group.leave()
            }
        }
        for (uuid, window) in windows {
            var entry: [String: Any] = [
                "display": names[uuid] ?? uuid,
                "wallpaper": window.wallpaper?.id ?? "",
                "frame": "\(Int(window.frame.minX)),\(Int(window.frame.minY)) \(Int(window.frame.width))x\(Int(window.frame.height))",
                "level": window.level.rawValue,
                "windowNumber": window.windowNumber,
                "visible": window.occlusionState.contains(.visible),
                "userPaused": userPaused,
                "systemPaused": systemPaused,
            ]
            guard let content = window.content else {
                report.append(entry)
                continue
            }
            group.enter()
            content.diagnose(force: force) { info in
                entry["content"] = info
                report.append(entry)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            var sorted = report.sorted { ($0["windowNumber"] as? Int ?? 0) < ($1["windowNumber"] as? Int ?? 0) }
            for index in sorted.indices {
                if let name = sorted[index]["display"] as? String, let still = stills[name] { sorted[index]["still"] = still }
                if let name = sorted[index]["display"] as? String, let screen = self.displays().first(where: { $0.name == name })?.screen {
                    sorted[index]["macOSWallpaper"] = NSWorkspace.shared.desktopImageURL(for: screen)?.lastPathComponent ?? ""
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: sorted, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("report.json"))
            }
            completion()
        }
    }

    // MARK: Maus

    /// Das Wallpaper-Fenster unter einem Punkt in Bildschirmkoordinaten.
    func window(at point: NSPoint) -> WallpaperWindow? {
        windows.values.first { $0.frame.contains(point) }
    }

    func isOwnWindow(_ number: Int) -> Bool {
        windows.values.contains { $0.windowNumber == number }
    }
}

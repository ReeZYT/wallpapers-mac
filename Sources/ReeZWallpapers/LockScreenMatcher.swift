import AppKit

/// Gleicht den Sperrbildschirm an das Wallpaper an.
///
/// Den Sperrbildschirm zeichnet macOS selbst über allen Fenstern; fremde Apps kommen dort nicht hin. Er zeigt aber
/// immer das macOS-Hintergrundbild des jeweiligen Monitors. Diese Klasse trägt dort ein Standbild des laufenden
/// Wallpapers ein: Gesperrt sieht man dasselbe Motiv, nur unbewegt, und nach dem Entsperren läuft es weiter.
/// Nebenbei passt dann auch die Tönung der Menüleiste, und nach dem Neustart steht das Motiv, bevor die App läuft.
///
/// Das Bild kommt vom Wallpaper selbst (Schnappschuss der Seite, erstes Bild des Videos) oder, wenn sich die Seite
/// nicht verlässlich abbilden lässt, aus dem Titelbild. Das zuvor eingestellte Hintergrundbild wird je Monitor
/// gemerkt und beim Ausschalten zurückgestellt. macOS merkt sich das Hintergrundbild je Space: eingetragen und
/// zurückgestellt wird deshalb auch bei jedem Wechsel des Space.
@MainActor
final class LockScreenMatcher {
    struct Target {
        let display: DisplayInfo
        let window: WallpaperWindow?
    }

    private let library: Library
    private let dir: URL
    private let fm = FileManager.default
    /// Display-UUID → Kennung des Wallpapers, dessen Standbild gerade eingetragen ist, und dessen Datei.
    private var applied: [String: (key: String, file: URL)] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private var targets: [Target] = []

    init(library: Library) {
        self.library = library
        dir = library.supportDir.appendingPathComponent("stills", isDirectory: true)
    }

    /// Nach jeder Änderung an Monitoren, Auswahl oder Schalter aufrufen.
    func update(_ targets: [Target]) {
        self.targets = targets
        guard Settings.lockScreenMatch else { return restoreAll() }
        for target in targets {
            let uuid = target.display.uuid
            guard let window = target.window, let wallpaper = window.wallpaper else {
                // Hier läuft kein Wallpaper: das alte Hintergrundbild soll wieder gelten
                pending[uuid]?.cancel()
                applied[uuid] = nil
                restore(target.display)
                continue
            }
            let key = wallpaper.id + "@" + wallpaper.revision
            if applied[uuid]?.key == key {
                reapplyIfNeeded(target.display)
                continue
            }
            // Ein frisch geladenes Wallpaper braucht einen Moment, bis sein erstes volles Bild steht
            pending[uuid]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.capture(uuid: uuid, key: key)
            }
            pending[uuid] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }

    /// Anderer Space: dort gilt ein eigenes Hintergrundbild.
    func spaceChanged() {
        for target in targets {
            if Settings.lockScreenMatch {
                reapplyIfNeeded(target.display)
            } else {
                restore(target.display)
            }
        }
    }

    // MARK: Standbild erzeugen und eintragen

    private func capture(uuid: String, key: String) {
        guard Settings.lockScreenMatch,
              let target = targets.first(where: { $0.display.uuid == uuid }),
              let window = target.window, let wallpaper = window.wallpaper,
              wallpaper.id + "@" + wallpaper.revision == key, let content = window.content else { return }
        content.still { [weak self] data in
            guard let self else { return }
            let image = data ?? self.library.cover(for: wallpaper).flatMap { try? Data(contentsOf: $0) }
            guard let image, Settings.lockScreenMatch else { return }
            self.write(image, uuid: uuid, key: key, original: data == nil ? self.library.cover(for: wallpaper) : nil)
        }
    }

    private func write(_ data: Data, uuid: String, key: String, original: URL?) {
        guard let target = targets.first(where: { $0.display.uuid == uuid }) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Neuer Dateiname bei jedem Eintragen: macOS merkt sich Bilder unter ihrem Pfad und zeigt sonst das alte
        let ext = original?.pathExtension.isEmpty == false ? original!.pathExtension : "jpg"
        let file = dir.appendingPathComponent("\(uuid)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            try data.write(to: file, options: .atomic)
            try set(file, on: target.display.screen)
        } catch {
            return
        }
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(uuid) && name != file.lastPathComponent {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        applied[uuid] = (key, file)
    }

    private func set(_ file: URL, on screen: NSScreen) throws {
        let current = NSWorkspace.shared.desktopImageURL(for: screen)
        // Nur merken, was nicht von uns stammt
        if let uuid = screen.displayUUID, let current, !isOurs(current), Settings.savedDesktopImages[uuid] == nil {
            var saved = Settings.savedDesktopImages
            saved[uuid] = current.path
            Settings.savedDesktopImages = saved
        }
        try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ])
    }

    private func reapplyIfNeeded(_ display: DisplayInfo) {
        guard let file = applied[display.uuid]?.file, fm.fileExists(atPath: file.path),
              NSWorkspace.shared.desktopImageURL(for: display.screen)?.path != file.path else { return }
        try? set(file, on: display.screen)
    }

    // MARK: Zurückstellen

    private func isOurs(_ url: URL) -> Bool {
        url.path.hasPrefix(dir.path + "/")
    }

    private func restoreAll() {
        pending.values.forEach { $0.cancel() }
        pending = [:]
        applied = [:]
        targets.forEach { restore($0.display) }
    }

    /// Stellt das gemerkte Hintergrundbild zurück, aber nur, wenn gerade eines unserer Standbilder eingetragen ist:
    /// was der Benutzer inzwischen selbst gewählt hat, bleibt.
    private func restore(_ display: DisplayInfo) {
        guard let current = NSWorkspace.shared.desktopImageURL(for: display.screen), isOurs(current) else { return }
        let saved = Settings.savedDesktopImages[display.uuid].map { URL(fileURLWithPath: $0) }
        let fallback = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
        let previous = saved.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } ?? fallback
        try? NSWorkspace.shared.setDesktopImageURL(previous, for: display.screen, options: [:])
    }

    // MARK: Diagnose

    /// Schreibt die Standbilder aller Monitore nach `folder`, ohne am Hintergrundbild etwas zu ändern.
    func writeStills(to folder: URL, completion: @escaping ([String: String]) -> Void) {
        var report: [String: String] = [:]
        let group = DispatchGroup()
        for (index, target) in targets.enumerated() {
            guard let window = target.window, let wallpaper = window.wallpaper, let content = window.content else { continue }
            group.enter()
            content.still { [library] data in
                let name = "still-\(index + 1)"
                if let data {
                    try? data.write(to: folder.appendingPathComponent(name + ".jpg"))
                    report[target.display.name] = "\(name).jpg (\(L("from the wallpaper", "vom Wallpaper")))"
                } else if let cover = library.cover(for: wallpaper), let data = try? Data(contentsOf: cover) {
                    try? data.write(to: folder.appendingPathComponent(name + "." + cover.pathExtension))
                    report[target.display.name] = "\(name).\(cover.pathExtension) (\(L("cover image", "Titelbild")))"
                } else {
                    report[target.display.name] = L("no image", "kein Bild")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(report) }
    }
}

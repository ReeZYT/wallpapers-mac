import Foundation

/// Was der Bildschirmschoner von der App wissen muss: welches Wallpaper auf welchem Monitor läuft und wo es liegt.
///
/// Die App schreibt das bei jeder Änderung nach ~/Library/Application Support/ReeZ Wallpapers/saver.json. Der
/// Bildschirmschoner läuft in der Sandbox von macOS (legacyScreenSaver), darf aber die ganze Platte lesen und holt
/// sich Datei und Projektordner von dort. Schreiben kann er nichts.
struct SaverConfig: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let title: String
        let kind: String
        let root: String
        let entry: String
        let revision: String
        let isLocal: Bool
    }

    var fps = 0
    /// Wallpaper für Monitore ohne eigene Zuordnung.
    var fallback: String?
    /// Display-UUID → Wallpaper-ID.
    var displays: [String: String] = [:]
    var wallpapers: [String: Entry] = [:]

    /// Der echte Benutzerordner: in der Sandbox zeigt NSHomeDirectory auf den Container des Bildschirmschoners.
    static var supportDir: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/ReeZ Wallpapers", isDirectory: true)
    }

    private static var file: URL { supportDir.appendingPathComponent("saver.json") }

    static func read() -> SaverConfig? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SaverConfig.self, from: data)
    }

    func write() {
        guard Self.read() != self else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.file, options: .atomic)
    }

    func wallpaper(forDisplay uuid: String?) -> Wallpaper? {
        guard let id = uuid.flatMap({ displays[$0] }) ?? fallback, let entry = wallpapers[id],
              let kind = Wallpaper.Kind(rawValue: entry.kind) else { return nil }
        return Wallpaper(
            id: id, title: entry.title, kind: kind, root: URL(fileURLWithPath: entry.root), entry: entry.entry,
            preview: nil, revision: entry.revision, isLocal: entry.isLocal
        )
    }
}

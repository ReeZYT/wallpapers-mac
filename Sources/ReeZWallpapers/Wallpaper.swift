import Foundation

/// Ein anzeigbares Wallpaper: ein Wallpaper-Engine-Projektordner (mit project.json) auf der Platte.
struct Wallpaper: Equatable {
    enum Kind: String {
        case web
        case video
    }

    /// „site/<slug>“ (von wallpapers.reez.cc) oder „local/<ordner>“ (eigener Ordner).
    let id: String
    let title: String
    let kind: Kind
    /// Projektordner, Symlinks aufgelöst.
    let root: URL
    /// index.html bzw. Videodatei, relativ zu `root`.
    let entry: String
    let preview: URL?
    /// Ändert sich, sobald der Inhalt neu geladen werden muss.
    let revision: String
    let isLocal: Bool

    /// Host der internen Adresse reezwp://<host>/…: jedes Wallpaper bekommt einen eigenen Ursprung.
    var host: String {
        let name = id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id
        let safe = name.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" }
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return (isLocal ? "local-" : "site-") + String(safe.prefix(40)) + "-" + String(hash % 0xFFFFFF, radix: 16)
    }
}

/// Die Teile von project.json, die die App braucht.
struct ProjectFile {
    let title: String?
    let kind: Wallpaper.Kind?
    let file: String?
    let preview: String?
    /// general.properties: Schlüssel → Beschreibung mit „type“, „value“ usw.
    let properties: [String: [String: Any]]

    init?(root: URL) {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("project.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        title = json["title"] as? String
        kind = (json["type"] as? String).flatMap { Wallpaper.Kind(rawValue: $0.lowercased()) }
        file = json["file"] as? String
        preview = json["preview"] as? String
        let general = json["general"] as? [String: Any]
        properties = (general?["properties"] as? [String: [String: Any]]) ?? [:]
    }

    /// Werte so, wie Wallpaper Engine sie an applyUserProperties übergibt: { schlüssel: { value: … } }.
    func userProperties(overrides: [String: Any]) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for (key, spec) in properties {
            if let value = overrides[key] ?? spec["value"] {
                out[key] = ["value": value]
            }
        }
        return out
    }
}

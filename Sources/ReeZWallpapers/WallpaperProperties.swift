import Foundation
import JavaScriptCore

/// Eine Einstellung eines Wallpapers, wie Wallpaper Engine sie aus `general.properties` in project.json anbietet.
struct WallpaperProperty {
    enum Kind {
        case bool
        case slider(min: Double, max: Double, fraction: Bool, precision: Int)
        case combo([(label: String, value: Any)])
        case color
        case text
    }

    let key: String
    /// Beschriftung in der Sprache des Benutzers, ohne HTML.
    let label: String
    let kind: Kind
    let defaultValue: Any
    /// JavaScript-Ausdruck wie `clock.value == true`: nur wenn er zutrifft, ist die Einstellung sichtbar.
    let condition: String?
}

/// Liest die Einstellungen eines Wallpapers und verwaltet die vom Benutzer geänderten Werte.
enum WallpaperProperties {
    /// Beschriftungen, die Wallpaper Engine selbst mitbringt.
    private static let builtIn: [String: (String, String)] = [
        "ui_browse_properties_scheme_color": ("Scheme color", "Schemafarbe"),
    ]

    /// Einstellungen in der Reihenfolge von project.json (`order`). Typen, die die App nicht kennt, fehlen.
    static func list(for wallpaper: Wallpaper) -> [WallpaperProperty] {
        guard let data = try? Data(contentsOf: wallpaper.root.appendingPathComponent("project.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = json["general"] as? [String: Any],
              let raw = general["properties"] as? [String: [String: Any]] else { return [] }
        let localization = general["localization"] as? [String: [String: String]] ?? [:]
        // Sprache des Benutzers, sonst Englisch, sonst irgendeine vorhandene
        let wanted = Language.isGerman ? "de-de" : "en-us"
        let tables = [localization[wanted], localization["en-us"], localization.values.first].compactMap { $0 }

        func text(_ key: String) -> String {
            let found = tables.lazy.compactMap { $0[key] }.first
                ?? builtIn[key].map { Language.isGerman ? $0.1 : $0.0 }
                ?? key
            // Beschriftungen dürfen in Wallpaper Engine HTML enthalten
            return found
                .replacingOccurrences(of: "<br */?>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let ordered = raw.sorted {
            let a = ($0.value["order"] as? NSNumber)?.intValue ?? Int.max
            let b = ($1.value["order"] as? NSNumber)?.intValue ?? Int.max
            return a == b ? $0.key < $1.key : a < b
        }
        return ordered.compactMap { key, spec in
            guard let type = (spec["type"] as? String)?.lowercased(), let value = spec["value"] else { return nil }
            let kind: WallpaperProperty.Kind
            switch type {
            case "bool":
                kind = .bool
            case "slider":
                let min = (spec["min"] as? NSNumber)?.doubleValue ?? 0
                let max = (spec["max"] as? NSNumber)?.doubleValue ?? 100
                let fraction = (spec["fraction"] as? Bool) ?? false
                let precision = (spec["precision"] as? NSNumber)?.intValue ?? 2
                kind = .slider(min: min, max: Swift.max(max, min), fraction: fraction, precision: precision)
            case "combo":
                let options = (spec["options"] as? [[String: Any]] ?? []).compactMap { option -> (label: String, value: Any)? in
                    guard let value = option["value"] else { return nil }
                    return (text(option["label"] as? String ?? "\(value)"), value)
                }
                guard !options.isEmpty else { return nil }
                kind = .combo(options)
            case "color":
                kind = .color
            case "textinput":
                kind = .text
            default:
                return nil
            }
            return WallpaperProperty(
                key: key,
                label: text(spec["text"] as? String ?? key),
                kind: kind,
                defaultValue: value,
                condition: (spec["condition"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    /// Aktuelle Werte: Standard aus project.json, überlagert von dem, was der Benutzer geändert hat.
    static func values(for wallpaper: Wallpaper, properties: [WallpaperProperty]) -> [String: Any] {
        let overrides = Settings.propertyOverrides[wallpaper.id] ?? [:]
        var values: [String: Any] = [:]
        for property in properties {
            values[property.key] = overrides[property.key] ?? property.defaultValue
        }
        return values
    }

    /// Merkt sich einen Wert. Entspricht er dem Standard, verschwindet der Eintrag wieder.
    static func store(_ value: Any, for property: WallpaperProperty, wallpaper: Wallpaper) {
        var all = Settings.propertyOverrides
        var own = all[wallpaper.id] ?? [:]
        if same(value, property.defaultValue) {
            own[property.key] = nil
        } else {
            own[property.key] = value
        }
        all[wallpaper.id] = own.isEmpty ? nil : own
        Settings.propertyOverrides = all
    }

    static func resetAll(for wallpaper: Wallpaper) {
        var all = Settings.propertyOverrides
        all[wallpaper.id] = nil
        Settings.propertyOverrides = all
    }

    static func same(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? NSNumber, let y = b as? NSNumber { return x == y }
        if let x = a as? String, let y = b as? String { return x == y }
        return false
    }

    /// Prüft, ob ein Wert zu einer Einstellung passt (für Werte, die von außen kommen), und bringt ihn in ihre Form.
    static func coerce(_ value: Any, for property: WallpaperProperty) -> Any? {
        switch property.kind {
        case .bool:
            return (value as? Bool).map { $0 as Any }
        case .slider(let min, let max, let fraction, _):
            guard !(value is Bool), let number = (value as? NSNumber)?.doubleValue else { return nil }
            let clamped = Swift.min(Swift.max(number, min), max)
            return fraction ? clamped as Any : Int(clamped.rounded()) as Any
        case .combo(let options):
            return options.first { same($0.value, value) || "\($0.value)" == "\(value)" }?.value
        case .color, .text:
            return value as? String
        }
    }

    /// Wertet die Sichtbarkeits-Bedingung einer Einstellung aus. Im Zweifel sichtbar.
    static func isVisible(_ property: WallpaperProperty, values: [String: Any]) -> Bool {
        guard let condition = property.condition, let context = JSContext() else { return true }
        for (key, value) in values {
            context.setObject(["value": value], forKeyedSubscript: key as NSString)
        }
        let result = context.evaluateScript(condition)
        if context.exception != nil { return true }
        return result?.toBool() ?? true
    }
}

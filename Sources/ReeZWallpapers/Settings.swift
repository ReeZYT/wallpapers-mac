import Foundation

/// Gespeicherte Auswahl (UserDefaults). Monitore werden über ihre Display-UUID gemerkt,
/// damit die Zuordnung Neustarts und Umstecken übersteht.
enum Settings {
    private static let d = UserDefaults.standard

    /// Steht für „kein Wallpaper“: der normale macOS-Hintergrund bleibt sichtbar.
    static let noneID = "none"

    /// Wallpaper für alle Monitore ohne eigene Zuordnung.
    static var defaultWallpaper: String? {
        get { d.string(forKey: "defaultWallpaper") }
        set { d.set(newValue, forKey: "defaultWallpaper") }
    }

    /// Display-UUID → Wallpaper-ID, nur für Monitore mit eigener Wahl.
    static var assignments: [String: String] {
        get { d.dictionary(forKey: "assignments") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "assignments") }
    }

    /// Slugs von wallpapers.reez.cc, die zusätzlich zur öffentlichen Liste geladen werden (dort versteckte Wallpaper).
    static var extraSlugs: [String] {
        get { d.stringArray(forKey: "extraSlugs") ?? [] }
        set { d.set(newValue, forKey: "extraSlugs") }
    }

    /// Bildrate, die den Web-Wallpapern mitgegeben wird. 0 = keine Grenze.
    static var fpsLimit: Int {
        get { d.integer(forKey: "fpsLimit") }
        set { d.set(newValue, forKey: "fpsLimit") }
    }

    /// Mausbewegung und Klicks auf dem Desktop an die Wallpaper weitergeben.
    static var mouseEnabled: Bool {
        get { d.object(forKey: "mouseEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "mouseEnabled") }
    }

    /// Laufenden Titel (Spotify, Apple Music) an die Wallpaper geben.
    static var mediaEnabled: Bool {
        get { d.object(forKey: "mediaEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "mediaEnabled") }
    }

    /// Standbild des Wallpapers als macOS-Hintergrundbild eintragen, damit der Sperrbildschirm dazu passt.
    static var lockScreenMatch: Bool {
        get { d.bool(forKey: "lockScreenMatch") }
        set { d.set(newValue, forKey: "lockScreenMatch") }
    }

    /// Display-UUID → Pfad des macOS-Hintergrundbilds, das vor dem Angleichen eingestellt war (zum Zurückstellen).
    static var savedDesktopImages: [String: String] {
        get { d.dictionary(forKey: "savedDesktopImages") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "savedDesktopImages") }
    }

    /// ⌃⌘Q (Sperr-Kürzel von macOS) zusätzlich für „Sperren – Wallpaper läuft weiter“ belegen.
    static var takeOverSystemLockShortcut: Bool {
        get { d.bool(forKey: "takeOverSystemLockShortcut") }
        set { d.set(newValue, forKey: "takeOverSystemLockShortcut") }
    }

    /// Wallpaper-ID → abweichende Werte für Einstellungen aus project.json (Schlüssel → Wert).
    static var propertyOverrides: [String: [String: Any]] {
        get { d.dictionary(forKey: "propertyOverrides") as? [String: [String: Any]] ?? [:] }
        set { d.set(newValue, forKey: "propertyOverrides") }
    }
}

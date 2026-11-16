import AppKit

/// `ReeZWallpapers --diagnose <ordner> [--force]` fragt die laufende App nach ihrem Zustand: je Monitor Fenster,
/// Wallpaper, Bildrate und Fehler der Seite. Gedacht zum Nachsehen, wenn ein Wallpaper nicht tut, was es soll.
///
/// `ReeZWallpapers --set <wallpaper-id> <schlüssel>=<wert>` ändert eine Einstellung eines Wallpapers in der laufenden
/// App, genau wie das Einstellungsfenster (Wert als JSON: true, 40, "sakura"). `--settings <wallpaper-id>` öffnet das
/// Fenster, `--settings close` schließt alle.
enum Diagnostics {
    static let request = Notification.Name("cc.reez.wallpapers.diagnose")
    static let reply = Notification.Name("cc.reez.wallpapers.diagnosed")
    static let setProperty = Notification.Name("cc.reez.wallpapers.set")
    static let openSettings = Notification.Name("cc.reez.wallpapers.settings")

    /// `--set` und `--settings`: an die laufende App weiterreichen.
    static func runCommand(arguments: [String]) -> Never {
        let center = DistributedNotificationCenter.default()
        if let index = arguments.firstIndex(of: "--settings"), arguments.count > index + 1 {
            center.postNotificationName(openSettings, object: arguments[index + 1], userInfo: nil, deliverImmediately: true)
        } else if let index = arguments.firstIndex(of: "--set"), arguments.count > index + 2,
                  let split = arguments[index + 2].firstIndex(of: "=") {
            let key = String(arguments[index + 2][..<split])
            let value = String(arguments[index + 2][arguments[index + 2].index(after: split)...])
            center.postNotificationName(setProperty, object: arguments[index + 1], userInfo: ["key": key, "value": value], deliverImmediately: true)
        } else {
            print("Usage: ReeZWallpapers --set <wallpaper-id> <key>=<json value> | --settings <wallpaper-id>|close")
            exit(2)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        exit(0)
    }

    /// Aufrufende Seite: Anfrage an die laufende App schicken und auf den Bericht warten.
    static func runClient(arguments: [String]) -> Never {
        guard let index = arguments.firstIndex(of: "--diagnose"), arguments.count > index + 1 else {
            print("Usage: ReeZWallpapers --diagnose <folder> [--force]")
            exit(2)
        }
        let dir = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let center = DistributedNotificationCenter.default()
        var answered = false
        let observer = center.addObserver(forName: reply, object: dir.path, queue: .main) { _ in answered = true }
        center.postNotificationName(request, object: dir.path, userInfo: ["force": arguments.contains("--force") ? "1" : "0"], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(20)
        while !answered, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        center.removeObserver(observer)
        if answered, let text = try? String(contentsOf: dir.appendingPathComponent("report.json"), encoding: .utf8) {
            print(text)
            exit(0)
        }
        print("No answer. Is ReeZ Wallpapers running?")
        exit(1)
    }

    /// In der laufenden App: auf Anfragen antworten.
    @MainActor
    static func serve(_ displays: DisplayManager, library: Library) -> [NSObjectProtocol] {
        let center = DistributedNotificationCenter.default()
        let settings = center.addObserver(forName: openSettings, object: nil, queue: .main) { note in
            let id = note.object as? String
            MainActor.assumeIsolated {
                if id == "close" {
                    PropertiesPanel.closeAll()
                } else if let wallpaper = library.wallpaper(id: id) {
                    PropertiesPanel.show(wallpaper, displays: displays)
                }
            }
        }
        let set = center.addObserver(forName: setProperty, object: nil, queue: .main) { note in
            let id = note.object as? String
            let key = note.userInfo?["key"] as? String
            let text = note.userInfo?["value"] as? String ?? ""
            MainActor.assumeIsolated {
                // Nur bekannte Einstellungen mit passendem Wert annehmen
                guard let wallpaper = library.wallpaper(id: id),
                      let property = WallpaperProperties.list(for: wallpaper).first(where: { $0.key == key }),
                      let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
                      let value = WallpaperProperties.coerce(parsed, for: property) else { return }
                PropertiesPanel.set(value, for: property, wallpaper: wallpaper, displays: displays)
            }
        }
        let diagnose = center.addObserver(forName: request, object: nil, queue: .main) { note in
            guard let path = note.object as? String else { return }
            let force = (note.userInfo?["force"] as? String) == "1"
            MainActor.assumeIsolated {
                displays.diagnose(into: URL(fileURLWithPath: path), force: force) {
                    center.postNotificationName(reply, object: path, userInfo: nil, deliverImmediately: true)
                }
            }
        }
        return [settings, set, diagnose]
    }
}

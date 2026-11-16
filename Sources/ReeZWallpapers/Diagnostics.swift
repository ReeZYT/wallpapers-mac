import AppKit

/// `ReeZWallpapers --diagnose <ordner> [--force]` fragt die laufende App nach ihrem Zustand: je Monitor Fenster,
/// Wallpaper, Bildrate und Fehler der Seite. Gedacht zum Nachsehen, wenn ein Wallpaper nicht tut, was es soll.
enum Diagnostics {
    static let request = Notification.Name("cc.reez.wallpapers.diagnose")
    static let reply = Notification.Name("cc.reez.wallpapers.diagnosed")

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
    static func serve(_ displays: DisplayManager) -> NSObjectProtocol {
        let center = DistributedNotificationCenter.default()
        return center.addObserver(forName: request, object: nil, queue: .main) { note in
            guard let path = note.object as? String else { return }
            let force = (note.userInfo?["force"] as? String) == "1"
            MainActor.assumeIsolated {
                displays.diagnose(into: URL(fileURLWithPath: path), force: force) {
                    center.postNotificationName(reply, object: path, userInfo: nil, deliverImmediately: true)
                }
            }
        }
    }
}

import AppKit

/// Gibt Mausbewegung und Klicks auf dem freien Desktop an die Wallpaper weiter.
///
/// Die Fenster liegen hinter den Desktop-Symbolen des Finders und bekommen deshalb selbst keine Mausereignisse.
/// Ein globaler Beobachter sieht Bewegung und Klicks systemweit (für Mausereignisse braucht macOS dafür keine
/// Freigabe). Weitergegeben wird nur, wenn unter dem Zeiger wirklich der Desktop liegt und kein anderes Fenster.
@MainActor
final class MouseForwarder {
    private let displays: DisplayManager
    private var monitor: Any?
    private var lastMove: TimeInterval = 0
    private weak var hovered: WallpaperWindow?
    private weak var pressed: WallpaperWindow?
    /// Fensternummer → liegt auf Desktop-Ebene. Spart die Abfrage beim Fensterdienst bei jeder Bewegung.
    private var desktopCache: [Int: Bool] = [:]

    init(displays: DisplayManager) {
        self.displays = displays
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        } else if !enabled, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            leave()
        }
    }

    private func handle(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons & 1

        if event.type == .leftMouseUp {
            if let window = pressed {
                send("up", to: window, at: point, buttons: 0)
                pressed = nil
            }
            return
        }

        // Bewegungen auf rund 60 pro Sekunde begrenzen
        if event.type == .mouseMoved || event.type == .leftMouseDragged {
            guard event.timestamp - lastMove >= 1.0 / 62.0 else { return }
            lastMove = event.timestamp
        }

        // Ein auf dem Desktop begonnener Zug (gedrückte Taste) bleibt beim selben Wallpaper
        let target = pressed ?? (isDesktop(at: point) ? displays.window(at: point) : nil)
        guard let target else { return leave() }
        if hovered !== target {
            leave()
            hovered = target
        }
        if event.type == .leftMouseDown {
            pressed = target
            send("down", to: target, at: point, buttons: 1)
        } else {
            send("move", to: target, at: point, buttons: buttons)
        }
    }

    private func leave() {
        if let window = hovered {
            send("leave", to: window, at: NSEvent.mouseLocation, buttons: 0)
        }
        hovered = nil
        pressed = nil
    }

    private func send(_ type: String, to window: WallpaperWindow, at point: NSPoint, buttons: Int) {
        // Bildschirmkoordinaten (Ursprung unten links) → Seite (Ursprung oben links)
        window.content?.mouse(type, x: point.x - window.frame.minX, y: window.frame.maxY - point.y, buttons: buttons)
    }

    /// Liegt unter dem Punkt der Desktop (Finder-Symbolebene oder unser eigenes Fenster) und kein App-Fenster,
    /// Dock oder Menüleiste? Normale Fenster haben Ebene 0 und höher, alles auf Desktop-Ebene ist negativ.
    private func isDesktop(at point: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0 else { return true }
        if let known = desktopCache[number] { return known }
        var result = displays.isOwnWindow(number)
        if !result,
           let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
           let layer = info.first?[kCGWindowLayer as String] as? Int {
            result = layer < 0
        }
        if desktopCache.count > 512 { desktopCache.removeAll() }
        desktopCache[number] = result
        return result
    }
}

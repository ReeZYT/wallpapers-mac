import AppKit
import ServiceManagement

/// Menüeintrag mit Closure statt Target/Action.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.state = state
        self.image = image
    }

    required init(coder: NSCoder) {
        fatalError("nicht aus einem Nib")
    }

    @objc private func fire() {
        handler()
    }
}

/// Das Menüleisten-Symbol: die einzige Oberfläche der App.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let library: Library
    private let displays: DisplayManager
    private let mouse: MouseForwarder
    private var thumbnails: [URL: NSImage] = [:]

    init(library: Library, displays: DisplayManager, mouse: MouseForwarder) {
        self.library = library
        self.displays = displays
        self.mouse = mouse
        super.init()
        let image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "ReeZ Wallpapers")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "ReeZ Wallpapers")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Das Menü entsteht bei jedem Öffnen neu: Monitore, Bibliothek und Haken sind immer aktuell.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Eigene Ordner können jederzeit dazukommen oder verschwinden
        library.reloadFromDisk()
        menu.removeAllItems()
        let current = displays.displays()
        let selections = current.map { displays.selection(for: $0.uuid) ?? Settings.noneID }

        if library.wallpapers.isEmpty {
            menu.addItem(info(library.isSyncing ? "Wallpaper werden geladen …" : "Noch keine Wallpaper geladen"))
        } else if current.count <= 1 {
            addWallpaperItems(to: menu, selected: Set(selections), allSame: true) { [displays] id in displays.setAll(id) }
        } else {
            let allSame = Set(selections).count == 1
            let all = NSMenuItem(title: "Alle Monitore", action: nil, keyEquivalent: "")
            all.submenu = NSMenu()
            addWallpaperItems(to: all.submenu!, selected: Set(selections), allSame: allSame) { [displays] id in displays.setAll(id) }
            menu.addItem(all)
            for (display, selection) in zip(current, selections) {
                let item = NSMenuItem(title: display.name, action: nil, keyEquivalent: "")
                item.submenu = NSMenu()
                addWallpaperItems(to: item.submenu!, selected: [selection], allSame: true) { [displays] id in displays.set(id, for: display.uuid) }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Pausieren", state: displays.userPaused ? .on : .off) { [displays] in
            displays.userPaused.toggle()
        })
        let fps = NSMenuItem(title: "Bildrate", action: nil, keyEquivalent: "")
        fps.submenu = NSMenu()
        for (label, value) in [("Unbegrenzt", 0), ("60 Bilder/s", 60), ("30 Bilder/s", 30), ("24 Bilder/s", 24)] {
            fps.submenu?.addItem(ActionItem(label, state: Settings.fpsLimit == value ? .on : .off) { [displays] in
                Settings.fpsLimit = value
                displays.applyFPSLimit()
            })
        }
        menu.addItem(fps)
        menu.addItem(ActionItem("Maus und Klicks an Wallpaper weitergeben", state: Settings.mouseEnabled ? .on : .off) { [mouse] in
            Settings.mouseEnabled.toggle()
            mouse.setEnabled(Settings.mouseEnabled)
        })

        menu.addItem(.separator())
        menu.addItem(info(syncStatus()))
        menu.addItem(ActionItem("Jetzt mit wallpapers.reez.cc abgleichen") { [library] in
            Task { await library.sync() }
        })
        menu.addItem(ActionItem("Wallpaper neu laden") { [library, displays] in
            library.reloadFromDisk()
            displays.refresh(force: true)
        })
        let own = NSMenuItem(title: "Eigene Wallpaper", action: nil, keyEquivalent: "")
        own.submenu = NSMenu()
        own.submenu?.addItem(ActionItem("Projektordner hinzufügen …") { [weak self] in self?.addFolder() })
        own.submenu?.addItem(ActionItem("Verstecktes Wallpaper von der Seite …") { [weak self] in self?.addHidden() })
        own.submenu?.addItem(ActionItem("Ordner im Finder zeigen") { [library] in
            NSWorkspace.shared.open(library.localDir)
        })
        menu.addItem(own)

        menu.addItem(.separator())
        menu.addItem(ActionItem("Beim Anmelden starten", state: SMAppService.mainApp.status == .enabled ? .on : .off) { [weak self] in
            self?.toggleLoginItem()
        })
        let quit = NSMenuItem(title: "ReeZ Wallpapers beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Liste aller Wallpaper plus „Aus“. Haken beim gewählten; Strich, wenn es nur auf manchen Monitoren läuft.
    private func addWallpaperItems(to menu: NSMenu, selected: Set<String>, allSame: Bool, choose: @escaping (String) -> Void) {
        func state(_ id: String) -> NSControl.StateValue {
            selected.contains(id) ? (allSame ? .on : .mixed) : .off
        }
        var hadLocal = false
        for wallpaper in library.wallpapers {
            if wallpaper.isLocal, !hadLocal {
                hadLocal = true
                menu.addItem(.separator())
            }
            menu.addItem(ActionItem(wallpaper.title, state: state(wallpaper.id), image: thumbnail(wallpaper)) { choose(wallpaper.id) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Aus (macOS-Hintergrund)", state: state(Settings.noneID)) { choose(Settings.noneID) })
    }

    private func thumbnail(_ wallpaper: Wallpaper) -> NSImage? {
        guard let url = wallpaper.preview else { return nil }
        if let cached = thumbnails[url] { return cached }
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else { return nil }
        // 16:9-Ausschnitt mit leicht gerundeten Ecken
        let size = NSSize(width: 44, height: 25)
        let image = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            let scale = max(rect.width / source.size.width, rect.height / source.size.height)
            let drawn = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: NSRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
            return true
        }
        thumbnails[url] = image
        return image
    }

    private func syncStatus() -> String {
        if library.isSyncing { return "Abgleich läuft …" }
        if let error = library.lastError {
            return "Abgleich fehlgeschlagen: " + String(error.prefix(80))
        }
        guard let date = library.lastSync else { return "Noch nicht abgeglichen" }
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return "Zuletzt abgeglichen: " + formatter.string(from: date)
    }

    private func addFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Projektordner eines Wallpapers wählen"
        panel.message = "Der Ordner mit project.json, wie Wallpaper Engine ihn anlegt."
        panel.prompt = "Hinzufügen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            _ = try library.addLocalFolder(folder)
        } catch {
            alert("Ordner nicht hinzugefügt", error.localizedDescription)
        }
    }

    private func addHidden() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Verstecktes Wallpaper hinzufügen"
        alert.informativeText = "Adresse der Detailseite oder der Name hinter wallpapers.reez.cc/. Das Wallpaper wird ab jetzt wie die öffentlichen mit abgeglichen."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "singularity-interactive-black-hole"
        alert.accessoryView = field
        alert.addButton(withTitle: "Hinzufügen")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let input = field.stringValue
        Task { [weak self, library] in
            do {
                _ = try await library.addSiteWallpaper(input)
            } catch {
                self?.alert("Wallpaper nicht hinzugefügt", error.localizedDescription)
            }
        }
    }

    private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Anmeldeobjekt nicht geändert", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

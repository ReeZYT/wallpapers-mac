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
            menu.addItem(info(library.isSyncing ? L("Loading wallpapers…", "Wallpaper werden geladen …") : L("No wallpapers loaded yet", "Noch keine Wallpaper geladen")))
        } else if current.count <= 1 {
            addWallpaperItems(to: menu, selected: Set(selections), allSame: true) { [displays] id in displays.setAll(id) }
        } else {
            let allSame = Set(selections).count == 1
            let all = NSMenuItem(title: L("All displays", "Alle Monitore"), action: nil, keyEquivalent: "")
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
        menu.addItem(ActionItem(L("Pause", "Pausieren"), state: displays.userPaused ? .on : .off) { [displays] in
            displays.userPaused.toggle()
        })
        let fps = NSMenuItem(title: L("Frame rate", "Bildrate"), action: nil, keyEquivalent: "")
        fps.submenu = NSMenu()
        for (label, value) in [(L("Unlimited", "Unbegrenzt"), 0), (L("60 fps", "60 Bilder/s"), 60), (L("30 fps", "30 Bilder/s"), 30), (L("24 fps", "24 Bilder/s"), 24)] {
            fps.submenu?.addItem(ActionItem(label, state: Settings.fpsLimit == value ? .on : .off) { [displays] in
                Settings.fpsLimit = value
                displays.applyFPSLimit()
            })
        }
        menu.addItem(fps)
        menu.addItem(ActionItem(L("Pass mouse and clicks to wallpapers", "Maus und Klicks an Wallpaper weitergeben"), state: Settings.mouseEnabled ? .on : .off) { [mouse] in
            Settings.mouseEnabled.toggle()
            mouse.setEnabled(Settings.mouseEnabled)
        })

        menu.addItem(ActionItem(L("Show the current track in wallpapers (Spotify, Apple Music)", "Laufenden Titel an Wallpaper geben (Spotify, Apple Music)"), state: Settings.mediaEnabled ? .on : .off) { [displays] in
            Settings.mediaEnabled.toggle()
            displays.media.setEnabled(Settings.mediaEnabled)
        })
        let track = displays.media.track
        if Settings.mediaEnabled, !track.title.isEmpty {
            let symbol = displays.media.playback == .playing ? "▶︎" : "❙❙"
            menu.addItem(info("\(symbol)  \(track.title)" + (track.artist.isEmpty ? "" : " – \(track.artist)")))
        }

        // Noch nicht an einem echten System erprobt (ändert das macOS-Hintergrundbild): nur sichtbar, wenn schon
        // eingeschaltet oder das Menü mit gedrückter Wahltaste geöffnet wird
        if Settings.lockScreenMatch || NSEvent.modifierFlags.contains(.option) {
            menu.addItem(ActionItem(L("Match the lock screen (still image as macOS wallpaper)", "Sperrbildschirm angleichen (Standbild als macOS-Hintergrund)"), state: Settings.lockScreenMatch ? .on : .off) { [displays] in
                Settings.lockScreenMatch.toggle()
                displays.refresh()
            })
        }

        if SaverInstaller.isAvailable {
            let lock = ActionItem(L("Lock – wallpaper keeps playing", "Sperren – Wallpaper läuft weiter")) { SaverInstaller.start() }
            lock.keyEquivalent = "l"
            lock.keyEquivalentModifierMask = [.control, .option, .command]
            menu.addItem(lock)
            if SaverInstaller.isInstalled {
                if SystemLock.isAvailable {
                    menu.addItem(ActionItem(L("Lock key (⌃⌘Q) does this too", "Sperrtaste (ctrl + cmd + Q) macht das auch"), state: Settings.takeOverSystemLockShortcut ? .on : .off) {
                        Settings.takeOverSystemLockShortcut.toggle()
                        LockShortcuts.shared.apply()
                    })
                }
                if !SystemLock.locksWithScreenSaver(maxAge: 30) {
                    menu.addItem(info(L("macOS does not lock right away: set the password to “Immediately”", "macOS sperrt dabei nicht sofort: Passwort auf „Sofort“ stellen")))
                }
            }
            menu.addItem(ActionItem(SaverInstaller.isInstalled
                ? L("Screen saver settings…", "Bildschirmschoner-Einstellungen …")
                : L("Set up the screen saver…", "Bildschirmschoner einrichten …")) { [weak self] in self?.setUpSaver() })
        }

        menu.addItem(.separator())
        menu.addItem(info(syncStatus()))
        menu.addItem(ActionItem(L("Check wallpapers.reez.cc now", "Jetzt mit wallpapers.reez.cc abgleichen")) { [library] in
            Task { await library.sync() }
        })
        menu.addItem(ActionItem(L("Reload wallpapers", "Wallpaper neu laden")) { [library, displays] in
            library.reloadFromDisk()
            displays.refresh(force: true)
        })
        let own = NSMenuItem(title: L("My own wallpapers", "Eigene Wallpaper"), action: nil, keyEquivalent: "")
        own.submenu = NSMenu()
        own.submenu?.addItem(ActionItem(L("Add project folder…", "Projektordner hinzufügen …")) { [weak self] in self?.addFolder() })
        // Für Wallpaper, die auf der Seite noch versteckt sind: nur sichtbar, wenn schon eines eingetragen ist
        // oder das Menü mit gedrückter Wahltaste geöffnet wird
        if !Settings.extraSlugs.isEmpty || NSEvent.modifierFlags.contains(.option) {
            own.submenu?.addItem(ActionItem(L("Add hidden wallpaper from the site…", "Verstecktes Wallpaper von der Seite …")) { [weak self] in self?.addHidden() })
        }
        own.submenu?.addItem(ActionItem(L("Show folder in Finder", "Ordner im Finder zeigen")) { [library] in
            NSWorkspace.shared.open(library.localDir)
        })
        menu.addItem(own)

        menu.addItem(.separator())
        if let version = library.availableUpdate {
            menu.addItem(ActionItem(L("Update available: version \(version)…", "Update verfügbar: Version \(version) …")) {
                NSWorkspace.shared.open(Library.site.appendingPathComponent("mac/"))
            })
        }
        menu.addItem(ActionItem(L("Open wallpapers.reez.cc", "wallpapers.reez.cc öffnen")) {
            NSWorkspace.shared.open(Library.site)
        })
        menu.addItem(ActionItem(L("Start at login", "Beim Anmelden starten"), state: SMAppService.mainApp.status == .enabled ? .on : .off) { [weak self] in
            self?.toggleLoginItem()
        })
        let quit = NSMenuItem(title: L("Quit ReeZ Wallpapers", "ReeZ Wallpapers beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        menu.addItem(ActionItem(L("Off (macOS wallpaper)", "Aus (macOS-Hintergrund)"), state: state(Settings.noneID)) { choose(Settings.noneID) })
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
        if library.isSyncing { return L("Checking the site…", "Abgleich läuft …") }
        if let error = library.lastError {
            return L("Check failed: ", "Abgleich fehlgeschlagen: ") + String(error.prefix(80))
        }
        guard let date = library.lastSync else { return L("Not checked yet", "Noch nicht abgeglichen") }
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return L("Last checked: ", "Zuletzt abgeglichen: ") + formatter.string(from: date)
    }

    private func addFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = L("Choose a wallpaper project folder", "Projektordner eines Wallpapers wählen")
        panel.message = L("The folder with project.json, as created by Wallpaper Engine.", "Der Ordner mit project.json, wie Wallpaper Engine ihn anlegt.")
        panel.prompt = L("Add", "Hinzufügen")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            _ = try library.addLocalFolder(folder)
        } catch {
            alert(L("Folder not added", "Ordner nicht hinzugefügt"), error.localizedDescription)
        }
    }

    private func addHidden() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Add a hidden wallpaper", "Verstecktes Wallpaper hinzufügen")
        alert.informativeText = L("The address of its page, or the name after wallpapers.reez.cc/. From now on it is kept up to date like the public ones.", "Adresse der Detailseite oder der Name hinter wallpapers.reez.cc/. Das Wallpaper wird ab jetzt wie die öffentlichen mit abgeglichen.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "singularity-interactive-black-hole"
        alert.accessoryView = field
        alert.addButton(withTitle: L("Add", "Hinzufügen"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let input = field.stringValue
        Task { [weak self, library] in
            do {
                _ = try await library.addSiteWallpaper(input)
            } catch {
                self?.alert(L("Wallpaper not added", "Wallpaper nicht hinzugefügt"), error.localizedDescription)
            }
        }
    }

    private func setUpSaver() {
        do {
            if !SaverInstaller.isInstalled { try SaverInstaller.install() }
        } catch {
            return alert(L("Screen saver not set up", "Bildschirmschoner nicht eingerichtet"), error.localizedDescription)
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Two settings in macOS", "Zwei Einstellungen in macOS")
        alert.informativeText = L(
            "1. Screen Saver: choose “ReeZ Wallpapers” (under Other).\n2. Lock Screen: set “Require password after screen saver begins or display is turned off” to Immediately.\n\nAfter that, “Lock – wallpaper keeps playing” (⌃⌥⌘L) locks your Mac while the wallpaper keeps moving until you touch the mouse or keyboard. The menu can also hand the normal lock shortcut ⌃⌘Q to it. The Touch ID button always shows the macOS lock screen.",
            "1. Bildschirmschoner: „ReeZ Wallpapers“ wählen (unter „Andere“).\n2. Sperrbildschirm: „Passwort erforderlich nach Beginn des Bildschirmschoners oder Ausschalten des Displays“ auf „Sofort“ stellen.\n\nDanach sperrt „Sperren – Wallpaper läuft weiter“ (⌃⌥⌘L) den Mac, und das Wallpaper bewegt sich weiter, bis du Maus oder Tastatur anfasst. Im Menü lässt sich auch das normale Sperr-Kürzel ⌃⌘Q dafür übernehmen. Die Touch-ID-Taste zeigt immer den Sperrbildschirm von macOS."
        )
        alert.addButton(withTitle: L("Open Screen Saver settings", "Bildschirmschoner-Einstellungen öffnen"))
        alert.addButton(withTitle: L("Later", "Später"))
        if alert.runModal() == .alertFirstButtonReturn {
            SaverInstaller.openSettings()
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
            alert(L("Login item not changed", "Anmeldeobjekt nicht geändert"), error.localizedDescription)
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

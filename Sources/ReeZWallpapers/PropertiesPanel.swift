import AppKit

/// Das Einstellungsfenster eines Wallpapers: dieselben Schalter, Regler, Farben und Auswahllisten, die Wallpaper Engine
/// aus `general.properties` baut. Jede Änderung wirkt sofort auf alle Monitore, auf denen das Wallpaper läuft, und
/// wird je Wallpaper gespeichert.
@MainActor
final class PropertiesPanel: NSObject, NSWindowDelegate {
    private static var open: [String: PropertiesPanel] = [:]

    static func show(_ wallpaper: Wallpaper, displays: DisplayManager) {
        let panel = open[wallpaper.id] ?? PropertiesPanel(wallpaper: wallpaper, displays: displays)
        open[wallpaper.id] = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.window.makeKeyAndOrderFront(nil)
    }

    static func closeAll() {
        open.values.forEach { $0.window.close() }
    }

    /// Setzt einen Wert: speichern, an die laufenden Wallpaper geben, ein offenes Fenster nachziehen.
    static func set(_ value: Any, for property: WallpaperProperty, wallpaper: Wallpaper, displays: DisplayManager) {
        WallpaperProperties.store(value, for: property, wallpaper: wallpaper)
        displays.apply(properties: [property.key: value], toWallpaper: wallpaper.id)
        open[wallpaper.id]?.reload()
    }

    private let wallpaper: Wallpaper
    private let displays: DisplayManager
    private let properties: [WallpaperProperty]
    private var values: [String: Any]
    private let window: NSWindow
    private var rows: [String: NSGridRow] = [:]
    private var controls: [String: NSControl] = [:]
    private var valueLabels: [String: NSTextField] = [:]
    private var pending: [String: DispatchWorkItem] = [:]

    private init(wallpaper: Wallpaper, displays: DisplayManager) {
        self.wallpaper = wallpaper
        self.displays = displays
        properties = WallpaperProperties.list(for: wallpaper)
        values = WallpaperProperties.values(for: wallpaper, properties: properties)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: min(640, CGFloat(properties.count) * 34 + 110)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        super.init()
        window.title = wallpaper.title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 220)
        window.delegate = self
        build()
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        pending.values.forEach { $0.perform() }
        Self.open[wallpaper.id] = nil
    }

    // MARK: Aufbau

    private final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }

    private func build() {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        for property in properties {
            let label = NSTextField(wrappingLabelWithString: property.label)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = grid.addRow(with: [label, control(for: property)])
            row.yPlacement = .center
            rows[property.key] = row
        }

        let document = Flipped()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document

        let reset = NSButton(title: L("Reset to defaults", "Auf Standard zurücksetzen"), target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        let note = NSTextField(labelWithString: L("Changes apply right away.", "Änderungen wirken sofort."))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let footer = NSStackView(views: [reset, NSView(), note])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 12, right: 20)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(line)
        content.addSubview(footer)
        window.contentView = content
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
        ])
        reload()
    }

    private func control(for property: WallpaperProperty) -> NSView {
        let id = NSUserInterfaceItemIdentifier(property.key)
        switch property.kind {
        case .bool:
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.identifier = id
            toggle.target = self
            toggle.action = #selector(toggled(_:))
            controls[property.key] = toggle
            return toggle
        case .slider(let min, let max, _, _):
            let slider = NSSlider(value: min, minValue: min, maxValue: max, target: self, action: #selector(slid(_:)))
            slider.identifier = id
            slider.isContinuous = true
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let value = NSTextField(labelWithString: "")
            value.alignment = .right
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.translatesAutoresizingMaskIntoConstraints = false
            value.widthAnchor.constraint(equalToConstant: 46).isActive = true
            controls[property.key] = slider
            valueLabels[property.key] = value
            let stack = NSStackView(views: [slider, value])
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        case .combo(let options):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.identifier = id
            for option in options {
                popup.addItem(withTitle: option.label)
                popup.lastItem?.representedObject = option.value
            }
            popup.target = self
            popup.action = #selector(picked(_:))
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            controls[property.key] = popup
            return popup
        case .color:
            let well = NSColorWell()
            well.identifier = id
            well.target = self
            well.action = #selector(colored(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 48).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            controls[property.key] = well
            return well
        case .text:
            let field = NSTextField(string: "")
            field.identifier = id
            field.target = self
            field.action = #selector(typed(_:))
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 204).isActive = true
            controls[property.key] = field
            return field
        }
    }

    // MARK: Werte anzeigen

    /// Bringt alle Bedienelemente auf den gespeicherten Stand (nach dem Öffnen, Zurücksetzen oder einer Änderung von außen).
    private func reload() {
        values = WallpaperProperties.values(for: wallpaper, properties: properties)
        for property in properties {
            guard let control = controls[property.key], let value = values[property.key] else { continue }
            switch property.kind {
            case .bool:
                (control as? NSSwitch)?.state = (value as? Bool) == true ? .on : .off
            case .slider:
                control.doubleValue = (value as? NSNumber)?.doubleValue ?? 0
                valueLabels[property.key]?.stringValue = Self.format(control.doubleValue, property)
            case .combo(let options):
                let index = options.firstIndex { WallpaperProperties.same($0.value, value) || "\($0.value)" == "\(value)" }
                (control as? NSPopUpButton)?.selectItem(at: index ?? 0)
            case .color:
                (control as? NSColorWell)?.color = Self.color(from: value as? String ?? "") ?? .white
            case .text:
                control.stringValue = value as? String ?? ""
            }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        for property in properties where property.condition != nil {
            rows[property.key]?.isHidden = !WallpaperProperties.isVisible(property, values: values)
        }
    }

    private static func format(_ number: Double, _ property: WallpaperProperty) -> String {
        if case .slider(_, _, let fraction, let precision) = property.kind, fraction {
            return String(format: "%.\(max(0, min(precision, 4)))f", number)
        }
        return String(Int(number.rounded()))
    }

    /// Farben stehen in Wallpaper Engine als „r g b“ mit Werten von 0 bis 1.
    private static func color(from text: String) -> NSColor? {
        let parts = text.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: 1)
    }

    private static func text(from color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { String((Double($0) * 1000).rounded() / 1000) }
            .joined(separator: " ")
    }

    // MARK: Änderungen

    private func property(of sender: NSControl) -> WallpaperProperty? {
        properties.first { $0.key == sender.identifier?.rawValue }
    }

    private func commit(_ value: Any, _ property: WallpaperProperty) {
        values[property.key] = value
        WallpaperProperties.store(value, for: property, wallpaper: wallpaper)
        displays.apply(properties: [property.key: value], toWallpaper: wallpaper.id)
        updateVisibility()
    }

    @objc private func toggled(_ sender: NSSwitch) {
        guard let property = property(of: sender) else { return }
        commit(sender.state == .on, property)
    }

    @objc private func slid(_ sender: NSSlider) {
        guard let property = property(of: sender), case .slider(_, _, let fraction, _) = property.kind else { return }
        let value: Any = fraction ? sender.doubleValue : Int(sender.doubleValue.rounded())
        valueLabels[property.key]?.stringValue = Self.format(sender.doubleValue, property)
        // Beim Ziehen nicht jede Zwischenstufe an das Wallpaper geben: manche Einstellungen bauen dort viel neu auf
        pending[property.key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending[property.key] = nil
            self?.commit(value, property)
        }
        pending[property.key] = work
        if NSApp.currentEvent?.type == .leftMouseUp {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    @objc private func picked(_ sender: NSPopUpButton) {
        guard let property = property(of: sender), let value = sender.selectedItem?.representedObject else { return }
        commit(value, property)
    }

    @objc private func colored(_ sender: NSColorWell) {
        guard let property = property(of: sender) else { return }
        commit(Self.text(from: sender.color), property)
    }

    @objc private func typed(_ sender: NSTextField) {
        guard let property = property(of: sender) else { return }
        commit(sender.stringValue, property)
    }

    @objc private func resetAll() {
        pending.values.forEach { $0.cancel() }
        pending = [:]
        WallpaperProperties.resetAll(for: wallpaper)
        reload()
        displays.apply(properties: values, toWallpaper: wallpaper.id)
    }
}

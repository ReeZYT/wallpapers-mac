// Zeichnet das App-Symbol (drei Monitore in den Farben von reez.cc, dunkles Thema) und schreibt Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: s)
    transform.concat()

    // --bg-raised, --line-strong und --accent aus dem dunklen Thema der Seite
    let background = NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255, alpha: 1)
    let line = NSColor(srgbRed: 0x33 / 255, green: 0x33 / 255, blue: 0x37 / 255, alpha: 1)
    let accent = NSColor(srgbRed: 0x5f / 255, green: 0xcf / 255, blue: 0x8a / 255, alpha: 1)
    let quiet = NSColor(srgbRed: 0xa1 / 255, green: 0xa1 / 255, blue: 0xa7 / 255, alpha: 1)

    // Grundform nach Apples Raster: 824 px breit, mittig, runde Ecken
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    background.setFill()
    plate.fill()
    line.setStroke()
    plate.lineWidth = 6
    plate.stroke()

    func monitor(_ rect: NSRect, filled: Bool) {
        let screen = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        let color = filled ? accent : quiet
        if filled {
            // Der mittlere Monitor steht vor den beiden äußeren: erst deckend, dann der grüne Schimmer
            background.setFill()
            screen.fill()
            accent.withAlphaComponent(0.14).setFill()
            screen.fill()
        }
        color.setStroke()
        screen.lineWidth = 22
        screen.lineJoinStyle = .round
        screen.stroke()
        // Fuß
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: rect.midX, y: rect.minY))
        stand.line(to: NSPoint(x: rect.midX, y: rect.minY - 44))
        stand.move(to: NSPoint(x: rect.midX - 54, y: rect.minY - 44))
        stand.line(to: NSPoint(x: rect.midX + 54, y: rect.minY - 44))
        stand.lineWidth = 22
        stand.lineCapStyle = .round
        stand.stroke()
    }
    monitor(NSRect(x: 196, y: 452, width: 200, height: 128), filled: false)
    monitor(NSRect(x: 628, y: 452, width: 200, height: 128), filled: false)
    monitor(NSRect(x: 352, y: 420, width: 320, height: 204), filled: true)

    // Das grüne Quadrat aus dem Schriftzug der Seite
    accent.setFill()
    NSBezierPath(roundedRect: NSRect(x: 478, y: 488, width: 68, height: 68), xRadius: 16, yRadius: 16).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try tool.run()
tool.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(tool.terminationStatus == 0 ? "Resources/AppIcon.icns geschrieben" : "iconutil fehlgeschlagen")

// Zeichnet das App-Symbol (drei Monitore im Terminal-Grün von reez.cc) und schreibt Resources/AppIcon.icns.
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

    let background = NSColor(srgbRed: 0x05 / 255, green: 0x07 / 255, blue: 0x0a / 255, alpha: 1)
    let line = NSColor(srgbRed: 0x19 / 255, green: 0x22 / 255, blue: 0x2b / 255, alpha: 1)
    let accent = NSColor(srgbRed: 0, green: 1, blue: 0x41 / 255, alpha: 1)

    // Grundform nach Apples Raster: 824 px breit, mittig, runde Ecken
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    background.setFill()
    plate.fill()
    line.setStroke()
    plate.lineWidth = 6
    plate.stroke()

    func monitor(_ rect: NSRect, filled: Bool) {
        let screen = NSBezierPath(rect: rect)
        if filled {
            // Der mittlere Monitor steht vor den beiden äußeren: erst deckend, dann der grüne Schimmer
            background.setFill()
            screen.fill()
            accent.withAlphaComponent(0.16).setFill()
            screen.fill()
        }
        accent.setStroke()
        screen.lineWidth = 22
        screen.stroke()
        // Fuß
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: rect.midX, y: rect.minY))
        stand.line(to: NSPoint(x: rect.midX, y: rect.minY - 44))
        stand.move(to: NSPoint(x: rect.midX - 54, y: rect.minY - 44))
        stand.line(to: NSPoint(x: rect.midX + 54, y: rect.minY - 44))
        stand.lineWidth = 22
        stand.stroke()
    }
    monitor(NSRect(x: 196, y: 452, width: 200, height: 128), filled: false)
    monitor(NSRect(x: 628, y: 452, width: 200, height: 128), filled: false)
    monitor(NSRect(x: 352, y: 420, width: 320, height: 204), filled: true)

    // Eingabezeichen wie im Terminal der Seite
    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: 432, y: 566))
    prompt.line(to: NSPoint(x: 492, y: 522))
    prompt.line(to: NSPoint(x: 432, y: 478))
    prompt.move(to: NSPoint(x: 520, y: 478))
    prompt.line(to: NSPoint(x: 596, y: 478))
    prompt.lineWidth = 22
    accent.setStroke()
    prompt.stroke()

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

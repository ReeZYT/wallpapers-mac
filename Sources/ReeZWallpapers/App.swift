import AppKit

@main
@MainActor
enum App {
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.runClient(arguments: CommandLine.arguments)
        }
        if CommandLine.arguments.contains("--set") || CommandLine.arguments.contains("--settings") {
            Diagnostics.runCommand(arguments: CommandLine.arguments)
        }
        // Nur ein Menüleisten-Symbol, kein Dock-Symbol (zusätzlich LSUIElement in der Info.plist).
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // NSApplication hält den Delegate nur schwach
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

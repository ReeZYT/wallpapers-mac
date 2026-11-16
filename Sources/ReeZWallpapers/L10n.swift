import Foundation

/// Zwei Sprachen ohne .lproj-Ordner: Deutsch auf deutsch eingestellten Macs, sonst Englisch.
/// Systemeigene Texte (Öffnen-Dialog, Fehlermeldungen von macOS) folgen `CFBundleLocalizations` in der Info.plist.
enum Language {
    static let isGerman = Locale.preferredLanguages.first?.lowercased().hasPrefix("de") ?? false
}

func L(_ english: String, _ german: String) -> String {
    Language.isGerman ? german : english
}

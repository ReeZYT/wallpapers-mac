import AppKit

/// Was ein Wallpaper-Fenster von seinem Inhalt braucht, egal ob Web oder Video.
protocol WallpaperContent: NSView {
    func setPaused(_ paused: Bool)
    func setFPSLimit(_ fps: Int)
    /// type: „move“, „down“, „up“ oder „leave“. Koordinaten in Punkten, Ursprung oben links.
    func mouse(_ type: String, x: CGFloat, y: CGFloat, buttons: Int)
    /// Medienereignis wie in Wallpaper Engine: „status“, „properties“, „thumbnail“, „playback“ oder „timeline“.
    func media(_ kind: String, _ payload: [String: Any])
    /// Geänderte Einstellungen des Wallpapers (Schlüssel aus project.json → neuer Wert).
    func properties(_ values: [String: Any])
    /// Standbild als JPEG, oder nil, wenn sich der Inhalt nicht verlässlich abbilden lässt (dann nimmt der Aufrufer
    /// das Titelbild des Wallpapers).
    func still(completion: @escaping (Data?) -> Void)
    /// Zustand für `--diagnose`. `force` lässt das Wallpaper für die Messung laufen, auch wenn es gerade niemand sieht.
    func diagnose(force: Bool, completion: @escaping ([String: Any]) -> Void)
}

import AppKit

/// Der laufende Titel für die Wallpaper: das Gegenstück zur „Medienintegration“ von Wallpaper Engine.
///
/// Unter Windows liest Wallpaper Engine den Titel systemweit aus. macOS gibt diese Auskunft seit 15.4 nur noch an
/// Apples eigene Programme (MediaRemote antwortet anderen leer). Spotify und Apple Music melden Titelwechsel, Start
/// und Pause aber selbst über verteilte Mitteilungen, für die es keine Freigabe braucht. Das Cover nennt Spotify dabei
/// nicht; die App holt es zum Titel über Spotifys öffentliche oEmbed-Auskunft.
///
/// Grenze: Die Player melden nur Änderungen. Startet die App mitten in einem Titel, erscheint er beim nächsten
/// Titelwechsel oder nach Pause und Weiter.
@MainActor
final class MediaCenter {
    /// Zahlen wie `window.wallpaperMediaIntegration.PLAYBACK_…` in Wallpaper Engine.
    enum Playback: Int {
        case stopped = 0
        case playing = 1
        case paused = 2
    }

    struct Track: Equatable {
        var title = ""
        var artist = ""
        var album = ""
        var albumArtist = ""
        /// Kennung des Players, bei Spotify „spotify:track:…“.
        var id: String?
    }

    private(set) var track = Track()
    private(set) var playback: Playback = .stopped
    private var position: Double = 0
    private var positionAt = Date()
    private var duration: Double = 0
    private var thumbnail: [String: Any]?
    /// Player, von dem der aktuelle Stand stammt.
    private var source: String?
    private var observers: [NSObjectProtocol] = []
    private var artworkCache: [String: [String: Any]] = [:]
    private var artworkTask: Task<Void, Never>?

    /// Art („status“, „properties“, „thumbnail“, „playback“, „timeline“) und Daten, wie Wallpaper Engine sie den
    /// gleichnamigen Listenern übergibt.
    var onEvent: ((String, [String: Any]) -> Void)?

    private(set) var isEnabled = false

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        let center = DistributedNotificationCenter.default()
        if enabled {
            observe(center, "com.spotify.client.PlaybackStateChanged") { $0.spotify($1) }
            observe(center, "com.apple.Music.playerInfo") { $0.appleMusic($1) }
            emit("status", ["enabled": true])
        } else {
            observers.forEach(center.removeObserver)
            observers = []
            artworkTask?.cancel()
            // Wallpaper zurück in den Leerlauf
            track = Track()
            playback = .stopped
            thumbnail = nil
            source = nil
            duration = 0
            emit("properties", propertiesPayload())
            emit("thumbnail", ["thumbnail": ""])
            emit("playback", ["state": Playback.stopped.rawValue])
        }
    }

    private func observe(_ center: DistributedNotificationCenter, _ name: String, _ handler: @escaping (MediaCenter, [AnyHashable: Any]) -> Void) {
        observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, info)
            }
        })
    }

    /// Alles, was ein frisch geladenes Wallpaper wissen muss, in der Reihenfolge, in der es gesendet wird.
    func snapshot() -> [(String, [String: Any])] {
        guard isEnabled else { return [] }
        var events: [(String, [String: Any])] = [("status", ["enabled": true])]
        if !track.title.isEmpty {
            events.append(("properties", propertiesPayload()))
            events.append(("thumbnail", thumbnail ?? ["thumbnail": ""]))
            if duration > 0 { events.append(("timeline", timelinePayload())) }
        }
        events.append(("playback", ["state": playback.rawValue]))
        return events
    }

    // MARK: Player

    private func spotify(_ info: [AnyHashable: Any]) {
        var new = Track()
        new.title = info["Name"] as? String ?? ""
        new.artist = info["Artist"] as? String ?? ""
        new.album = info["Album"] as? String ?? ""
        new.albumArtist = info["Album Artist"] as? String ?? ""
        new.id = info["Track ID"] as? String
        update(
            source: "spotify",
            track: new,
            playback: Self.playback(info["Player State"]),
            position: (info["Playback Position"] as? NSNumber)?.doubleValue,
            duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
        )
    }

    private func appleMusic(_ info: [AnyHashable: Any]) {
        var new = Track()
        new.title = info["Name"] as? String ?? ""
        new.artist = info["Artist"] as? String ?? ""
        new.album = info["Album"] as? String ?? ""
        new.albumArtist = info["Album Artist"] as? String ?? ""
        // Music nennt weder Position noch Cover
        update(
            source: "music",
            track: new,
            playback: Self.playback(info["Player State"]),
            position: nil,
            duration: ((info["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000
        )
    }

    private static func playback(_ value: Any?) -> Playback {
        switch (value as? String)?.lowercased() {
        case "playing": return .playing
        case "paused": return .paused
        default: return .stopped
        }
    }

    private func update(source new: String, track newTrack: Track, playback newPlayback: Playback, position newPosition: Double?, duration newDuration: Double) {
        // Läuft gerade ein anderer Player, zählt dessen Stand: Pause oder Ende des zweiten Players ändert nichts
        if let source, source != new, playback == .playing, newPlayback != .playing { return }
        source = new

        let trackChanged = newTrack != track
        // Ohne gemeldete Position die geschätzte festhalten, bevor sich der Zustand ändert
        let frozen = currentPosition()
        if trackChanged {
            track = newTrack
            emit("properties", propertiesPayload())
        }
        position = newPosition ?? (trackChanged ? 0 : frozen)
        positionAt = Date()
        duration = newDuration
        if duration > 0 { emit("timeline", timelinePayload()) }
        if newPlayback != playback {
            playback = newPlayback
            emit("playback", ["state": playback.rawValue])
        }
        if trackChanged { loadArtwork() }
    }

    private func currentPosition() -> Double {
        var seconds = position
        if playback == .playing { seconds += Date().timeIntervalSince(positionAt) }
        if duration > 0 { seconds = min(seconds, duration) }
        return max(0, seconds)
    }

    private func propertiesPayload() -> [String: Any] {
        [
            "title": track.title,
            "artist": track.artist,
            "subTitle": "",
            "albumTitle": track.album,
            "albumArtist": track.albumArtist.isEmpty ? track.artist : track.albumArtist,
            "genres": "",
            "contentType": "music",
        ]
    }

    private func timelinePayload() -> [String: Any] {
        ["position": currentPosition(), "duration": duration]
    }

    private func emit(_ kind: String, _ payload: [String: Any]) {
        onEvent?(kind, payload)
    }

    // MARK: Cover

    private func loadArtwork() {
        artworkTask?.cancel()
        thumbnail = nil
        guard let id = track.id, let link = Self.spotifyLink(id) else {
            // Kein Cover zu haben: ausdrücklich leer melden, sonst bliebe das vorige stehen
            return emit("thumbnail", ["thumbnail": ""])
        }
        if let cached = artworkCache[id] {
            thumbnail = cached
            return emit("thumbnail", cached)
        }
        artworkTask = Task { [weak self] in
            let payload = await Self.fetchSpotifyArtwork(link)
            guard let self, !Task.isCancelled, self.track.id == id else { return }
            if let payload {
                if self.artworkCache.count >= 40 { self.artworkCache.removeAll() }
                self.artworkCache[id] = payload
            }
            self.thumbnail = payload
            self.emit("thumbnail", payload ?? ["thumbnail": ""])
        }
    }

    /// „spotify:track:<id>“ oder „spotify:episode:<id>“ → Adresse der Seite bei Spotify. Lokale Dateien haben keine.
    private static func spotifyLink(_ id: String) -> String? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", ["track", "episode"].contains(String(parts[1])),
              parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "https://open.spotify.com/\(parts[1])/\(parts[2])"
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    /// Fragt Spotifys oEmbed-Auskunft nach dem Vorschaubild und lädt es, möglichst in 640 px.
    private nonisolated static func fetchSpotifyArtwork(_ link: String) async -> [String: Any]? {
        var query = URLComponents(string: "https://open.spotify.com/oembed")!
        query.queryItems = [URLQueryItem(name: "url", value: link)]
        guard let url = query.url else { return nil }

        var thumbnailURL: URL?
        // Die Auskunft antwortet vereinzelt leer: ein zweiter Versuch
        for _ in 0..<2 where thumbnailURL == nil {
            if let (data, _) = try? await session.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["thumbnail_url"] as? String, let found = URL(string: text),
               found.scheme == "https", let host = found.host, host.hasSuffix(".spotifycdn.com") || host.hasSuffix(".scdn.co") {
                thumbnailURL = found
            }
        }
        guard let thumbnailURL else { return nil }

        // Die Auskunft nennt das 300er-Bild; dieselbe Adresse mit anderer Größenkennung liefert 640 px
        let large = URL(string: thumbnailURL.absoluteString.replacingOccurrences(of: "00001e02", with: "0000b273"))
        for candidate in [large, thumbnailURL].compactMap({ $0 }) {
            if let (data, response) = try? await session.data(from: candidate),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let image = NSImage(data: data), image.isValid {
                let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
                var payload: [String: Any] = ["thumbnail": "data:\(type);base64," + data.base64EncodedString()]
                payload.merge(colors(of: image)) { _, new in new }
                return payload
            }
        }
        return nil
    }

    /// Farben des Covers, wie Wallpaper Engine sie mitliefert: die drei häufigsten Töne und eine lesbare Schriftfarbe.
    private nonisolated static func colors(of image: NSImage) -> [String: Any] {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [:] }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Grobes Raster (16 Stufen je Kanal), je Feld Anzahl und Farbsumme
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let old = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
        }
        var picked: [(r: Int, g: Int, b: Int)] = []
        for bin in bins.values.sorted(by: { $0.count > $1.count }) {
            let color = (r: bin.r / bin.count, g: bin.g / bin.count, b: bin.b / bin.count)
            // Töne überspringen, die einem schon gewählten zu ähnlich sind
            let distinct = picked.allSatisfy { abs($0.r - color.r) + abs($0.g - color.g) + abs($0.b - color.b) > 96 }
            if distinct { picked.append(color) }
            if picked.count == 3 { break }
        }
        guard let primary = picked.first else { return [:] }
        func hex(_ c: (r: Int, g: Int, b: Int)) -> String { String(format: "#%02x%02x%02x", c.r, c.g, c.b) }
        let luminance = (299 * primary.r + 587 * primary.g + 114 * primary.b) / 1000
        let contrast = luminance > 140 ? "#000000" : "#ffffff"
        return [
            "primaryColor": hex(primary),
            "secondaryColor": hex(picked.count > 1 ? picked[1] : primary),
            "tertiaryColor": hex(picked.count > 2 ? picked[2] : (picked.count > 1 ? picked[1] : primary)),
            "textColor": contrast,
            "highContrastColor": contrast,
        ]
    }
}

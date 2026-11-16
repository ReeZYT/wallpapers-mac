import Foundation

/// Alle Wallpaper, die die App zeigen kann.
///
/// Zwei Quellen, beide unter ~/Library/Application Support/ReeZ Wallpapers/:
///   site/<slug>/   Abgleich mit wallpapers.reez.cc: meta.json, state.json (ETag des ZIPs), project/ (entpackt)
///   local/<name>/  eigene Projektordner (oder Symlinks darauf), z. B. für Wallpaper, die noch nicht auf der Seite sind
///
/// Die Seite hat keine eigene Schnittstelle, aber alles Nötige ist öffentlich: sitemap.xml nennt die Slugs,
/// /files/<slug>/meta.json beschreibt ein Wallpaper, /files/<slug>/<slug>.zip ist der Projektordner.
@MainActor
final class Library {
    static let site = URL(string: "https://wallpapers.reez.cc")!

    private(set) var wallpapers: [Wallpaper] = []
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    let supportDir: URL
    var siteDir: URL { supportDir.appendingPathComponent("site", isDirectory: true) }
    var localDir: URL { supportDir.appendingPathComponent("local", isDirectory: true) }

    private let fm = FileManager.default
    private let session: URLSession

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDir = base.appendingPathComponent("ReeZ Wallpapers", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "ReeZWallpapers-mac/1.0"]
        session = URLSession(configuration: config)
        try? fm.createDirectory(at: siteDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
    }

    func wallpaper(id: String?) -> Wallpaper? {
        guard let id else { return nil }
        return wallpapers.first { $0.id == id }
    }

    // MARK: Von der Platte lesen

    func reloadFromDisk() {
        var list: [Wallpaper] = []

        // Reihenfolge der Seite (neueste bzw. hervorgehobene zuerst), danach alles Übrige nach Titel
        let order = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: siteDir.appendingPathComponent("order.json")))) ?? []
        var site: [String: Wallpaper] = [:]
        for slug in subdirectories(of: siteDir) where Self.isSlug(slug) {
            let dir = siteDir.appendingPathComponent(slug, isDirectory: true)
            let meta = readMeta(dir.appendingPathComponent("meta.json"))
            let etag = readState(dir)["etag"] ?? ""
            if let w = makeWallpaper(id: "site/" + slug, root: dir.appendingPathComponent("project", isDirectory: true), title: meta?.title, isLocal: false, revision: etag) {
                site[slug] = w
            }
        }
        for slug in order {
            if let w = site.removeValue(forKey: slug) { list.append(w) }
        }
        list += site.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        var local: [Wallpaper] = []
        for name in subdirectories(of: localDir) {
            let dir = localDir.appendingPathComponent(name, isDirectory: true)
            if let w = makeWallpaper(id: "local/" + name, root: dir, title: nil, isLocal: true, revision: nil) {
                local.append(w)
            }
        }
        list += local.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let changed = list != wallpapers
        wallpapers = list
        if changed { onChange?() }
    }

    private func subdirectories(of dir: URL) -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            // fileExists folgt Symlinks: verlinkte Ordner zählen mit
            return fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    private func makeWallpaper(id: String, root: URL, title: String?, isLocal: Bool, revision: String?) -> Wallpaper? {
        let root = root.resolvingSymlinksInPath()
        guard let project = ProjectFile(root: root), let kind = project.kind else { return nil }
        let entry = project.file ?? (kind == .web ? "index.html" : "")
        guard !entry.isEmpty, fm.fileExists(atPath: root.appendingPathComponent(entry).path) else { return nil }
        let preview = project.preview.map { root.appendingPathComponent($0) }.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        // Eigene Ordner: Änderungsdatum von project.json und Startdatei, damit „Neu laden“ Änderungen mitbekommt
        let rev = revision ?? [root.appendingPathComponent("project.json"), root.appendingPathComponent(entry)]
            .map { String(Int(((try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)) }
            .joined(separator: "-")
        return Wallpaper(
            id: id,
            title: title ?? project.title ?? root.lastPathComponent,
            kind: kind,
            root: root,
            entry: entry,
            preview: preview,
            revision: rev,
            isLocal: isLocal
        )
    }

    // MARK: Abgleich mit wallpapers.reez.cc

    private struct SiteMeta: Decodable {
        struct Assets: Decodable {
            let zip: String
            let zipSize: Int?
        }
        let slug: String
        let title: String
        let type: String
        let assets: Assets
    }

    private enum SyncError: LocalizedError {
        case http(Int, String)
        case badArchive(String)
        case unsupported(String)
        /// Die Seite kennt unter diesem Namen kein Wallpaper (z. B. eine andere Seite aus der Sitemap).
        case notAWallpaper(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let what): return "\(what): HTTP \(code)"
            case .badArchive(let slug): return L("\(slug): the ZIP has no project folder with a project.json", "\(slug): ZIP enthält keinen Projektordner mit project.json")
            case .unsupported(let slug): return L("\(slug): this wallpaper type is not supported", "\(slug): Typ wird nicht unterstützt")
            case .notAWallpaper(let slug): return L("The site has no wallpaper called \(slug).", "Auf der Seite gibt es kein Wallpaper namens \(slug).")
            }
        }
    }

    private static func isSlug(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    private func readMeta(_ url: URL) -> SiteMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SiteMeta.self, from: data)
    }

    private func readState(_ dir: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("state.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Holt neue und geänderte Wallpaper von der Seite. Fehler lassen den vorhandenen Stand unberührt.
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        onChange?()
        var problems: [String] = []
        await checkForAppUpdate()
        do {
            // Öffentliche Liste, dahinter die von Hand hinzugefügten (auf der Seite versteckten) Wallpaper
            let listed = try await fetchSlugs()
            var slugs = listed
            for slug in Settings.extraSlugs where Self.isSlug(slug) && !slugs.contains(slug) {
                slugs.append(slug)
            }
            for slug in slugs {
                do {
                    try await syncOne(slug)
                } catch SyncError.notAWallpaper {
                    // Kein Wallpaper: eine andere Seite aus der Sitemap (z. B. /mac/) oder ein gelöschtes verstecktes
                    Settings.extraSlugs.removeAll { $0 == slug }
                    slugs.removeAll { $0 == slug }
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            // Was die Seite nicht mehr listet (gelöscht oder versteckt), fliegt auch hier raus
            for cached in subdirectories(of: siteDir) where !slugs.contains(cached) {
                try? fm.removeItem(at: siteDir.appendingPathComponent(cached))
            }
            try? JSONEncoder().encode(slugs).write(to: siteDir.appendingPathComponent("order.json"), options: .atomic)
            lastSync = Date()
            lastError = problems.isEmpty ? nil : problems.joined(separator: "; ")
        } catch {
            lastError = error.localizedDescription
        }
        isSyncing = false
        reloadFromDisk()
        onChange?()
    }

    /// Neuere Fassung der App auf der Seite? `/mac/version.json` nennt die aktuelle; das Menü zeigt dann einen Hinweis.
    private(set) var availableUpdate: String?

    private func checkForAppUpdate() async {
        guard let (data, response) = try? await session.data(from: Self.site.appendingPathComponent("mac/version.json")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latest = json["version"] as? String,
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        availableUpdate = latest.compare(current, options: .numeric) == .orderedDescending ? latest : nil
    }

    private func fetchSlugs() async throws -> [String] {
        let (data, response) = try await session.data(from: Self.site.appendingPathComponent("sitemap.xml"))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SyncError.http(code, "sitemap.xml") }
        let xml = String(decoding: data, as: UTF8.self)
        let pattern = "<loc>" + NSRegularExpression.escapedPattern(for: Self.site.absoluteString) + "/([a-z0-9]+(?:-[a-z0-9]+)*)/</loc>"
        let regex = try NSRegularExpression(pattern: pattern)
        var slugs: [String] = []
        for match in regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            if let range = Range(match.range(at: 1), in: xml) {
                let slug = String(xml[range])
                if !slugs.contains(slug) { slugs.append(slug) }
            }
        }
        return slugs
    }

    private func syncOne(_ slug: String) async throws {
        let files = Self.site.appendingPathComponent("files").appendingPathComponent(slug)
        let (metaData, metaResponse) = try await session.data(from: files.appendingPathComponent("meta.json"))
        let metaCode = (metaResponse as? HTTPURLResponse)?.statusCode ?? 0
        if metaCode == 404 { throw SyncError.notAWallpaper(slug) }
        guard metaCode == 200 else { throw SyncError.http(metaCode, "\(slug)/meta.json") }
        let meta = try JSONDecoder().decode(SiteMeta.self, from: metaData)
        guard meta.slug == slug, ["web", "video"].contains(meta.type) else { throw SyncError.unsupported(slug) }
        guard meta.assets.zip.range(of: "^[A-Za-z0-9._-]+\\.zip$", options: .regularExpression) != nil else { throw SyncError.badArchive(slug) }

        let dir = siteDir.appendingPathComponent(slug, isDirectory: true)
        let projectDir = dir.appendingPathComponent("project", isDirectory: true)
        let haveProject = fm.fileExists(atPath: projectDir.appendingPathComponent("project.json").path)

        // ZIP nur laden, wenn es sich geändert hat (ETag vom letzten Mal mitschicken → 304)
        var request = URLRequest(url: files.appendingPathComponent(meta.assets.zip))
        if haveProject, let etag = readState(dir)["etag"], !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (zip, response) = try await session.download(for: request)
        defer { try? fm.removeItem(at: zip) }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if code == 304 {
            // Inhalt unverändert, Titel kann sich trotzdem geändert haben
            try metaData.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            return
        }
        guard code == 200 else { throw SyncError.http(code, meta.assets.zip) }

        // In einen Nachbarordner entpacken und erst dann austauschen: ein laufendes Wallpaper sieht nie halbe Stände
        let staging = dir.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try await Self.unzip(zip, to: staging)
        guard let found = findProjectRoot(in: staging), let project = ProjectFile(root: found), project.kind != nil else {
            throw SyncError.badArchive(slug)
        }
        if fm.fileExists(atPath: projectDir.path) { try fm.removeItem(at: projectDir) }
        try fm.moveItem(at: found, to: projectDir)
        try metaData.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        let etag = http?.value(forHTTPHeaderField: "ETag") ?? http?.value(forHTTPHeaderField: "Last-Modified") ?? UUID().uuidString
        try JSONEncoder().encode(["etag": etag]).write(to: dir.appendingPathComponent("state.json"), options: .atomic)
    }

    /// Der Ordner mit project.json: das ZIP selbst oder ein Unterordner (die Seite packt <slug>/ hinein).
    private func findProjectRoot(in dir: URL) -> URL? {
        if fm.fileExists(atPath: dir.appendingPathComponent("project.json").path) { return dir }
        for name in subdirectories(of: dir) {
            let sub = dir.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: sub.appendingPathComponent("project.json").path) { return sub }
        }
        return nil
    }

    private nonisolated static func unzip(_ zip: URL, to dir: URL) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-o", zip.path, "-d", dir.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                // 1 = nur Warnungen, die Dateien sind trotzdem da
                if p.terminationStatus == 0 || p.terminationStatus == 1 {
                    done.resume()
                } else {
                    done.resume(throwing: SyncError.badArchive(zip.lastPathComponent))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                done.resume(throwing: error)
            }
        }
    }

    /// Nimmt ein auf der Seite verstecktes Wallpaper dazu. Eingabe: Slug oder Adresse der Detailseite.
    func addSiteWallpaper(_ input: String) async throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = (URL(string: trimmed)?.host != nil ? URL(string: trimmed)?.pathComponents.first { $0 != "/" } : nil) ?? trimmed
        guard Self.isSlug(slug) else {
            throw NSError(domain: "ReeZWallpapers", code: 2, userInfo: [
                NSLocalizedDescriptionKey: L(
                    "That is not a wallpaper name from the site. It is the part after wallpapers.reez.cc/, for example nishiki-interactive-koi-pond.",
                    "Das ist kein Wallpaper-Name der Seite. Gemeint ist der Teil hinter wallpapers.reez.cc/, z. B. nishiki-interactive-koi-pond."
                )
            ])
        }
        try await syncOne(slug)
        if !Settings.extraSlugs.contains(slug) { Settings.extraSlugs.append(slug) }
        var order = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: siteDir.appendingPathComponent("order.json")))) ?? []
        if !order.contains(slug) {
            order.append(slug)
            try? JSONEncoder().encode(order).write(to: siteDir.appendingPathComponent("order.json"), options: .atomic)
        }
        reloadFromDisk()
        return "site/" + slug
    }

    // MARK: Eigene Ordner

    /// Hängt einen Projektordner per Symlink unter local/ ein. Änderungen im Original wirken nach „Neu laden“.
    func addLocalFolder(_ folder: URL) throws -> String {
        let source = folder.resolvingSymlinksInPath()
        guard let project = ProjectFile(root: source), project.kind != nil else {
            throw NSError(domain: "ReeZWallpapers", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L(
                    "This folder has no project.json of a web or video wallpaper.",
                    "In diesem Ordner liegt keine project.json eines Web- oder Video-Wallpapers."
                )
            ])
        }
        var name = source.lastPathComponent
        var n = 2
        while fm.fileExists(atPath: localDir.appendingPathComponent(name).path) {
            if (try? fm.destinationOfSymbolicLink(atPath: localDir.appendingPathComponent(name).path)) == source.path {
                reloadFromDisk()
                return "local/" + name
            }
            name = source.lastPathComponent + " \(n)"
            n += 1
        }
        try fm.createSymbolicLink(at: localDir.appendingPathComponent(name), withDestinationURL: source)
        reloadFromDisk()
        return "local/" + name
    }
}

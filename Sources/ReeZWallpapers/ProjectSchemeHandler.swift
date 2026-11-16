import Foundation
import UniformTypeIdentifiers
import WebKit

/// Liefert Projektordner unter reezwp://<host>/<pfad> an die WebViews aus.
///
/// Über file:// würden fetch(), Module und Schriften je nach Wallpaper an Ursprungsregeln scheitern; mit eigenem
/// Schema hat jedes Wallpaper einen sauberen Ursprung, ohne dass ein lokaler Webserver einen Port öffnet.
final class ProjectSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "reezwp"

    private var roots: [String: URL] = [:]

    func register(_ wallpaper: Wallpaper) {
        roots[wallpaper.host] = wallpaper.root.resolvingSymlinksInPath()
    }

    static func url(for wallpaper: Wallpaper) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = wallpaper.host
        parts.path = "/" + wallpaper.entry
        return parts.url
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let host = url.host, let root = roots[host] else {
            return respond(task, status: 404)
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        // Symlinks auflösen und erst dann prüfen: nichts außerhalb des Projektordners ausliefern
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return respond(task, status: 404)
        }

        var headers = [
            "Content-Type": Self.mimeType(for: file),
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache",
            "Access-Control-Allow-Origin": "*",
        ]
        // Bereichsanfragen: Audio- und Videodateien werden stückweise geholt
        if let header = task.request.value(forHTTPHeaderField: "Range"), let range = Self.parseRange(header, length: data.count) {
            let slice = data.subdata(in: range)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            headers["Content-Length"] = String(slice.count)
            return respond(task, status: 206, headers: headers, body: slice)
        }
        headers["Content-Length"] = String(data.count)
        respond(task, status: 200, headers: headers, body: data)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Antworten gehen in einem Rutsch raus, es gibt nichts abzubrechen.
    }

    private func respond(_ task: WKURLSchemeTask, status: Int, headers: [String: String] = [:], body: Data = Data()) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return task.didFailWithError(URLError(.badServerResponse))
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    private static func parseRange(_ header: String, length: Int) -> Range<Int>? {
        guard length > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        if spec[0].isEmpty {
            // „-500“: die letzten 500 Bytes
            guard let suffix = Int(spec[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(spec[0]), start < length else { return nil }
        let end = min(Int(spec[1]) ?? (length - 1), length - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }

    private static let textTypes: [String: String] = [
        "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
        "json": "application/json", "txt": "text/plain", "svg": "image/svg+xml", "xml": "application/xml",
        "vert": "text/plain", "frag": "text/plain", "glsl": "text/plain",
    ]

    private static func mimeType(for file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        if let text = textTypes[ext] { return text + "; charset=utf-8" }
        if ext == "wasm" { return "application/wasm" }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

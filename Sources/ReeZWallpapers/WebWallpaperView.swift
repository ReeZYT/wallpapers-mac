import AppKit
import WebKit

/// Ein Web-Wallpaper in einer WKWebView, mit der Schnittstelle, die Wallpaper Engine den Seiten sonst gibt.
final class WebWallpaperView: NSView, WallpaperContent, WKNavigationDelegate {
    private let wallpaper: Wallpaper
    private let webView: WKWebView
    private var loaded = false
    private var paused = false
    private var fpsLimit: Int
    /// Aktueller Medienstand für eine frisch geladene Seite.
    private let mediaSnapshot: () -> [(String, [String: Any])]

    init(wallpaper: Wallpaper, scheme: ProjectSchemeHandler, fpsLimit: Int, frame: NSRect, mediaSnapshot: @escaping () -> [(String, [String: Any])]) {
        self.wallpaper = wallpaper
        self.fpsLimit = fpsLimit
        self.mediaSnapshot = mediaSnapshot
        scheme.register(wallpaper)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(scheme, forURLScheme: ProjectSchemeHandler.scheme)
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(
            WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        // Schwarz statt weißem Aufblitzen, bis die Seite zeichnet
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .black
        if #available(macOS 13.3, *) {
            // Safari → Entwickler zeigt das Wallpaper im Web Inspector
            webView.isInspectable = true
        }
        addSubview(webView)

        if let url = ProjectSchemeHandler.url(for: wallpaper) {
            webView.load(URLRequest(url: url))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("nicht aus einem Nib")
    }

    // MARK: WallpaperContent

    func setPaused(_ paused: Bool) {
        self.paused = paused
        run("window.__reez&&window.__reez.setPaused(\(paused))")
    }

    func setFPSLimit(_ fps: Int) {
        fpsLimit = fps
        run("window.__reez&&window.__reez.props(null,{fps:\(fps)})")
    }

    func mouse(_ type: String, x: CGFloat, y: CGFloat, buttons: Int) {
        run("window.__reez&&window.__reez.mouse('\(type)',\(String(format: "%.1f", x)),\(String(format: "%.1f", y)),\(buttons))")
    }

    func media(_ kind: String, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        run("window.__reez&&window.__reez.send('\(kind)',\(String(decoding: data, as: UTF8.self)))")
    }

    private func run(_ script: String) {
        guard loaded else { return }
        webView.evaluateJavaScript(script + ";0", completionHandler: nil)
    }

    func diagnose(force: Bool, completion: @escaping ([String: Any]) -> Void) {
        guard loaded else { return completion(["loaded": false]) }
        if force {
            // Nur für die Messung: als sichtbar behandeln, obwohl z. B. der Sperrbildschirm davor liegt
            setOcclusionDetection(false)
            run("window.__reez&&window.__reez.setPaused(false)")
        }
        // Zählt eine Sekunde lang gezeichnete Bilder und Mausereignisse, die bei der Seite ankommen
        let script = """
        return await new Promise(function (resolve) {
          var frames = 0, moves = 0, clicks = 0, t0 = performance.now(), finished = false;
          var onMove = function () { moves++; }, onClick = function () { clicks++; };
          window.addEventListener('mousemove', onMove); window.addEventListener('click', onClick);
          function done() {
            if (finished) return; finished = true;
            window.removeEventListener('mousemove', onMove); window.removeEventListener('click', onClick);
            var r = window.__reez || {}, l = r.listeners || {};
            resolve(JSON.stringify({
              readyState: document.readyState, visibility: document.visibilityState, title: document.title,
              viewport: innerWidth + 'x' + innerHeight, devicePixelRatio: devicePixelRatio,
              canvases: Array.from(document.querySelectorAll('canvas')).map(function (c) { return (c.id || '?') + ' ' + c.width + 'x' + c.height; }),
              framesPerSecond: frames, mouseMoves: moves, clicks: clicks,
              propertyListener: !!window.wallpaperPropertyListener, propertiesApplied: r.propsApplied || 0, paused: !!r.paused,
              audioListeners: (l.audio || []).length, mediaListeners: (l.properties || []).length,
              media: (function (m) {
                return {
                  enabled: m.status ? !!m.status.enabled : null, title: m.properties ? m.properties.title : null,
                  artist: m.properties ? m.properties.artist : null, state: m.playback ? m.playback.state : null,
                  timeline: m.timeline ? Math.round(m.timeline.position) + '/' + Math.round(m.timeline.duration) : null,
                  thumbnailKB: m.thumbnail && m.thumbnail.thumbnail ? Math.round(m.thumbnail.thumbnail.length / 1024) : 0,
                  colors: m.thumbnail ? [m.thumbnail.primaryColor, m.thumbnail.secondaryColor, m.thumbnail.textColor] : null
                };
              })(r.last || {}),
              errors: r.errors || []
            }));
          }
          function tick() { frames++; if (performance.now() - t0 < 1000) requestAnimationFrame(tick); else done(); }
          requestAnimationFrame(tick);
          setTimeout(done, 1600);
        });
        """
        let start = { [self] in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [self] result in
                var info: [String: Any] = ["loaded": true]
                switch result {
                case .success(let value):
                    if let text = value as? String, let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        info.merge(json) { _, new in new }
                    }
                case .failure(let error):
                    info["scriptError"] = String(describing: error)
                }
                let finish = { [self] in
                    if force {
                        setOcclusionDetection(true)
                        if paused { run("window.__reez&&window.__reez.setPaused(true)") }
                    }
                    completion(info)
                }
                finish()
            }
            if force {
                let x = bounds.width / 2, y = bounds.height / 2
                mouse("move", x: x - 40, y: y, buttons: 0)
                mouse("move", x: x, y: y, buttons: 0)
                mouse("down", x: x, y: y, buttons: 1)
                mouse("up", x: x, y: y, buttons: 0)
            }
        }
        // Nach dem Aufwecken kurz warten, bis das Wallpaper wieder läuft
        if force { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: start) } else { start() }
    }

    /// WebKit hält Seiten in verdeckten Fenstern an. Für die Diagnose lässt sich das abschalten (interne Methode,
    /// wird nur dort benutzt und ist optional: fehlt sie, bleibt alles wie es ist).
    private func setOcclusionDetection(_ enabled: Bool) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, enabled)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        // Wie Wallpaper Engine nach dem Laden: erst allgemeine, dann alle eigenen Einstellungen übergeben
        let project = ProjectFile(root: wallpaper.root)
        let overrides = Settings.propertyOverrides[wallpaper.id] ?? [:]
        let user = project?.userProperties(overrides: overrides) ?? [:]
        let json = (try? JSONSerialization.data(withJSONObject: user)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        run("window.__reez&&window.__reez.props(\(json),{fps:\(fpsLimit)})")
        if paused { run("window.__reez&&window.__reez.setPaused(true)") }
        for (kind, payload) in mediaSnapshot() {
            media(kind, payload)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Ein Wallpaper bleibt in seinem Projektordner; Links nach außen öffnen nichts
        let scheme = action.request.url?.scheme
        decisionHandler(scheme == ProjectSchemeHandler.scheme || scheme == "about" ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Der Web-Prozess wurde beendet (z. B. Speicherdruck): neu laden statt schwarz bleiben
        loaded = false
        webView.reload()
    }

    // MARK: Brücke zur Seite

    /// Läuft vor den Skripten des Wallpapers. Stellt die Funktionen bereit, die Wallpaper Engine in die Seite legt:
    /// Einstellungen (wallpaperPropertyListener) bekommen echte Werte, die Medien-Listener den laufenden Titel aus
    /// `MediaCenter`. Der Audio-Listener wird angenommen und aufbewahrt, aber noch nicht bedient: die Wallpaper
    /// verhalten sich wie in Wallpaper Engine ohne Tonsignal, statt in ihren Browser-Vorschaumodus zu fallen.
    private static let bridge = #"""
    (function () {
      'use strict';
      if (window.__reez) return;

      var listeners = { audio: [], status: [], properties: [], thumbnail: [], playback: [], timeline: [] };
      var last = {};
      function register(kind) {
        return function (fn) {
          if (typeof fn !== 'function') return;
          listeners[kind].push(fn);
          if (last[kind] !== undefined) setTimeout(function () { try { fn(last[kind]); } catch (e) { /* weiter */ } }, 0);
        };
      }
      window.wallpaperRegisterAudioListener = register('audio');
      window.wallpaperRegisterMediaStatusListener = register('status');
      window.wallpaperRegisterMediaPropertiesListener = register('properties');
      window.wallpaperRegisterMediaThumbnailListener = register('thumbnail');
      window.wallpaperRegisterMediaPlaybackListener = register('playback');
      window.wallpaperRegisterMediaTimelineListener = register('timeline');
      window.wallpaperMediaIntegration = { PLAYBACK_STOPPED: 0, PLAYBACK_PLAYING: 1, PLAYBACK_PAUSED: 2 };

      var errors = [];
      window.addEventListener('error', function (e) {
        if (errors.length < 20) errors.push((e.message || 'error') + ' @ ' + String(e.filename || '').split('/').pop() + ':' + (e.lineno || 0));
      });
      window.addEventListener('unhandledrejection', function (e) {
        if (errors.length < 20) errors.push('unhandled rejection: ' + String(e.reason && e.reason.message || e.reason));
      });

      var inside = false, downTarget = null;
      function fire(target, type, x, y, buttons, bubbles) {
        var init = {
          bubbles: bubbles !== false, cancelable: true, composed: true, view: window,
          clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: buttons
        };
        try {
          if (type.indexOf('pointer') === 0) {
            init.pointerId = 1; init.pointerType = 'mouse'; init.isPrimary = true;
            target.dispatchEvent(new PointerEvent(type, init));
          } else {
            target.dispatchEvent(new MouseEvent(type, init));
          }
        } catch (e) { /* Fehler im Wallpaper sollen die Weitergabe nicht stoppen */ }
      }

      var host = window.__reez = {
        listeners: listeners,
        last: last,
        errors: errors,
        propsApplied: 0,
        paused: false,
        send: function (kind, payload) {
          if (!listeners[kind]) return;
          last[kind] = payload;
          listeners[kind].forEach(function (fn) { try { fn(payload); } catch (e) { /* weiter mit dem nächsten */ } });
        },
        props: function (user, general) {
          var l = window.wallpaperPropertyListener;
          if (!l) return;
          try { if (general && l.applyGeneralProperties) l.applyGeneralProperties(general); } catch (e) { /* weiter */ }
          try { if (user && l.applyUserProperties) { l.applyUserProperties(user); host.propsApplied = Object.keys(user).length; } } catch (e) { errors.push('applyUserProperties: ' + e.message); }
        },
        setPaused: function (paused) {
          host.paused = !!paused;
          var l = window.wallpaperPropertyListener;
          try { if (l && l.setPaused) l.setPaused(!!paused); } catch (e) { /* weiter */ }
        },
        /* Die Fenster liegen hinter den Desktop-Symbolen und bekommen keine echten Mausereignisse.
           Die App meldet Position und Klicks, hier werden daraus Ereignisse wie im Browser. */
        mouse: function (type, x, y, buttons) {
          if (type === 'leave') {
            if (!inside) return;
            inside = false;
            if (downTarget) { fire(downTarget, 'pointerup', x, y, 0); fire(downTarget, 'mouseup', x, y, 0); downTarget = null; }
            fire(document.documentElement, 'mouseout', x, y, 0);
            fire(document, 'mouseleave', x, y, 0, false);
            return;
          }
          var el = document.elementFromPoint(x, y) || document.documentElement;
          if (!inside) { inside = true; fire(document, 'mouseenter', x, y, buttons, false); }
          if (type === 'move') {
            fire(el, 'pointermove', x, y, buttons); fire(el, 'mousemove', x, y, buttons);
          } else if (type === 'down') {
            downTarget = el;
            fire(el, 'pointerdown', x, y, buttons); fire(el, 'mousedown', x, y, buttons);
          } else if (type === 'up') {
            fire(el, 'pointerup', x, y, buttons); fire(el, 'mouseup', x, y, buttons);
            if (downTarget === el) fire(el, 'click', x, y, buttons);
            downTarget = null;
          }
        }
      };
    })();
    """#
}

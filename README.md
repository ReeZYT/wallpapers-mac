# ReeZ Wallpapers (macOS)

Zeigt die Wallpaper von [wallpapers.reez.cc](https://wallpapers.reez.cc) als Schreibtischhintergrund auf allen
Monitoren eines Macs gleichzeitig. Eine App, ein Symbol in der Menüleiste, kein Dock-Symbol. Gedacht als Ersatz für
Wallpaper Engine, das es für macOS nicht gibt.

## Bauen und installieren

```bash
scripts/build-app.sh --install
```

Baut mit SwiftPM (Xcode-Kommandozeilenwerkzeuge reichen), bündelt `build/ReeZ Wallpapers.app`, kopiert sie nach
`/Applications` und startet sie neu. Ohne `--install` wird nur gebaut. Signiert wird ad hoc, das reicht für den eigenen
Mac. Das Symbol entsteht mit `swift scripts/make-icon.swift` (liegt fertig in `Resources/AppIcon.icns`).

Ab macOS 13. Autostart schaltet man im Menü mit „Beim Anmelden starten“ ein.

## Woher die Wallpaper kommen

Die Seite hat keine eigene Schnittstelle, aber alles Nötige ist öffentlich:

| Adresse | Inhalt |
| --- | --- |
| `/sitemap.xml` | Liste der veröffentlichten Wallpaper (Slugs), in der Reihenfolge der Startseite |
| `/files/<slug>/meta.json` | Titel, Typ, Name des ZIPs |
| `/files/<slug>/<slug>.zip` | der Wallpaper-Engine-Projektordner |

Die App gleicht beim Start und alle sechs Stunden ab (oder im Menü: „Jetzt mit wallpapers.reez.cc abgleichen“). ZIPs
werden nur neu geladen, wenn sich ihr ETag geändert hat, und laufen danach lokal, also auch ohne Netz. Was die Seite
nicht mehr listet, verschwindet auch aus der App.

Alles liegt unter `~/Library/Application Support/ReeZ Wallpapers/`:

```
site/<slug>/     meta.json, state.json (ETag), project/ (entpackt)
site/order.json  Reihenfolge der Seite
local/<name>/    eigene Projektordner oder Symlinks darauf
```

- **Auf der Seite versteckte Wallpaper** stehen nicht in der Sitemap. Menü → Eigene Wallpaper → „Verstecktes Wallpaper
  von der Seite …“ nimmt eines über seinen Slug dazu; es wird danach wie die anderen abgeglichen.
- **Eigene Ordner** (noch nicht hochgeladen, in Arbeit): Menü → Eigene Wallpaper → „Projektordner hinzufügen …“ legt
  einen Symlink unter `local/` an. Änderungen am Original zeigt „Wallpaper neu laden“.

Unterstützt werden die Typen `web` und `video` aus `project.json`. Szenen und Programme kann nur Wallpaper Engine.

## Wie es anzeigt

- **Ein Fenster je Monitor** (`DisplayManager.swift`) auf der Ebene des Schreibtischhintergrunds
  (`kCGDesktopWindowLevel`): über dem macOS-Hintergrundbild, unter den Desktop-Symbolen, Widgets und allen Fenstern.
  Die Fenster sind auf allen Spaces und bleiben in Mission Control stehen. Die Auswahl gilt für alle Monitore oder je
  Monitor (gemerkt über die Display-UUID).
- **Web-Wallpaper** laufen in einer `WKWebView` und werden über das eigene Schema `reezwp://<wallpaper>/…` aus dem
  Projektordner ausgeliefert (`ProjectSchemeHandler.swift`), nicht über `file://` und ohne lokalen Server.
- **Video-Wallpaper** spielt `AVPlayerLooper` nahtlos, stumm und bildfüllend.
- **Schnittstelle von Wallpaper Engine** (`WebWallpaperView.swift`, Skript `bridge`): Nach dem Laden gehen alle
  Einstellungen aus `project.json` mit ihren Standardwerten an `wallpaperPropertyListener.applyUserProperties`, die
  Bildraten-Grenze an `applyGeneralProperties`, Pausen an `setPaused`. Die Audio- und Medien-Funktionen
  (`wallpaperRegisterAudioListener`, `wallpaperRegisterMedia…Listener`) sind vorhanden und merken sich die Listener,
  liefern aber noch nichts. Die Wallpaper verhalten sich damit wie in Wallpaper Engine ohne laufende Musik.
- **Maus** (`MouseForwarder.swift`): Die Fenster liegen hinter den Desktop-Symbolen und bekommen keine Mausereignisse.
  Ein globaler Beobachter meldet Bewegung und Linksklicks; liegt unter dem Zeiger der freie Desktop, erzeugt die Brücke
  daraus `mousemove`, `mousedown`, `mouseup`, `click` und die Pointer-Ereignisse in der Seite. macOS verlangt dafür
  keine Freigabe.
- **Pause**: von Hand im Menü, außerdem von allein, wenn ein Monitor ganz von Fenstern verdeckt ist, die Monitore
  schlafen oder der Bildschirm gesperrt ist.

Abweichende Einstellungen eines Wallpapers lassen sich schon speichern, eine Oberfläche dafür gibt es noch nicht:

```bash
defaults write cc.reez.wallpapers propertyOverrides -dict-add "site/nishiki-interactive-koi-pond" '{ fishcount = 20; clock = 1; }'
```

Danach „Wallpaper neu laden“. Die Schlüssel stehen in der `project.json` des Wallpapers unter `general.properties`.

## Diagnose

```bash
"/Applications/ReeZ Wallpapers.app/Contents/MacOS/ReeZWallpapers" --diagnose /tmp/reez-diagnose
```

Fragt die laufende App und gibt je Monitor aus: Wallpaper, Fensterebene, sichtbar oder pausiert, gezeichnete Bilder pro
Sekunde, angekommene Mausereignisse und Skriptfehler der Seite. `--force` lässt die Wallpaper für die Messung laufen,
auch wenn sie gerade verdeckt sind, und schickt Testklicks in die Bildmitte. Ein Bild eines Fensters macht
`screencapture -l <windowNumber> bild.png` (die Nummer steht im Bericht). Web-Wallpaper lassen sich außerdem in Safari
unter Entwickler → ReeZ Wallpapers im Web Inspector öffnen.

## Was noch fehlt

- Laufender Titel und Cover (Medienintegration) und Musikreaktion (Audiodaten): die Brücke ist vorbereitet, es fehlt
  die Quelle auf macOS-Seite.
- Eine Oberfläche für die Einstellungen der Wallpaper.
- Rechtsklick, Mausrad und Tastatur werden nicht weitergegeben.

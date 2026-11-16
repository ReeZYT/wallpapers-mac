# ReeZ Wallpapers (macOS)

Zeigt die Wallpaper von [wallpapers.reez.cc](https://wallpapers.reez.cc) als Schreibtischhintergrund auf allen
Monitoren eines Macs gleichzeitig. Eine App, ein Symbol in der Menüleiste, kein Dock-Symbol. Gedacht als Ersatz für
Wallpaper Engine, das es für macOS nicht gibt.

## Bauen und installieren

```bash
scripts/build-app.sh --install
```

Baut mit SwiftPM (Xcode-Kommandozeilenwerkzeuge reichen) für Apple Silicon und Intel in einer Datei, bündelt
`build/ReeZ Wallpapers.app`, kopiert sie nach `/Applications` und startet sie neu. Ohne `--install` wird nur gebaut.
Signiert wird ad hoc. Das Symbol entsteht mit `swift scripts/make-icon.swift` (liegt fertig in `Resources/AppIcon.icns`).

Ab macOS 13. Autostart schaltet man im Menü mit „Beim Anmelden starten“ ein. Die Oberfläche ist Englisch, auf deutsch
eingestellten Macs Deutsch (`L10n.swift`: jeder Text steht als `L("English", "Deutsch")` an Ort und Stelle).

## Weitergeben

Die App steht als Download auf https://wallpapers.reez.cc/mac/ (Repo `ReeZYT/wallpapers`, lokal `Privat/lab`).

```bash
scripts/package.sh
```

packt `build/ReeZ-Wallpapers-mac.zip` und gibt Version, Größe und SHA-256 als JSON aus. Neue Fassung veröffentlichen:

1. Version in `Resources/Info.plist` erhöhen (`CFBundleShortVersionString`).
2. `scripts/package.sh > build/mac-app.json`
3. Im Seiten-Repo: ZIP nach `public/downloads/`, JSON nach `src/lib/mac-app.json`, dort `npm run check && npm run build
   && npm test`, committen und nach `main` bringen (deployt automatisch).

Installierte Apps fragen beim Abgleich `/mac/version.json` ab und zeigen im Menü einen Update-Hinweis, sobald dort eine
höhere Version steht. Ein automatisches Update gibt es nicht.

Die App ist nicht von Apple beglaubigt (notarisiert), dafür bräuchte es ein Apple-Entwicklerkonto. Auf fremden Macs
blockiert macOS deshalb den ersten Start; die Download-Seite erklärt den Weg über Systemeinstellungen → Datenschutz &
Sicherheit → „Dennoch öffnen“. Geprüft ist die App auf macOS 26 mit Apple Silicon, die Intel-Fassung über Rosetta.

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
  von der Seite …“ nimmt eines über seinen Slug dazu; es wird danach wie die anderen abgeglichen. Der Eintrag erscheint
  nur, wenn schon eines eingetragen ist oder das Menü mit gedrückter Wahltaste (⌥) geöffnet wird.
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
  Bildraten-Grenze an `applyGeneralProperties`, Pausen an `setPaused`. Die Medien-Listener
  (`wallpaperRegisterMedia…Listener`) bekommen den laufenden Titel, siehe unten. `wallpaperRegisterAudioListener` ist
  vorhanden und merkt sich die Listener, liefert aber noch nichts: die Wallpaper verhalten sich wie in Wallpaper
  Engine ohne Tonsignal.
- **Maus** (`MouseForwarder.swift`): Die Fenster liegen hinter den Desktop-Symbolen und bekommen keine Mausereignisse.
  Ein globaler Beobachter meldet Bewegung und Linksklicks; liegt unter dem Zeiger der freie Desktop, erzeugt die Brücke
  daraus `mousemove`, `mousedown`, `mouseup`, `click` und die Pointer-Ereignisse in der Seite. macOS verlangt dafür
  keine Freigabe.
- **Pause**: von Hand im Menü, außerdem von allein, wenn ein Monitor ganz von Fenstern verdeckt ist, die Monitore
  schlafen oder der Bildschirm gesperrt ist.

## Laufender Titel

`MediaCenter.swift` ist das Gegenstück zur Medienintegration von Wallpaper Engine: Titel, Interpret, Album, Cover,
Wiedergabezustand und Position gehen an die Medien-Listener der Wallpaper (Mixtape, Neon Torii, die Neko-Wallpaper).
Abschalten lässt es sich im Menü („Laufenden Titel an Wallpaper geben“), dort steht auch der erkannte Titel.

- **Quelle:** Unter Windows liest Wallpaper Engine den Titel systemweit. macOS gibt diese Auskunft seit 15.4 nur noch
  an Apples eigene Programme. **Spotify** und **Apple Music** melden Titelwechsel, Start und Pause aber selbst über
  verteilte Mitteilungen (`com.spotify.client.PlaybackStateChanged`, `com.apple.Music.playerInfo`); dafür braucht es
  keine Freigabe. Andere Quellen (YouTube im Browser, andere Player) kommen nicht an.
- **Cover:** Spotify nennt es in der Mitteilung nicht. Die App fragt zum Titel Spotifys öffentliche oEmbed-Auskunft
  (`open.spotify.com/oembed`) und lädt das Bild in 640 px von Spotifys Bildserver. Das ist die einzige Anfrage nach
  außen neben dem Abgleich mit der Seite. Apple Music liefert kein Cover und keine Position; die Wallpaper zeichnen
  dann ihr eigenes.
- **Grenze:** Die Player melden nur Änderungen. Startet die App mitten in einem Titel, erscheint er beim nächsten
  Titelwechsel oder nach Pause und Weiter.
- Songtexte in Mixtape holt das Wallpaper selbst bei lrclib.net, wie unter Windows.

Zum Testen ohne Player genügt eine nachgestellte Mitteilung, z. B. per Swift-Skript mit
`DistributedNotificationCenter.default().postNotificationName(...)` und den Feldern `Player State`, `Name`, `Artist`,
`Album`, `Duration` (ms), `Playback Position` (s), `Track ID`. Was bei der Seite ankommt, zeigt `--diagnose` unter `media`.

## Sperrbildschirm

Den Sperrbildschirm zeichnet macOS selbst über allen Fenstern; fremde Apps kommen dort nicht hin, und bewegte
Hintergründe können nur Apples eigene Erweiterungen (`WallpaperExtensionKit` ist privat). Er zeigt aber immer das
macOS-Hintergrundbild des jeweiligen Monitors. Der Schalter „Sperrbildschirm angleichen“ (`LockScreenMatcher.swift`,
standardmäßig aus) trägt dort je Monitor ein Standbild des laufenden Wallpapers ein:

- Web-Wallpaper: Schnappschuss der Seite in voller Auflösung. Seiten mit 3D-Transformationen bildet
  `WKWebView.takeSnapshot` falsch ab; sie bekommen das Titelbild der Seite (`site/<slug>/cover.*`, wird beim Abgleich
  mitgeladen), eigene Ordner ihre Vorschau.
- Video-Wallpaper: ein Bild vom Anfang der Schleife.
- Die Bilder liegen unter `~/Library/Application Support/ReeZ Wallpapers/stills/`. Das vorher eingestellte
  Hintergrundbild wird je Monitor gemerkt und beim Ausschalten zurückgestellt (ein bewegter Apple-Hintergrund kommt
  dabei als sein Standbild zurück und muss in den Systemeinstellungen neu gewählt werden).
- macOS merkt sich das Hintergrundbild je Space; die App trägt es deshalb bei jedem Space-Wechsel nach.

### Bewegt beim Sperren: der Bildschirmschoner

Versuche am 16.11.2026 (macOS 26.6) haben gezeigt: Über dem Sperrbildschirm zeigt macOS keine Fenster anderer
Programme, auf keiner Fensterebene. Ein Bildschirmschoner, der erst nach einer direkten Sperre gestartet wird, gilt
für macOS zwar als laufend, wird aber weder geladen noch gezeigt. Bewegt ist dort nur Apples eigener Hintergrund.

Ein Bildschirmschoner, der *vor* der Sperre läuft, bleibt dagegen sichtbar, bis jemand Maus oder Tastatur anfasst.
Deshalb liegt in der App ein Bildschirmschoner (`Sources/ReeZWallpapersSaver`, Bündel unter
`Contents/Resources/ReeZ Wallpapers.saver`), der auf jedem Monitor dasselbe Wallpaper spielt wie die App:

- Menü → „Bildschirmschoner einrichten …“ kopiert ihn nach `~/Library/Screen Savers` und nennt die zwei Einstellungen,
  die nur der Benutzer setzen kann: unter Bildschirmschoner „ReeZ Wallpapers“ wählen, unter Sperrbildschirm
  „Passwort erforderlich nach Beginn des Bildschirmschoners …“ auf „Sofort“.
- Menü → „Sperren – Wallpaper läuft weiter“ (⌃⌥⌘L, systemweit) startet den Bildschirmschoner. Mit „Sofort“ ist der Mac
  damit gesperrt und das Wallpaper läuft weiter.
- Menü → „Sperrtaste (ctrl + cmd + Q) macht das auch“ (standardmäßig aus) übernimmt das Sperr-Kürzel von macOS, das
  auch die Sperrtaste mancher Tastaturen schickt: Ein eigenes Kürzel darauf hat Vorrang vor dem System. Eine
  Sperrtaste muss immer sperren, deshalb fragt die App bei jedem Druck `sysadminctl -screenLock status` ab und löst
  ohne „Sofort“ oder ohne eingerichteten Bildschirmschoner die echte Sperre aus (`SACLockScreenImmediate`, intern).
- Die Touch-ID-Taste lässt sich nicht abfangen; dort zeigt macOS immer seinen Sperrbildschirm.
- Solange der Bildschirmschoner läuft, ruhen die Fenster der App.
- Der Bildschirmschoner läuft in der Sandbox von macOS (`legacyScreenSaver`), darf aber die ganze Platte lesen. Er
  liest `saver.json` (Auswahl je Monitor, Pfade; die App schreibt sie bei jeder Änderung) und die Projektordner direkt
  aus `~/Library/Application Support/ReeZ Wallpapers`. Seine Ansichten sind dieselben wie in der App: die gemeinsamen
  Quelldateien sind per Symlink in das zweite SwiftPM-Ziel eingehängt.
- WebKit hält Seiten in verdeckten Fenstern an, und die Fenster eines Bildschirmschoners gelten ihm als verdeckt
  (macOS zeigt sie über einen eigenen Prozess an). Im Bildschirmschoner ist diese Erkennung deshalb abgeschaltet;
  sonst sieht man nur die Hintergrundfarbe der Seite.
- Titel und Cover, Maus und Pausen gibt es im Bildschirmschoner nicht. Was er und die Kürzel tun, steht im
  Systemprotokoll (`subsystem == "cc.reez.wallpapers"` für die App):
  `/usr/bin/log show --last 5m --predicate 'subsystem == "cc.reez.wallpapers.saver"'`.

Was als Standbild herauskäme, zeigt `--diagnose <ordner> --force`: Es legt die Bilder in den Ordner, ohne das
Hintergrundbild anzufassen, und nennt je Monitor das gerade eingestellte macOS-Bild.

## Einstellungen der Wallpaper

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

- Musikreaktion (Audiodaten für `wallpaperRegisterAudioListener`): bräuchte die Freigabe „Systemaudio aufnehmen“.
- Laufender Titel aus anderen Quellen als Spotify und Apple Music.
- Eine Oberfläche für die Einstellungen der Wallpaper.
- Rechtsklick, Mausrad und Tastatur werden nicht weitergegeben.
- Titel und Cover im Bildschirmschoner.

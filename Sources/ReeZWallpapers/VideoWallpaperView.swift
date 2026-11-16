import AppKit
import AVFoundation

/// Ein Video-Wallpaper: nahtlose Schleife ohne Ton, bildfüllend.
final class VideoWallpaperView: NSView, WallpaperContent {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private let videoURL: URL

    init(wallpaper: Wallpaper, frame: NSRect) {
        videoURL = wallpaper.root.appendingPathComponent(wallpaper.entry)
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true

        let item = AVPlayerItem(url: videoURL)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        // Ein Hintergrundvideo darf den Ruhezustand der Monitore nicht verhindern
        player.preventsDisplaySleepDuringVideoPlayback = false

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(playerLayer)
        player.play()
    }

    required init?(coder: NSCoder) {
        fatalError("nicht aus einem Nib")
    }

    func setPaused(_ paused: Bool) {
        if paused { player.pause() } else { player.play() }
    }

    func setFPSLimit(_ fps: Int) {
        // Videos laufen mit ihrer eigenen Bildrate.
    }

    func mouse(_ type: String, x: CGFloat, y: CGFloat, buttons: Int) {
        // Videos reagieren nicht auf die Maus.
    }

    func media(_ kind: String, _ payload: [String: Any]) {
        // Videos zeigen keinen Titel an.
    }

    func still(completion: @escaping (Data?) -> Void) {
        // Ein Bild vom Anfang der Schleife, in voller Auflösung des Videos
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.5, preferredTimescale: 600)) { image, _, _ in
            let data = image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) }
            DispatchQueue.main.async { completion(data) }
        }
    }

    func diagnose(force: Bool, completion: @escaping ([String: Any]) -> Void) {
        let item = player.currentItem
        completion([
            "status": item?.status == .readyToPlay ? "readyToPlay" : (item?.error?.localizedDescription ?? "not ready"),
            "rate": player.rate,
            "seconds": player.currentTime().seconds,
            "size": item.map { "\(Int($0.presentationSize.width))x\(Int($0.presentationSize.height))" } ?? "",
            "loops": looper?.loopCount ?? 0,
        ])
    }
}

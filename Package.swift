// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReeZWallpapers",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ReeZWallpapers", targets: ["ReeZWallpapers"]),
        // Der Bildschirmschoner als ladbare Bibliothek; scripts/build-app.sh packt sie in ein .saver-Bündel
        .library(name: "ReeZWallpapersSaver", type: .dynamic, targets: ["ReeZWallpapersSaver"]),
    ],
    targets: [
        .executableTarget(name: "ReeZWallpapers", path: "Sources/ReeZWallpapers"),
        // Teilt sich die Ansichten mit der App: die gemeinsamen Dateien sind als Symlinks eingehängt
        .target(name: "ReeZWallpapersSaver", path: "Sources/ReeZWallpapersSaver"),
    ]
)

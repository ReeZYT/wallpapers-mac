# ReeZ Wallpapers for Mac

Wallpaper Engine doesn't exist for macOS. This is how I run my wallpapers from
[wallpapers.reez.cc](https://wallpapers.reez.cc) on my Mac anyway.

It's a menu bar app. Click the display icon, pick a wallpaper, and it plays behind your desktop icons on every
monitor. If you'd rather have a different one on each monitor, the menu does that too. The wallpapers come from the
site and stay up to date on their own, so there is nothing to download by hand.

The wallpapers react to your mouse like they do in Wallpaper Engine, and the ones with a music display show what's
playing in Spotify or Apple Music.

You can also lock your Mac from the app's menu. A screen saver takes over then, and the wallpaper keeps running until
you touch the mouse or keyboard.

Only web and video wallpapers work. Scene wallpapers need the real Wallpaper Engine.

## Requirements

- macOS 13 or newer
- Apple silicon or Intel

It runs on my Mac with macOS 26 and Apple silicon. Intel and older systems should work, but nobody has tried them on
real hardware yet.

## Installation

1. Download the ZIP from [wallpapers.reez.cc/mac](https://wallpapers.reez.cc/mac/) and unpack it.
2. Move ReeZ Wallpapers to your Applications folder and open it.
3. macOS refuses the first start because the app isn't notarized by Apple. Open System Settings, go to
   Privacy & Security, scroll down and click "Open Anyway".
4. Click the display icon in the menu bar and choose a wallpaper.

If it should start with your Mac, turn on "Start at login" in the same menu.

### Build it yourself

You need the Xcode command line tools, nothing else.

```bash
git clone https://github.com/ReeZYT/wallpapers-mac.git
cd wallpapers-mac
scripts/build-app.sh --install
```

Notes on how it works are in [docs/development.md](docs/development.md). They are in German.

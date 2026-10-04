# NanoTower

**A PC tower in your pocket.**

Plug a USB-C iPhone into a monitor or TV, or send it over AirPlay, and NanoTower shows its own desktop on the big screen instead of mirroring your phone. The iPhone becomes the computer underneath, and it stays free to act as a trackpad, a controller, or a black screen.

> **Status:** early prototype. The external-display foundation works over both USB-C and AirPlay. The window manager and apps are next.

---

## Why

Samsung, Pixel and Motorola and certain android devices have a desktop mode built-in. iPhone just has mirroring. NanoTower builds its own desktop inside an app: windows, a dock, and apps that run on the external display while the phone does the work.

It is **not** an iOS replacement and does not run other iOS apps. It is a self-contained desktop environment that happens to live on your phone.

## Current features

- [x] Detects an external display (USB-C / HDMI adapter or AirPlay)
- [x] Renders a separate desktop UI on the external display, not a mirror
- [x] One code path for wired and wireless
- [x] AirPlay route picker inside the app
- [x] Desktop state survives disconnect and reconnect

## Roadmap

- [ ] Window manager (drag, resize, minimize, maximize, close)
- [ ] Dock / taskbar and wallpaper
- [ ] Mouse and trackpad cursor (Bluetooth mouse, plus iPhone as trackpad)
- [ ] Keyboard shortcuts (Cmd+Space, Cmd+Tab, Cmd+W, ...)
- [ ] iPhone black-screen mode (app-controlled)
- [ ] Apps: Browser (WebKit with content blocking), Notes/Editor, Files, Terminal (sandboxed), Photos, Music
- [ ] Universal launcher / search
- [ ] Settings, themes, lock screen

## Requirements

- Xcode 16 or later
- iPhone with a USB-C port (iPhone 15 or newer) for wired output
- A USB-C to HDMI adapter or USB-C display cable, **or** an AirPlay receiver (Apple TV or AirPlay-capable TV) on the same Wi-Fi network
- iOS 17+

## Getting started

```bash
git clone https://github.com/<your-username>/nanotower.git
cd nanotower
open NanoTower.xcodeproj
```

1. Select your iPhone as the run destination.
2. In **Signing & Capabilities**, choose your own Team (a free Apple ID works for personal devices).
3. Run the app on the phone.
4. Connect a display by cable, or tap the AirPlay button in the app and choose a receiver.

The simulator can fake an external display under **I/O → External Displays**, but test on real hardware early.

## How it works

iOS gives an app a separate `UIWindowScene` for an external display, but only if the app declares that scene role in its manifest. Without it, iOS falls back to mirroring.

- `Info.plist` declares `UIWindowSceneSessionRoleExternalDisplayNonInteractive` and enables multiple scenes.
- `AppDelegate` returns a scene configuration for the external role.
- `ExternalSceneDelegate` builds a window hosting the SwiftUI `DesktopView`.
- A `UIScene.willConnectNotification` fallback builds the window manually if the delegate isn't called.
- Shared state lives in singletons (`DesktopState`, `DisplayManager`), so the desktop survives disconnects.

### Project structure

```
NanoTower/
├── NanoTowerApp.swift   # App entry point
├── ContentView.swift    # Phone-side UI (status, AirPlay button)
├── Desktop.swift        # Scene setup, shared state, external desktop UI
└── Info.plist           # Scene manifest with the external display role
```

## Known limitations

- iOS does not let a third-party app power off the physical display. "Black screen" mode is an app-controlled black overlay and only works while the app is in the foreground.
- iOS does not allow arbitrary binaries to run, so the terminal will be a sandboxed shell with built-in commands or an interpreter.
- NanoTower cannot host other iOS apps. Every app in the desktop is built in.
- AirPlay adds latency compared to a wired connection.

## Contributing

Issues and pull requests are welcome while the project is small. Please open an issue first for anything large.

## Disclaimer

NanoTower is an independent project and is not affiliated with or endorsed by Apple Inc. or Samsung. iPhone, AirPlay, and DeX are trademarks of their respective owners.

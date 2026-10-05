# NanoTower

**A PC tower in your pocket.**

Plug a USB-C iPhone into a monitor or TV, or send it over AirPlay, and NanoTower shows its own desktop on the big screen instead of mirroring your phone. The iPhone becomes the computer underneath, and it stays free to act as a trackpad, a keyboard, a settings panel, or a black screen.

> **Status:** early prototype. The external display, window manager, dock and six built-in apps work. Expect rough edges, and please report them.

---

## Why

Samsung, Pixel, Motorola and some other Android devices have a desktop mode built in. iPhone just has mirroring. NanoTower builds its own desktop inside an app: windows, a dock, and apps that run on the external display while the phone does the work.

It is **not** an iOS replacement and does not run other iOS apps. It is a self-contained desktop environment that happens to live on your phone.

## Features

**Display**
- [x] Detects an external display (USB-C / HDMI adapter or AirPlay)
- [x] Renders a separate desktop on the external display, not a mirror
- [x] One code path for wired and wireless, with an AirPlay picker in the app
- [x] Auto interface scale that picks a readable size for the connected display, with a manual 70-250% override

**Desktop**
- [x] Window manager: drag, resize, minimize, maximize, close, snap to edges, double-click title bar
- [x] Dock, menu bar with battery and clock, right-click menu, app launcher
- [x] Wallpapers: five presets plus a custom photo
- [x] Window layout, settings and app state are saved and restored on launch

**Input**
- [x] iPhone as a trackpad: tap, hold and drag, two-finger right click, two-finger scroll
- [x] Bluetooth / USB mouse and keyboard
- [x] iPhone on-screen keyboard that types into the desktop
- [x] Shortcuts: Cmd/Opt+Space (launcher), Cmd/Opt+Tab, Cmd+W, Cmd+M, Cmd+Q, Cmd+C, Cmd+V
- [x] Adjustable tracking speed, 5 pointer styles and 9 pointer sizes

**Apps**
- [x] **Browser:** WebKit with tabs-in-place links, address bar, loading bar, homepage and search engine settings, desktop-site toggle, and full-screen video that you can exit (button, Esc, or the player's own control)
- [x] **Files:** sandboxed file manager with folders, rename, delete, text editor and image viewer
- [x] **Terminal:** sandboxed shell with built-in commands (`ls`, `cd`, `cat`, `mkdir`, `rm`, `mv`, `cp`, `echo`, `open`, `neofetch`, ...), history and tab completion
- [x] **Notes** (auto-saved), **Calculator**
- [x] **Settings:** the same sections on the iPhone and on the external screen (display, pointer, wallpaper, browser, system)

**iPhone screen**
- [x] Black screen is a toggle (button, three-finger tap, or Settings), and brightness is always restored when the app leaves the foreground
- [x] Factory reset that erases settings, files, notes, browser data and open windows

## Roadmap

- [ ] Browser: tabs, bookmarks, content blocking
- [ ] Files: import from the iPhone's Files app and Photos, drag and drop
- [ ] Photos and Music apps
- [ ] Themes (light mode, accent colors) and a lock screen
- [ ] More keyboard shortcuts and window tiling
- [ ] Multiple desktops

## Requirements

- Xcode 16 or later
- iPhone with a USB-C port (iPhone 15 or newer) for wired output
- A USB-C to HDMI adapter or USB-C display cable, **or** an AirPlay receiver (Apple TV or AirPlay-capable TV) on the same Wi-Fi network
- iOS 17+

## Getting started

```bash
git clone https://github.com/<your-username>/nanotower.git
cd nanotower
open DeskPhone.xcodeproj
```

1. Select your iPhone as the run destination.
2. In **Signing & Capabilities**, choose your own Team (a free Apple ID works for personal devices).
3. Run the app on the phone.
4. Connect a display by cable, or tap the AirPlay button in the app and choose a receiver.

The simulator can fake an external display under **I/O → External Displays**, but test on real hardware early.

### Using it

- **Trackpad:** tap to click, hold and drag to drag, two-finger tap to right click, two-finger drag to scroll.
- **Settings:** tap the gear on the phone, or open the Settings app on the big screen.
- **Black screen:** tap the moon toggle. Tap it again, or tap with three fingers, to turn the phone screen back on.
- **Browser fullscreen:** use the player's fullscreen button, and leave with the "Exit full screen" button or the Esc key.

## How it works

iOS gives an app a separate `UIWindowScene` for an external display, but only if the app declares that scene role in its manifest. Without it, iOS falls back to mirroring.

- `Info.plist` declares `UIWindowSceneSessionRoleExternalDisplayNonInteractive` and enables multiple scenes.
- `AppDelegate` returns a scene configuration for the external role.
- `ExternalSceneDelegate` builds a window hosting the SwiftUI `DesktopView`.
- A `UIScene.willConnectNotification` fallback builds the window manually if the delegate isn't called.
- The external display is non-interactive, so the desktop draws its own cursor and uses a hotspot system (`.clickable`) for hit-testing instead of normal SwiftUI taps.
- Shared state lives in singletons (`Desktop`, `Settings`, `DisplayManager`, `InputManager`), so the desktop survives disconnects. Settings and window layout are stored in `UserDefaults`; files live in the app's Documents folder.
- Browser fullscreen is implemented with an injected script that emulates the Fullscreen API, because the iPhone's native fullscreen can't be shown on the external display.

### Project structure

```
DeskPhone/
├── DeskPhoneApp.swift   # App entry point
├── ContentView.swift    # Phone-side UI: trackpad, controls, black screen, keyboard
├── Desktop.swift        # External scene setup, AirPlay picker
├── DesktopModel.swift   # Window manager, pointer logic, app registry, layout saving
├── DesktopView.swift    # Windows, dock, menu bar, launcher, cursor
├── InputManager.swift   # Bluetooth / USB mouse and keyboard
├── Settings.swift       # Persistent settings, factory reset, iPhone settings page
├── SettingsApp.swift    # Settings app for the external screen
├── BrowserApp.swift     # Browser and fullscreen support
├── FilesApp.swift       # Files app and sandbox file store
├── TerminalApp.swift    # Sandboxed terminal
├── Apps.swift           # Notes and Calculator
└── Info.plist           # Scene manifest with the external display role
```

## Known limitations

- iOS does not let a third-party app power off the physical display. "Black screen" mode is an app-controlled black overlay with brightness set to zero, and only works while the app is in the foreground.
- iOS does not allow arbitrary binaries to run, so the terminal is a sandboxed shell with built-in commands only.
- NanoTower cannot host other iOS apps. Every app in the desktop is built in.
- The external display is non-interactive, so clicks inside web pages are simulated with JavaScript. Some sites that require a real tap may ignore them.
- AirPlay adds latency compared to a wired connection.

## Contributing

Issues and pull requests are welcome while the project is small. Please open an issue first for anything large.

## Disclaimer

NanoTower is an independent project and is not affiliated with or endorsed by Apple Inc. or Samsung. iPhone, AirPlay, and DeX are trademarks of their respective owners.

import SwiftUI
import UIKit
import Combine

// MARK: - Layout constants

enum Metrics {
    static let titleBar: CGFloat = 32
    static let menuBar: CGFloat = 28
    static let dockSpace: CGFloat = 100
    static let edge: CGFloat = 8
}

enum Wallpapers {
    static let all: [[Color]] = [
        [.indigo, .black],
        [.teal, .blue],
        [.orange, .pink],
        [Color(white: 0.35), .black],
        [.green, .blue]
    ]
    static func colors(_ i: Int) -> [Color] {
        let n = all.count
        return all[((i % n) + n) % n]
    }
}

// MARK: - Apps

enum SpecialKey { case enter, backspace, tab, escape, left, right, up, down }

/// Base class for per-window app state. Apps override what they need.
class AppModel: ObservableObject {
    weak var win: Win?
    func insert(_ s: String) {}
    func special(_ k: SpecialKey) {}
    func contentClick(_ p: CGPoint) {}      // p is relative to the area below the title bar
    func scroll(_ dy: CGFloat) {}           // positive = scroll content down
    func copyText() -> String? { nil }
    func hover(_ p: CGPoint) {}             // pointer moved over the content area (relative to below the title bar)
    func command(_ key: String) {}          // Cmd+<letter>
    func handleClose() -> Bool { false }    // return true to swallow Cmd+W (e.g. close a tab instead)
}

enum AppKind: String, CaseIterable, Identifiable {
    case browser, files, video, audio, terminal, notes, calculator, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: return "Browser"
        case .files: return "Files"
        case .video: return "Videos"
        case .audio: return "Music"
        case .terminal: return "Terminal"
        case .notes: return "Notes"
        case .calculator: return "Calculator"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .browser: return "globe"
        case .files: return "folder.fill"
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        case .terminal: return "terminal.fill"
        case .notes: return "note.text"
        case .calculator: return "plus.forwardslash.minus"
        case .settings: return "gearshape.fill"
        }
    }
    var color: Color {
        switch self {
        case .browser: return .blue
        case .files: return .cyan
        case .video: return .purple
        case .audio: return Color(red: 0.78, green: 0.6, blue: 0.28)
        case .terminal: return Color(white: 0.2)
        case .notes: return .yellow
        case .calculator: return .orange
        case .settings: return .gray
        }
    }
    var size: CGSize {
        switch self {
        case .browser: return CGSize(width: 1000, height: 620)
        case .files: return CGSize(width: 800, height: 480)
        case .video: return CGSize(width: 800, height: 470)
        case .audio: return CGSize(width: 460, height: 590)
        case .terminal: return CGSize(width: 640, height: 400)
        case .notes: return CGSize(width: 560, height: 420)
        case .calculator: return CGSize(width: 320, height: 460)
        case .settings: return CGSize(width: 780, height: 500)
        }
    }
    func makeModel() -> AppModel {
        switch self {
        case .browser: return BrowserModel()
        case .files: return FilesModel()
        case .video: return VideoModel()
        case .audio: return AudioModel()
        case .terminal: return TerminalModel()
        case .notes: return NotesModel()
        case .calculator: return CalcModel()
        case .settings: return SettingsModel()
        }
    }
}

// MARK: - Window + cursor

final class Win: ObservableObject, Identifiable {
    let id = UUID()
    let kind: AppKind
    let model: AppModel
    @Published var frame: CGRect
    @Published var minimized = false
    @Published var maximized = false
    @Published var fullscreen = false
    var restoreFrame: CGRect
    var fsRestore: CGRect = .zero
    var fsWasMax = false

    init(kind: AppKind, frame: CGRect) {
        self.kind = kind
        self.model = kind.makeModel()
        self.frame = frame
        self.restoreFrame = frame
        self.model.win = self
    }
}

/// Separate object so only the cursor view redraws on every mouse move.
final class CursorState: ObservableObject {
    @Published var pos = CGPoint(x: 400, y: 300)
}

// MARK: - Clickable regions

struct Hotspot: Equatable {
    let id: UUID
    let window: UUID?
    let frame: CGRect
    let action: () -> Void

    static func == (a: Hotspot, b: Hotspot) -> Bool {
        a.id == b.id && a.window == b.window && a.frame == b.frame
    }
}

struct HotspotKey: PreferenceKey {
    static let defaultValue: [Hotspot] = []
    static func reduce(value: inout [Hotspot], nextValue: () -> [Hotspot]) {
        value.append(contentsOf: nextValue())
    }
}

private struct WinIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}
extension EnvironmentValues {
    var winID: UUID? {
        get { self[WinIDKey.self] }
        set { self[WinIDKey.self] = newValue }
    }
}

struct ClickableModifier: ViewModifier {
    @Environment(\.winID) private var winID
    @State private var id = UUID()
    let action: () -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { g in
                Color.clear.preference(
                    key: HotspotKey.self,
                    value: [Hotspot(id: id, window: winID,
                                    frame: g.frame(in: .named("desk")),
                                    action: action)]
                )
            }
        )
    }
}

/// Like `clickable`, but reports where inside the view the pointer was (0...1 on both axes).
struct ClickableAtModifier: ViewModifier {
    @Environment(\.winID) private var winID
    @State private var id = UUID()
    let action: (CGPoint) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { g in
                let f = g.frame(in: .named("desk"))
                Color.clear.preference(
                    key: HotspotKey.self,
                    value: [Hotspot(id: id, window: winID, frame: f, action: {
                        let p = Desktop.shared.cursor.pos
                        action(CGPoint(x: min(max((p.x - f.minX) / max(f.width, 1), 0), 1),
                                       y: min(max((p.y - f.minY) / max(f.height, 1), 0), 1)))
                    })]
                )
            }
        )
    }
}

extension View {
    func clickable(_ action: @escaping () -> Void) -> some View {
        modifier(ClickableModifier(action: action))
    }
    func clickableAt(_ action: @escaping (CGPoint) -> Void) -> some View {
        modifier(ClickableAtModifier(action: action))
    }
}

/// Turns raw scroll deltas into whole "row" steps.
struct ScrollAccumulator {
    private var acc: CGFloat = 0
    mutating func feed(_ dy: CGFloat, step: CGFloat) -> Int {
        acc += dy
        let n = Int(acc / step)
        acc -= CGFloat(n) * step
        return n
    }
}

// MARK: - The desktop

final class Desktop: ObservableObject {
    static let shared = Desktop()

    @Published var windows: [Win] = [] { didSet { saveLayout() } }   // back-to-front
    @Published var focusedID: UUID?
    @Published var fullscreenWin: Win?
    @Published var uiScale: CGFloat = 1.0
    @Published var showOnScreenKeyboard = false
    @Published var dockVisible = true
    @Published var launcherOpen = false
    @Published var launcherQuery = ""
    @Published var menuPoint: CGPoint?
    /// LOGICAL size: what the desktop lays itself out in (physical / uiScale)
    @Published var screen = CGSize(width: 1280, height: 720)
    private(set) var physicalScreen = CGSize(width: 1280, height: 720)

    let cursor = CursorState()
    var hotspots: [Hotspot] = []

    private enum DragMode {
        case move(Win, CGSize)
        case resize(Win, CGRect, CGPoint, Bool, Bool)
    }
    private var drag: DragMode?
    private var lastTitleClick: (UUID, Date)?
    private var didWelcome = false
    private var didCenter = false
    private var hideWork: DispatchWorkItem?

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    // MARK: Scaling

    /// Default "normal" scale: tuned so text is readable on TVs / monitors (720pt tall = 100%).
    var autoScale: CGFloat {
        max(1, min(2.5, ((physicalScreen.height / 720) * 10).rounded() / 10))
    }

    private var targetScale: CGFloat {
        let s = Settings.shared.scale
        return s > 0 ? CGFloat(s) : autoScale
    }

    func applyScale() {
        let new = targetScale
        guard abs(new - uiScale) > 0.001 else { return }
        let old = screen
        uiScale = new
        screen = CGSize(width: physicalScreen.width / new, height: physicalScreen.height / new)
        cursor.pos = clamp(CGPoint(x: cursor.pos.x * screen.width / max(old.width, 1),
                                   y: cursor.pos.y * screen.height / max(old.height, 1)))
        for w in windows {
            w.frame = w.maximized ? usableRect : fit(w.frame)
            w.restoreFrame = fit(w.restoreFrame)
            if w.fullscreen { w.frame = CGRect(origin: .zero, size: screen) }
        }
    }

    func stepScale(_ delta: CGFloat) {
        Settings.shared.scale = Double(max(0.7, min(2.5, ((uiScale + delta) * 10).rounded() / 10)))
    }

    private func fit(_ f: CGRect) -> CGRect {
        let u = usableRect
        let w = min(f.width, u.width - 16)
        let h = min(f.height, u.height)
        let x = min(max(f.minX, 0), max(0, u.width - w))
        let y = min(max(f.minY, u.minY), max(u.minY, u.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func toggleKeyboard() { showOnScreenKeyboard.toggle() }

    // MARK: Screen

    func setScreen(_ size: CGSize) {
        physicalScreen = size
        uiScale = targetScale
        screen = CGSize(width: size.width / uiScale, height: size.height / uiScale)
        if !didCenter {
            cursor.pos = CGPoint(x: screen.width / 2, y: screen.height / 2)
            didCenter = true
        }
        cursor.pos = clamp(cursor.pos)
        if !didWelcome && windows.isEmpty {
            didWelcome = true
            if !restoreLayout() { launch(.notes) }
        }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), screen.width - 1),
                y: min(max(p.y, 0), screen.height - 1))
    }

    var usableRect: CGRect {
        let bottom: CGFloat = Settings.shared.dockAutoHide ? 12 : Metrics.dockSpace
        return CGRect(x: 0, y: Metrics.menuBar,
                      width: screen.width,
                      height: screen.height - Metrics.menuBar - bottom)
    }

    var focusedWindow: Win? { windows.first { $0.id == focusedID } }

    // MARK: Persistence of open windows

    private struct SavedWin: Codable {
        var kind: String
        var x: Double, y: Double, w: Double, h: Double
        var maximized: Bool
        var minimized: Bool
    }

    private func saveLayout() {
        let items = windows.map { w -> SavedWin in
            let f = w.fullscreen ? w.fsRestore : (w.maximized ? w.restoreFrame : w.frame)
            return SavedWin(kind: w.kind.rawValue,
                            x: Double(f.minX), y: Double(f.minY), w: Double(f.width), h: Double(f.height),
                            maximized: w.fullscreen ? w.fsWasMax : w.maximized,
                            minimized: w.minimized)
        }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: "nt.layout")
        }
    }

    private func restoreLayout() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "nt.layout"),
              let items = try? JSONDecoder().decode([SavedWin].self, from: data),
              !items.isEmpty else { return false }
        for it in items {
            guard let kind = AppKind(rawValue: it.kind) else { continue }
            let r = fit(CGRect(x: it.x, y: it.y, width: it.w, height: it.h))
            let w = Win(kind: kind, frame: r)
            if it.maximized { w.frame = usableRect; w.maximized = true }
            w.minimized = it.minimized
            windows.append(w)
        }
        focusedID = windows.last(where: { !$0.minimized })?.id
        return !windows.isEmpty
    }

    /// Used by factory reset.
    func reset() {
        fullscreenWin = nil
        launcherOpen = false
        menuPoint = nil
        windows.removeAll()
        focusedID = nil
        UserDefaults.standard.removeObject(forKey: "nt.layout")
        didWelcome = true
        applyScale()
        launch(.notes)
    }

    // MARK: Window management

    @discardableResult
    func launch(_ kind: AppKind) -> Win {
        let n = CGFloat(windows.count % 6)
        var size = kind.size
        size.width = min(size.width, screen.width - 80)
        size.height = min(size.height, screen.height - Metrics.menuBar - Metrics.dockSpace)
        let origin = CGPoint(x: 90 + n * 36, y: Metrics.menuBar + 40 + n * 30)
        let w = Win(kind: kind, frame: fit(CGRect(origin: origin, size: size)))
        windows.append(w)
        focusedID = w.id
        return w
    }

    func focus(_ w: Win) {
        w.minimized = false
        if windows.last?.id != w.id, let i = windows.firstIndex(where: { $0.id == w.id }) {
            let item = windows.remove(at: i)
            windows.append(item)
        }
        focusedID = w.id
    }

    func close(_ w: Win) {
        if fullscreenWin?.id == w.id { fullscreenWin = nil }
        windows.removeAll { $0.id == w.id }
        if focusedID == w.id { focusedID = windows.last(where: { !$0.minimized })?.id }
    }

    func minimize(_ w: Win) {
        w.minimized = true
        if focusedID == w.id { focusedID = windows.last(where: { !$0.minimized })?.id }
        saveLayout()
    }

    func toggleMaximize(_ w: Win) {
        if w.maximized {
            w.frame = w.restoreFrame
            w.maximized = false
        } else {
            maximize(w)
        }
        saveLayout()
    }

    private func maximize(_ w: Win) {
        if !w.maximized { w.restoreFrame = w.frame }
        w.frame = usableRect
        w.maximized = true
    }

    private func snap(_ w: Win, left: Bool) {
        if !w.maximized { w.restoreFrame = w.frame }
        let r = usableRect
        w.frame = CGRect(x: left ? 0 : r.width / 2, y: r.minY, width: r.width / 2, height: r.height)
        w.maximized = true
    }

    /// Full-screen mode for a window (used by browser video / page fullscreen).
    func setFullscreen(_ w: Win, _ on: Bool) {
        if on == w.fullscreen { return }
        if on {
            w.fsRestore = w.frame
            w.fsWasMax = w.maximized
            w.fullscreen = true
            w.frame = CGRect(origin: .zero, size: screen)
            fullscreenWin = w
            focus(w)
        } else {
            w.fullscreen = false
            w.maximized = w.fsWasMax
            w.frame = w.fsWasMax ? usableRect : w.fsRestore
            if fullscreenWin?.id == w.id { fullscreenWin = nil }
        }
        saveLayout()
    }

    func dockClick(_ kind: AppKind) {
        guard let top = windows.last(where: { $0.kind == kind }) else { launch(kind); return }
        if top.id == focusedID && !top.minimized { minimize(top) } else { focus(top) }
    }

    func cycleWindows() {
        let visible = windows.filter { !$0.minimized }
        if visible.count > 1, let first = visible.first {
            focus(first)
        } else if let m = windows.last(where: { $0.minimized }) {
            focus(m)
        }
    }

    func closeFocused() {
        guard let w = focusedWindow else { return }
        if w.model.handleClose() { return }
        close(w)
    }
    func command(_ key: String) { focusedWindow?.model.command(key) }

    /// Open a media file in the right app
    func openMedia(_ url: URL, playlist: [URL] = []) {
        guard let kind = MediaTypes.kind(url) else { return }
        switch kind {
        case .video:
            let w = windows.last(where: { $0.kind == .video }) ?? launch(.video)
            focus(w)
            (w.model as? VideoModel)?.play(url, queue: playlist)
        case .audio:
            let w = windows.last(where: { $0.kind == .audio }) ?? launch(.audio)
            focus(w)
            (w.model as? AudioModel)?.play(url, queue: playlist)
        case .image:
            break
        }
    }
    func minimizeFocused() { if let w = focusedWindow { minimize(w) } }
    func quitFocusedApp() {
        guard let kind = focusedWindow?.kind else { return }
        if fullscreenWin?.kind == kind { fullscreenWin = nil }
        windows.removeAll { $0.kind == kind }
        focusedID = windows.last(where: { !$0.minimized })?.id
    }

    // MARK: Launcher

    var launcherResults: [AppKind] {
        let q = launcherQuery.lowercased()
        return q.isEmpty ? AppKind.allCases : AppKind.allCases.filter { $0.title.lowercased().contains(q) }
    }

    func toggleLauncher() {
        launcherOpen.toggle()
        launcherQuery = ""
        menuPoint = nil
    }

    private func runLauncher() {
        if let k = launcherResults.first { launch(k) }
        launcherOpen = false
    }

    // MARK: Keyboard routing

    func insert(_ s: String) {
        if launcherOpen { launcherQuery += s; return }
        focusedWindow?.model.insert(s)
    }

    func special(_ k: SpecialKey) {
        if launcherOpen {
            switch k {
            case .backspace: launcherQuery = String(launcherQuery.dropLast())
            case .enter: runLauncher()
            case .escape: launcherOpen = false
            default: break
            }
            return
        }
        if menuPoint != nil && k == .escape { menuPoint = nil; return }
        focusedWindow?.model.special(k)
    }

    func copy() {
        if let s = focusedWindow?.model.copyText() { UIPasteboard.general.string = s }
    }

    func paste() {
        if let s = UIPasteboard.general.string { insert(s) }
    }

    // MARK: Pointer

    private func smallest(_ hs: [Hotspot]) -> Hotspot? {
        hs.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func chromeHotspot(at p: CGPoint) -> Hotspot? {
        smallest(hotspots.filter { $0.window == nil && $0.frame.contains(p) })
    }

    private func topWindow(at p: CGPoint) -> Win? {
        windows.last {
            !$0.minimized && $0.frame.insetBy(dx: -Metrics.edge, dy: -Metrics.edge).contains(p)
        }
    }

    func mouseMoved(dx: CGFloat, dy: CGFloat) {
        // Tracking speed from settings; divide by uiScale so pointer speed is constant at any zoom
        let k = CGFloat(Settings.shared.trackingSpeed) / uiScale
        let p = clamp(CGPoint(x: cursor.pos.x + dx * k, y: cursor.pos.y + dy * k))
        cursor.pos = p
        updateDock(p)
        guard let drag else { hover(at: p); return }
        switch drag {
        case .move(let w, let off):
            w.frame.origin = CGPoint(x: p.x - off.width, y: max(Metrics.menuBar, p.y - off.height))
        case .resize(let w, let start, let startP, let right, let bottom):
            var f = start
            if right { f.size.width = max(260, start.width + p.x - startP.x) }
            if bottom { f.size.height = max(160, start.height + p.y - startP.y) }
            w.frame = f
        }
    }

    // MARK: Dock auto-hide

    func dockModeChanged() {
        hideWork?.cancel()
        dockVisible = true
        for w in windows where w.maximized && !w.fullscreen {
            w.frame = CGRect(x: w.frame.minX, y: usableRect.minY, width: w.frame.width, height: usableRect.height)
        }
    }

    private func updateDock(_ p: CGPoint) {
        guard Settings.shared.dockAutoHide else {
            if !dockVisible { dockVisible = true }
            return
        }
        if p.y >= screen.height - 6 {
            hideWork?.cancel()
            if !dockVisible { dockVisible = true }
        } else if p.y < screen.height - 118, dockVisible, hideWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.dockVisible = false
                self?.hideWork = nil
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else if p.y >= screen.height - 118 {
            hideWork?.cancel()
            hideWork = nil
        }
    }

    private func hover(at p: CGPoint) {
        guard !launcherOpen, menuPoint == nil, let w = topWindow(at: p), w.frame.contains(p) else { return }
        let tb: CGFloat = w.fullscreen ? 0 : Metrics.titleBar
        let lp = CGPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY - tb)
        if lp.y >= 0 { w.model.hover(lp) }
    }

    func click() { leftDown(); leftUp() }

    func leftDown() {
        let p = cursor.pos

        if launcherOpen { launcherOpen = false; return }

        let chrome = chromeHotspot(at: p)
        if menuPoint != nil {
            menuPoint = nil
            chrome?.action()
            return
        }
        if let chrome { chrome.action(); return }

        guard let w = topWindow(at: p) else { focusedID = nil; return }
        focus(w)

        let lp = CGPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY)
        guard lp.x >= 0, lp.y >= 0 else { return }
        let tb: CGFloat = w.fullscreen ? 0 : Metrics.titleBar

        // Title bar: traffic lights, double-click, drag
        if lp.y < tb {
            let centers: [CGFloat] = [18, 40, 62]
            for (i, cx) in centers.enumerated() where hypot(lp.x - cx, lp.y - 16) <= 10 {
                if i == 0 { close(w) } else if i == 1 { minimize(w) } else { toggleMaximize(w) }
                return
            }
            if let l = lastTitleClick, l.0 == w.id, Date().timeIntervalSince(l.1) < 0.4 {
                lastTitleClick = nil
                toggleMaximize(w)
                return
            }
            lastTitleClick = (w.id, Date())
            if w.maximized {
                let rf = w.restoreFrame
                w.frame = CGRect(x: p.x - rf.width / 2, y: Metrics.menuBar, width: rf.width, height: rf.height)
                w.maximized = false
                drag = .move(w, CGSize(width: rf.width / 2, height: lp.y))
            } else {
                drag = .move(w, CGSize(width: lp.x, height: lp.y))
            }
            return
        }

        // Resize from right / bottom / corner
        if !w.maximized && !w.fullscreen {
            let right = lp.x >= w.frame.width - Metrics.edge
            let bottom = lp.y >= w.frame.height - Metrics.edge
            if right || bottom {
                drag = .resize(w, w.frame, p, right, bottom)
                return
            }
        }

        // Content
        let inside = hotspots.filter { $0.window == w.id && $0.frame.contains(p) }
        if let h = smallest(inside) {
            h.action()
        } else {
            w.model.contentClick(CGPoint(x: lp.x, y: lp.y - tb))
        }
    }

    func leftUp() {
        let d = drag
        drag = nil
        switch d {
        case .move(let w, _)?:
            let p = cursor.pos
            if p.y <= 2 { maximize(w) }
            else if p.x <= 2 { snap(w, left: true) }
            else if p.x >= screen.width - 3 { snap(w, left: false) }
            saveLayout()
        case .resize?:
            saveLayout()
        case nil:
            break
        }
    }

    func rightClick() {
        let p = cursor.pos
        guard !launcherOpen, chromeHotspot(at: p) == nil else { return }
        menuPoint = topWindow(at: p) == nil ? p : nil
    }

    /// `motion`: positive = fingers (or wheel) moved DOWN. Natural scrolling makes the content follow them.
    func scroll(_ motion: CGFloat) {
        let dy = Settings.shared.naturalScroll ? -motion : motion
        topWindow(at: cursor.pos)?.model.scroll(dy)
    }
}

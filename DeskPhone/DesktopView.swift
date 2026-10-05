import SwiftUI
import UIKit

// MARK: - Root

struct DesktopView: View {
    @ObservedObject private var desktop = Desktop.shared
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaperLayer

            // Logical-size layer, scaled up to fill the real display
            ZStack(alignment: .topLeading) {
                desktopContent
                CursorView(cursor: desktop.cursor,
                           scale: settings.cursorScale / desktop.uiScale,
                           style: settings.pointerStyle)
            }
            .frame(width: desktop.screen.width, height: desktop.screen.height, alignment: .topLeading)
            .coordinateSpace(.named("desk"))
            .onPreferenceChange(HotspotKey.self) { desktop.hotspots = $0 }
            .scaleEffect(desktop.uiScale, anchor: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    @ViewBuilder private var wallpaperLayer: some View {
        if settings.wallpaper < 0, let img = settings.customWallpaper {
            Color.black
                .overlay(Image(uiImage: img).resizable().scaledToFill())
                .clipped()
                .ignoresSafeArea()
        } else {
            LinearGradient(colors: Wallpapers.colors(settings.wallpaper),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
    }

    private var desktopContent: some View {
        ZStack(alignment: .topLeading) {
            ForEach(desktop.windows) { win in
                WindowView(win: win, focused: desktop.focusedID == win.id)
            }
            if desktop.fullscreenWin == nil {
                MenuBarView(desktop: desktop)
                DockView(desktop: desktop)
            }
            if let p = desktop.menuPoint {
                ContextMenuView(desktop: desktop, point: p)
            }
            if desktop.launcherOpen {
                LauncherView(desktop: desktop)
            }
        }
    }
}

// MARK: - Window

struct WindowView: View {
    @ObservedObject var win: Win
    let focused: Bool

    var body: some View {
        let r: CGFloat = win.fullscreen ? 0 : 10
        VStack(spacing: 0) {
            if !win.fullscreen { titleBar }
            AppContent(win: win)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: win.frame.width, height: win.frame.height)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: r))
        .overlay(
            RoundedRectangle(cornerRadius: r)
                .stroke(Color.white.opacity(win.fullscreen ? 0 : (focused ? 0.35 : 0.12)), lineWidth: 1)
        )
        .shadow(color: .black.opacity(win.fullscreen ? 0 : 0.45), radius: focused ? 24 : 10, y: 8)
        .environment(\.winID, win.id)
        .position(x: win.frame.midX, y: win.frame.midY)
        .opacity(win.minimized ? 0 : 1)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red.opacity(focused ? 1 : 0.4)).frame(width: 14, height: 14)
            Circle().fill(Color.yellow.opacity(focused ? 1 : 0.4)).frame(width: 14, height: 14)
            Circle().fill(Color.green.opacity(focused ? 1 : 0.4)).frame(width: 14, height: 14)
            Spacer()
            Text(win.kind.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(focused ? 0.9 : 0.5))
            Spacer()
            Color.clear.frame(width: 62, height: 1)
        }
        .padding(.leading, 11)
        .frame(height: Metrics.titleBar)
        .background(Color(white: focused ? 0.2 : 0.15))
    }
}

struct AppContent: View {
    let win: Win

    var body: some View {
        switch win.kind {
        case .notes: NotesView(model: win.model as! NotesModel)
        case .browser: BrowserView(model: win.model as! BrowserModel)
        case .calculator: CalculatorView(model: win.model as! CalcModel)
        case .files: FilesView(model: win.model as! FilesModel)
        case .terminal: TerminalView(model: win.model as! TerminalModel)
        case .settings: SettingsView(model: win.model as! SettingsModel)
        }
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @ObservedObject var desktop: Desktop

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill")
                    .clickable { desktop.toggleLauncher() }
                Text("NanoTower").fontWeight(.semibold)
                Text(desktop.focusedWindow?.kind.title ?? "Desktop").opacity(0.7)
                Spacer()
                TimelineView(.periodic(from: .now, by: 5)) { ctx in
                    BatteryTimeStatusView(date: ctx.date)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: Metrics.menuBar)
            .background(Color.black.opacity(0.45))
            .clickable {}
            Spacer()
        }
    }
}

struct BatteryTimeStatusView: View {
    let date: Date

    private var batteryText: String {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? "–" : "\(Int(level * 100))%"
    }

    var body: some View {
        HStack(spacing: 14) {
            Label(batteryText, systemImage: "battery.100")
            Text(date.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

// MARK: - Dock

struct DockView: View {
    @ObservedObject var desktop: Desktop

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                ForEach(AppKind.allCases) { kind in
                    dockItem(for: kind)
                }
                launcherButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .clickable {}
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private func dockItem(for kind: AppKind) -> some View {
        VStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14).fill(kind.color.gradient))
            Circle()
                .fill(Color.white)
                .frame(width: 5, height: 5)
                .opacity(desktop.windows.contains(where: { $0.kind == kind }) ? 1 : 0)
        }
        .clickable { desktop.dockClick(kind) }
    }

    private var launcherButton: some View {
        VStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.15)))
            Circle().fill(Color.clear).frame(width: 5, height: 5)
        }
        .clickable { desktop.toggleLauncher() }
    }
}

// MARK: - Context Menu

struct ContextMenuView: View {
    @ObservedObject var desktop: Desktop
    let point: CGPoint

    private var width: CGFloat { 220 }
    private var height: CGFloat { CGFloat(AppKind.allCases.count + 1) * 34 + 12 }
    private var posX: CGFloat { min(point.x, desktop.screen.width - width - 8) }
    private var posY: CGFloat { min(point.y, desktop.screen.height - height - 8) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AppKind.allCases) { k in
                row(k.icon, "Open \(k.title)").clickable { desktop.launch(k) }
            }
            row("photo", "Next wallpaper").clickable { Settings.shared.nextWallpaper() }
        }
        .padding(6)
        .frame(width: width)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .offset(x: posX, y: posY)
    }

    private func row(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20)
            Text(title)
            Spacer()
        }
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }
}

// MARK: - Launcher

struct LauncherView: View {
    @ObservedObject var desktop: Desktop

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            resultsList
        }
        .foregroundStyle(.white)
        .frame(width: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, desktop.screen.height * 0.2)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
            Text(desktop.launcherQuery.isEmpty ? "Search apps…" : desktop.launcherQuery + "▏")
                .opacity(desktop.launcherQuery.isEmpty ? 0.5 : 1)
            Spacer()
        }
        .font(.system(size: 22))
        .padding(16)
    }

    private var resultsList: some View {
        ForEach(desktop.launcherResults) { k in
            launcherRow(k)
        }
    }

    private func launcherRow(_ k: AppKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: k.icon).frame(width: 24)
            Text(k.title)
            Spacer()
            if k == desktop.launcherResults.first {
                Text("↩").opacity(0.6)
            }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(k == desktop.launcherResults.first ? Color.white.opacity(0.12) : Color.clear)
    }
}

// MARK: - Cursor

struct CursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 17))
        p.addLine(to: CGPoint(x: 4, y: 13.2))
        p.addLine(to: CGPoint(x: 7, y: 20))
        p.addLine(to: CGPoint(x: 9.4, y: 19))
        p.addLine(to: CGPoint(x: 6.6, y: 12.4))
        p.addLine(to: CGPoint(x: 12, y: 12))
        p.closeSubpath()
        return p
    }
}

struct CursorView: View {
    @ObservedObject var cursor: CursorState
    let scale: CGFloat
    let style: PointerStyle

    var body: some View {
        PointerGlyph(style: style)
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: cursor.pos.x - style.hotspot * scale,
                    y: cursor.pos.y - style.hotspot * scale)
            .allowsHitTesting(false)
    }
}

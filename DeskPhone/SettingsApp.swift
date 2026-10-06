import SwiftUI
import UIKit
import Combine

enum SettingsTab: Int, CaseIterable, Identifiable {
    case display, pointer, wallpaper, browser, system
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .display: return "Display"
        case .pointer: return "Pointer"
        case .wallpaper: return "Wallpaper"
        case .browser: return "Browser"
        case .system: return "System"
        }
    }
    var icon: String {
        switch self {
        case .display: return "display"
        case .pointer: return "cursorarrow"
        case .wallpaper: return "photo"
        case .browser: return "globe"
        case .system: return "gearshape"
        }
    }
}

final class SettingsModel: AppModel {
    @Published var tab: SettingsTab = .display
    @Published var editingHome = false
    @Published var confirmReset = false
    @Published var cleared = false

    override func insert(_ s: String) {
        if editingHome { Settings.shared.homepage += s.replacingOccurrences(of: "\n", with: "") }
    }
    override func special(_ k: SpecialKey) {
        guard editingHome else { return }
        switch k {
        case .backspace: Settings.shared.homepage = String(Settings.shared.homepage.dropLast())
        case .enter, .escape: editingHome = false
        default: break
        }
    }
    override func contentClick(_ p: CGPoint) { editingHome = false }
}

/// Same sections as the iPhone settings page, rebuilt for the pointer-driven desktop.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var desktop = Desktop.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 160)
            VStack(alignment: .leading, spacing: 18) {
                content
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.12))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.icon).frame(width: 20)
                    Text(t.title).font(.system(size: 14))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(model.tab == t ? Color.blue.opacity(0.55) : Color.clear))
                .clickable { model.tab = t; model.editingHome = false }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.16))
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .display: displayTab
        case .pointer: pointerTab
        case .wallpaper: wallpaperTab
        case .browser: browserTab
        case .system: systemTab
        }
    }

    // MARK: Helpers

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            c()
        }
    }

    private func chip(_ text: String, selected: Bool = false, destructive: Bool = false,
                      _ action: @escaping () -> Void) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .frame(minWidth: 34, minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(destructive ? Color.red.opacity(0.75) : (selected ? Color.blue : Color.white.opacity(0.12))))
            .clickable(action)
    }

    private func tile<C: View>(selected: Bool, @ViewBuilder _ c: () -> C) -> some View {
        c()
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.blue.opacity(0.45) : Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white, lineWidth: selected ? 2 : 0))
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
    }

    // MARK: Display

    @ViewBuilder private var displayTab: some View {
        section("Interface scale") {
            HStack(spacing: 8) {
                chip("−") { desktop.stepScale(-0.1) }
                Text("\(Int((desktop.uiScale * 100).rounded()))%")
                    .font(.system(size: 17, weight: .semibold)).monospacedDigit().frame(width: 64)
                chip("+") { desktop.stepScale(0.1) }
                chip("Auto", selected: s.scale == 0) { s.scale = 0 }
            }
            hint(s.scale == 0 ? "Auto picks a comfortable, readable size for this display."
                              : "Custom scale. Choose Auto to restore the recommended size.")
        }
        section("Dock") {
            HStack(spacing: 8) {
                chip("Magnify icons: \(s.dockZoom ? "On" : "Off")", selected: s.dockZoom) { s.dockZoom.toggle() }
                chip("Auto-hide: \(s.dockAutoHide ? "On" : "Off")", selected: s.dockAutoHide) { s.dockAutoHide.toggle() }
            }
            hint("With auto-hide, push the pointer to the bottom edge to bring the dock back.")
        }
        section("Scrolling") {
            HStack(spacing: 8) {
                chip("Natural scrolling: \(s.naturalScroll ? "On" : "Off")", selected: s.naturalScroll) { s.naturalScroll.toggle() }
            }
            hint("Same direction for the iPhone trackpad and a mouse wheel.")
        }
    }

    // MARK: Pointer

    private func stepSpeed(_ d: Double) {
        s.trackingSpeed = max(0.3, min(3, ((s.trackingSpeed + d) * 10).rounded() / 10))
    }

    @ViewBuilder private var pointerTab: some View {
        section("Tracking speed") {
            HStack(spacing: 8) {
                chip("−") { stepSpeed(-0.1) }
                Text(String(format: "%.1f×", s.trackingSpeed))
                    .font(.system(size: 17, weight: .semibold)).monospacedDigit().frame(width: 64)
                chip("+") { stepSpeed(0.1) }
                chip("Slow", selected: s.trackingSpeed == 0.6) { s.trackingSpeed = 0.6 }
                chip("Normal", selected: s.trackingSpeed == 1.0) { s.trackingSpeed = 1.0 }
                chip("Fast", selected: s.trackingSpeed == 1.8) { s.trackingSpeed = 1.8 }
            }
        }
        section("Pointer style") {
            HStack(spacing: 8) {
                ForEach(PointerStyle.allCases) { st in
                    tile(selected: s.pointerStyle == st) {
                        VStack(spacing: 4) {
                            PointerGlyph(style: st)
                            Text(st.title).font(.system(size: 11))
                        }
                    }
                    .clickable { s.pointerStyle = st }
                }
            }
        }
        section("Pointer size") {
            HStack(spacing: 6) {
                ForEach(0..<Settings.cursorSizes.count, id: \.self) { i in
                    tile(selected: s.cursorSize == i) {
                        VStack(spacing: 2) {
                            PointerGlyph(style: s.pointerStyle)
                                .scaleEffect(Settings.cursorSizes[i] * 0.5)
                                .frame(height: 40)
                            Text("\(i + 1)").font(.system(size: 11))
                        }
                    }
                    .clickable { s.cursorSize = i }
                }
            }
        }
    }

    // MARK: Wallpaper

    @ViewBuilder private var wallpaperTab: some View {
        section("Wallpaper") {
            HStack(spacing: 10) {
                ForEach(0..<Wallpapers.all.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: Wallpapers.all[i], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white, lineWidth: s.wallpaper == i ? 3 : 0))
                        .clickable { s.wallpaper = i }
                }
            }
        }
        section("Custom wallpaper") {
            HStack(spacing: 14) {
                ZStack {
                    if let img = s.customWallpaper {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                        Text("None").font(.system(size: 13)).opacity(0.5)
                    }
                }
                .frame(width: 150, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white, lineWidth: s.wallpaper == -1 ? 3 : 0))
                .clickable { if s.customWallpaper != nil { s.wallpaper = -1 } }

                VStack(alignment: .leading, spacing: 8) {
                    if s.customWallpaper != nil { chip("Remove") { s.clearCustomWallpaper() } }
                    hint("Pick a photo in Settings on the iPhone,\nor open an image in Files → Set as wallpaper.")
                }
            }
        }
    }

    // MARK: Browser

    @ViewBuilder private var browserTab: some View {
        section("Homepage") {
            Text(s.homepage + (model.editingHome ? "▏" : ""))
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue, lineWidth: model.editingHome ? 1.5 : 0))
                .clickable { model.editingHome = true }
        }
        section("Search engine") {
            HStack(spacing: 8) {
                ForEach(SearchEngine.allCases) { e in
                    chip(e.title, selected: s.searchEngine == e) { s.searchEngine = e }
                }
            }
        }
        section("Pages") {
            HStack(spacing: 8) {
                chip("Desktop sites: \(s.requestDesktop ? "On" : "Off")", selected: s.requestDesktop) { s.requestDesktop.toggle() }
                chip(model.cleared ? "Cleared ✓" : "Clear browsing data") {
                    s.clearBrowsingData { model.cleared = true }
                }
            }
        }
    }

    // MARK: System

    @ViewBuilder private var systemTab: some View {
        section("iPhone screen") {
            HStack(spacing: 8) {
                chip("Black screen: \(s.blackout ? "On" : "Off")", selected: s.blackout) { s.blackout.toggle() }
            }
            hint("Turns the iPhone display black while the desktop keeps running.")
        }
        section("Factory reset") {
            hint("Erases settings, files, notes, browser data and open windows.")
            if model.confirmReset {
                HStack(spacing: 8) {
                    chip("Yes, erase everything", destructive: true) { model.confirmReset = false; s.factoryReset() }
                    chip("Cancel") { model.confirmReset = false }
                }
            } else {
                chip("Reset to factory defaults…", destructive: true) { model.confirmReset = true }
            }
        }
        hint("NanoTower v0.3")
    }
}

import SwiftUI
import UIKit
import WebKit
import PhotosUI
import Combine
import UniformTypeIdentifiers

// MARK: - Option types

enum PointerStyle: String, CaseIterable, Identifiable {
    case arrow, darkArrow, dot, ring, cross
    var id: String { rawValue }
    var title: String {
        switch self {
        case .arrow: return "Arrow"
        case .darkArrow: return "Dark"
        case .dot: return "Dot"
        case .ring: return "Ring"
        case .cross: return "Cross"
        }
    }
    /// Click point inside the 24×24 glyph box
    var hotspot: CGFloat { (self == .arrow || self == .darkArrow) ? 0 : 12 }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckduckgo, google, bing, brave
    var id: String { rawValue }
    var title: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .brave: return "Brave"
        }
    }
    var searchURL: String {
        switch self {
        case .duckduckgo: return "https://duckduckgo.com/?q="
        case .google: return "https://www.google.com/search?q="
        case .bing: return "https://www.bing.com/search?q="
        case .brave: return "https://search.brave.com/search?q="
        }
    }
}

extension Notification.Name {
    static let browserPrefsChanged = Notification.Name("nt.browserPrefsChanged")
}

// MARK: - Pointer glyph (shared by desktop cursor + settings previews)

struct PointerGlyph: View {
    let style: PointerStyle

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch style {
            case .arrow: arrow(.white, .black)
            case .darkArrow: arrow(.black, .white)
            case .dot:
                Circle().fill(Color.white).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1.5))
                    .offset(x: 6, y: 6)
            case .ring:
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1).padding(-2))
                    .offset(x: 2, y: 2)
            case .cross:
                Rectangle().fill(Color.white).frame(width: 2, height: 22).offset(x: 11, y: 1)
                Rectangle().fill(Color.white).frame(width: 22, height: 2).offset(x: 1, y: 11)
            }
        }
        .frame(width: 24, height: 24, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 1.5)
    }

    private func arrow(_ fill: Color, _ stroke: Color) -> some View {
        CursorShape().fill(fill)
            .overlay(CursorShape().stroke(stroke, lineWidth: 1.2))
            .frame(width: 13, height: 21)
    }
}

// MARK: - Settings store (everything persists in UserDefaults)

final class Settings: ObservableObject {
    static let shared = Settings()
    static let cursorSizes: [CGFloat] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]   // 9 sizes
    static var wallpaperURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("wallpaper.jpg")
    }

    /// 0 = Auto (recommended, picked from the display size)
    @Published var scale: Double = 0 {
        didSet {
            guard ready else { return }          // never touch Desktop while Settings is still initialising
            UserDefaults.standard.set(scale, forKey: "nt.scale")
            Desktop.shared.applyScale()
        }
    }
    @Published var trackingSpeed: Double = 1.0 {
        didSet { UserDefaults.standard.set(trackingSpeed, forKey: "nt.tracking") }
    }
    @Published var pointerStyle: PointerStyle = .arrow {
        didSet { UserDefaults.standard.set(pointerStyle.rawValue, forKey: "nt.pointer") }
    }
    @Published var cursorSize: Int = 1 {
        didSet { UserDefaults.standard.set(cursorSize, forKey: "nt.cursorSize") }
    }
    /// -1 = custom image
    @Published var wallpaper: Int = 0 {
        didSet { UserDefaults.standard.set(wallpaper, forKey: "nt.wallpaper") }
    }
    @Published var customWallpaper: UIImage?
    @Published var homepage: String = "duckduckgo.com" {
        didSet { UserDefaults.standard.set(homepage, forKey: "nt.home") }
    }
    @Published var searchEngine: SearchEngine = .duckduckgo {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: "nt.engine") }
    }
    @Published var requestDesktop: Bool = true {
        didSet {
            UserDefaults.standard.set(requestDesktop, forKey: "nt.desktop")
            NotificationCenter.default.post(name: .browserPrefsChanged, object: nil)
        }
    }
    @Published var naturalScroll: Bool = true {
        didSet { UserDefaults.standard.set(naturalScroll, forKey: "nt.natural") }
    }
    @Published var dockZoom: Bool = true {
        didSet { UserDefaults.standard.set(dockZoom, forKey: "nt.dockZoom") }
    }
    @Published var dockAutoHide: Bool = false {
        didSet {
            UserDefaults.standard.set(dockAutoHide, forKey: "nt.dockHide")
            if ready { Desktop.shared.dockModeChanged() }
        }
    }
    @Published var blackout = false {
        didSet { if oldValue != blackout { applyBlackout() } }
    }

    var cursorScale: CGFloat { Self.cursorSizes[min(max(cursorSize, 0), Self.cursorSizes.count - 1)] }
    var lastURL: String {
        get { UserDefaults.standard.string(forKey: "nt.lastURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "nt.lastURL") }
    }

    private var savedBrightness: CGFloat = 0.5
    private var ready = false

    private init() {
        let d = UserDefaults.standard
        scale = d.double(forKey: "nt.scale")
        if d.object(forKey: "nt.tracking") != nil { trackingSpeed = d.double(forKey: "nt.tracking") }
        pointerStyle = PointerStyle(rawValue: d.string(forKey: "nt.pointer") ?? "") ?? .arrow
        if d.object(forKey: "nt.cursorSize") != nil { cursorSize = min(max(d.integer(forKey: "nt.cursorSize"), 0), 8) }
        if d.object(forKey: "nt.wallpaper") != nil { wallpaper = d.integer(forKey: "nt.wallpaper") }
        homepage = d.string(forKey: "nt.home") ?? "duckduckgo.com"
        searchEngine = SearchEngine(rawValue: d.string(forKey: "nt.engine") ?? "") ?? .duckduckgo
        if d.object(forKey: "nt.desktop") != nil { requestDesktop = d.bool(forKey: "nt.desktop") }
        if d.object(forKey: "nt.natural") != nil { naturalScroll = d.bool(forKey: "nt.natural") }
        if d.object(forKey: "nt.dockZoom") != nil { dockZoom = d.bool(forKey: "nt.dockZoom") }
        if d.object(forKey: "nt.dockHide") != nil { dockAutoHide = d.bool(forKey: "nt.dockHide") }
        customWallpaper = UIImage(contentsOfFile: Settings.wallpaperURL.path)
        if customWallpaper == nil && wallpaper < 0 { wallpaper = 0 }
        ready = true
    }

    // MARK: Wallpaper

    func nextWallpaper() {
        wallpaper = wallpaper < 0 ? 0 : (wallpaper + 1) % Wallpapers.all.count
    }

    func setCustomWallpaper(_ img: UIImage) {
        let maxSide: CGFloat = 2560
        let k = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        let f = UIGraphicsImageRendererFormat.default()
        f.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: f).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        try? small.jpegData(compressionQuality: 0.85)?.write(to: Settings.wallpaperURL)
        customWallpaper = small
        wallpaper = -1
    }

    func clearCustomWallpaper() {
        try? FileManager.default.removeItem(at: Settings.wallpaperURL)
        customWallpaper = nil
        if wallpaper < 0 { wallpaper = 0 }
    }

    // MARK: Black screen (a real toggle; always restores brightness)

    private func applyBlackout() {
        if blackout {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            UIScreen.main.brightness = savedBrightness
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Restore brightness whenever the app leaves the foreground so it can never get stuck dark.
    func sceneChanged(active: Bool) {
        guard blackout else { return }
        UIScreen.main.brightness = active ? 0 : savedBrightness
    }

    // MARK: Browser data

    func clearBrowsingData(_ done: (() -> Void)? = nil) {
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: .distantPast) { done?() }
    }

    // MARK: Factory reset

    func factoryReset() {
        blackout = false
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        RootsStore.shared.external.forEach { $0.url.stopAccessingSecurityScopedResource() }
        RootsStore.shared.external = []
        try? FileManager.default.removeItem(at: Settings.wallpaperURL)
        try? FileManager.default.removeItem(at: FileStore.root)
        FileStore.seed()
        clearBrowsingData()

        trackingSpeed = 1.0
        pointerStyle = .arrow
        cursorSize = 1
        wallpaper = 0
        customWallpaper = nil
        homepage = "duckduckgo.com"
        searchEngine = .duckduckgo
        requestDesktop = true
        naturalScroll = true
        dockZoom = true
        dockAutoHide = false
        scale = 0
        Desktop.shared.reset()
    }
}

// MARK: - iPhone settings page

struct SettingsSheet: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var desktop = Desktop.shared
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var confirmReset = false
    @State private var cleared = false
    @ObservedObject private var roots = RootsStore.shared
    @State private var showImporter = false
    @State private var importMode = ImportMode.folder
    @State private var picks: [PhotosPickerItem] = []
    @State private var importNote: String?

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                pointerSection
                wallpaperSection
                filesSection
                browserSection
                screenSection
                resetSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: importMode == .folder ? [.folder] : [.item],
                          allowsMultipleSelection: importMode == .files) { result in
                guard case .success(let urls) = result else { return }
                if importMode == .folder {
                    urls.forEach { roots.add($0) }
                    importNote = "Folder added. It now shows in Files, Music and Videos."
                } else {
                    importNote = "Imported \(Importer.copy(urls)) file(s)."
                }
            }
            .onChange(of: picks) { items in
                guard !items.isEmpty else { return }
                Task { await importPhotos(items) }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var n = 0
        for it in items {
            if (try? await it.loadTransferable(type: MovieFile.self)) != nil { n += 1; continue }
            if let d = try? await it.loadTransferable(type: Data.self), Importer.saveImage(d) { n += 1 }
        }
        importNote = "Imported \(n) item(s) from Photos."
        picks = []
    }

    // MARK: Files

    private var filesSection: some View {
        Section {
            Button { importMode = .folder; showImporter = true } label: {
                Label("Add iPhone folder…", systemImage: "folder.badge.plus")
            }
            ForEach(roots.external) { r in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.cyan)
                    Text(r.name)
                    Spacer()
                    Button(role: .destructive) { roots.remove(r) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            Button { importMode = .files; showImporter = true } label: {
                Label("Import files…", systemImage: "square.and.arrow.down")
            }
            PhotosPicker(selection: $picks, matching: .any(of: [.images, .videos])) {
                Label("Import photos & videos…", systemImage: "photo.on.rectangle.angled")
            }
            if let n = importNote { Text(n).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Files") } footer: {
            Text("iOS only lets an app see folders you choose. Add Downloads, iCloud Drive, a Music folder… and they appear in Files, Music and Videos on the big screen.")
        }
    }

    // MARK: Display

    private var displaySection: some View {
        Section {
            Toggle("Auto scale (recommended)", isOn: Binding(
                get: { s.scale == 0 },
                set: { s.scale = $0 ? 0 : Double(desktop.uiScale) }))
            if s.scale != 0 {
                HStack {
                    Text("Interface scale")
                    Spacer()
                    Text("\(Int((s.scale * 100).rounded()))%").foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { s.scale },
                                      set: { s.scale = ($0 * 10).rounded() / 10 }),
                       in: 0.7...2.5, step: 0.1)
            }
            Toggle("Magnify dock icons", isOn: $s.dockZoom)
            Toggle("Auto-hide dock", isOn: $s.dockAutoHide)
        } header: { Text("Display") } footer: {
            Text(s.scale == 0
                 ? "Auto picks a comfortable size for the connected display (now \(Int((desktop.uiScale * 100).rounded()))%)."
                 : "Custom scale. Turn on Auto to restore the recommended size.")
        }
    }

    // MARK: Pointer

    private var pointerSection: some View {
        Section("Pointer") {
            Toggle("Natural scrolling (trackpad and mouse)", isOn: $s.naturalScroll)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Tracking speed")
                    Spacer()
                    Text(String(format: "%.1f×", s.trackingSpeed)).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { s.trackingSpeed },
                                      set: { s.trackingSpeed = ($0 * 10).rounded() / 10 }),
                       in: 0.3...3, step: 0.1)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Style")
                HStack(spacing: 8) {
                    ForEach(PointerStyle.allCases) { st in
                        tile(selected: s.pointerStyle == st) {
                            VStack(spacing: 4) {
                                PointerGlyph(style: st)
                                Text(st.title).font(.caption2)
                            }
                        }
                        .onTapGesture { s.pointerStyle = st }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Size")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(0..<Settings.cursorSizes.count, id: \.self) { i in
                        tile(selected: s.cursorSize == i) {
                            VStack(spacing: 2) {
                                PointerGlyph(style: s.pointerStyle)
                                    .scaleEffect(Settings.cursorSizes[i] * 0.5)
                                    .frame(height: 40)
                                Text("\(i + 1)").font(.caption2)
                            }
                        }
                        .onTapGesture { s.cursorSize = i }
                    }
                }
            }
        }
    }

    private func tile<C: View>(selected: Bool, @ViewBuilder _ c: () -> C) -> some View {
        c()
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.blue.opacity(0.4) : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white, lineWidth: selected ? 2 : 0))
            .contentShape(Rectangle())
    }

    // MARK: Wallpaper

    private var wallpaperSection: some View {
        Section("Wallpaper") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(0..<Wallpapers.all.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: Wallpapers.all[i], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white, lineWidth: s.wallpaper == i ? 3 : 0))
                        .onTapGesture { s.wallpaper = i }
                }
                ZStack {
                    if let img = s.customWallpaper {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.08)
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white, lineWidth: s.wallpaper == -1 ? 3 : 0))
                .onTapGesture { if s.customWallpaper != nil { s.wallpaper = -1 } }
            }
            PhotosPicker(selection: $photo, matching: .images) {
                Label("Choose custom wallpaper…", systemImage: "photo.on.rectangle")
            }
            .onChange(of: photo) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        await MainActor.run { s.setCustomWallpaper(img); photo = nil }
                    }
                }
            }
            if s.customWallpaper != nil {
                Button("Remove custom wallpaper", role: .destructive) { s.clearCustomWallpaper() }
            }
        }
    }

    // MARK: Browser

    private var browserSection: some View {
        Section("Browser") {
            HStack {
                Text("Homepage")
                TextField("duckduckgo.com", text: $s.homepage)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            Picker("Search engine", selection: $s.searchEngine) {
                ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Request desktop sites", isOn: $s.requestDesktop)
            Button(cleared ? "Cleared ✓" : "Clear browsing data") {
                s.clearBrowsingData { cleared = true }
            }
        }
    }

    // MARK: Screen / reset

    private var screenSection: some View {
        Section {
            Toggle(isOn: $s.blackout) { Label("Black screen", systemImage: "moon.fill") }
        } footer: {
            Text("Turns the iPhone display black while the desktop keeps running. Toggle it off here, with the moon button, or with a three-finger tap.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to factory defaults…", role: .destructive) { confirmReset = true }
        } footer: {
            Text("Erases settings, files, notes, browser data and open windows.")
        }
        .confirmationDialog("Erase everything and reset NanoTower?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase & Reset", role: .destructive) { s.factoryReset() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

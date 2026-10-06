import SwiftUI
import UIKit
import Combine

// MARK: - Sandbox file store shared by Files + Terminal

enum FileStore {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NanoFiles", isDirectory: true)
    }

    static func seed() {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for d in ["Documents", "Pictures", "Videos", "Music", "Downloads"] {
            try? fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        let welcome = root.appendingPathComponent("Documents/Welcome.txt")
        if !fm.fileExists(atPath: welcome.path) {
            try? "Welcome to NanoTower Files.\n\nDouble-click to open. Music and videos open in their players.\nAdd folders from your iPhone in Settings → Files on the phone.\n"
                .write(to: welcome, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Model

final class FilesModel: AppModel {
    struct Item: Identifiable {
        let url: URL
        let isDir: Bool
        let size: Int64
        let date: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
        var media: MediaKind? { isDir ? nil : MediaTypes.kind(url) }
        var isImage: Bool { media == .image }
    }
    enum Prompt { case folder, file, rename(URL) }

    @Published var cwd: URL = FileStore.root
    @Published var items: [Item] = []
    @Published var selected: URL?
    @Published var top = 0
    @Published var prompt: Prompt?
    @Published var input = ""
    @Published var confirmDelete = false
    @Published var note: String?
    @Published var editURL: URL?
    @Published var text = "" {
        didSet { if let u = editURL { try? text.write(to: u, atomically: true, encoding: .utf8) } }
    }
    @Published var image: UIImage?
    @Published var imageURL: URL?

    private var accum = ScrollAccumulator()
    private var lastClick: (URL, Date)?

    override init() {
        super.init()
        FileStore.seed()
        reload()
    }

    var root: Root { RootsStore.shared.root(containing: cwd) }
    var inViewer: Bool { editURL != nil || image != nil }
    var selectedItem: Item? { items.first { $0.url == selected } }
    var atRoot: Bool { cwd.path == root.url.path }

    var crumbs: String {
        let r = root
        let rel = cwd.path.replacingOccurrences(of: r.url.path, with: "")
        return rel.isEmpty ? r.name : r.name + "  ›  " + rel.dropFirst().replacingOccurrences(of: "/", with: "  ›  ")
    }

    func reload() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: cwd, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        items = urls.map { u -> Item in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Item(url: u, isDir: v?.isDirectory ?? false,
                        size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate ?? Date())
        }
        .sorted { a, b in
            a.isDir != b.isDir ? a.isDir : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if let s = selected, !items.contains(where: { $0.url == s }) { selected = nil }
        top = min(top, max(0, items.count - 1))
    }

    func go(to url: URL) {
        closeViewer()
        cwd = url
        selected = nil
        top = 0
        prompt = nil
        confirmDelete = false
        note = nil
        reload()
    }

    func up() { if !atRoot { go(to: cwd.deletingLastPathComponent()) } }

    func click(_ it: Item) {
        if let l = lastClick, l.0 == it.url, Date().timeIntervalSince(l.1) < 0.5 {
            lastClick = nil
            open(it)
        } else {
            lastClick = (it.url, Date())
            selected = it.url
        }
    }

    func open(_ it: Item) {
        note = nil
        if it.isDir { go(to: it.url); return }
        switch it.media {
        case .audio?, .video?:
            let same = items.filter { $0.media == it.media }.map { $0.url }
            Desktop.shared.openMedia(it.url, playlist: same)
            return
        case .image?:
            if let img = UIImage(contentsOfFile: it.url.path) { image = img; imageURL = it.url; return }
        default: break
        }
        if let s = try? String(contentsOf: it.url, encoding: .utf8) {
            text = s          // set before editURL so we don't rewrite the file
            editURL = it.url
        } else {
            note = "Can't preview “\(it.name)”"
        }
    }

    func closeViewer() { editURL = nil; image = nil; imageURL = nil }

    func setWallpaper() {
        if let img = image { Settings.shared.setCustomWallpaper(img); note = "Wallpaper updated" }
    }

    private func unique(_ name: String) -> URL { Importer.unique(cwd, name) }

    func begin(_ p: Prompt) {
        switch p {
        case .folder: input = "New Folder"
        case .file: input = "Untitled.txt"
        case .rename(let u): input = u.lastPathComponent
        }
        prompt = p
        confirmDelete = false
    }

    func commitPrompt() {
        let name = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        defer { prompt = nil }
        guard !name.isEmpty, let p = prompt else { return }
        let fm = FileManager.default
        switch p {
        case .folder:
            try? fm.createDirectory(at: unique(name), withIntermediateDirectories: false)
        case .file:
            try? "".write(to: unique(name), atomically: true, encoding: .utf8)
        case .rename(let u):
            let dest = u.deletingLastPathComponent().appendingPathComponent(name)
            if dest != u, !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: u, to: dest)
                selected = dest
            }
        }
        reload()
    }

    func doDelete() {
        if let s = selected { try? FileManager.default.removeItem(at: s) }
        selected = nil
        confirmDelete = false
        reload()
    }

    private func move(_ d: Int) {
        guard !items.isEmpty else { return }
        let i = items.firstIndex { $0.url == selected } ?? (d > 0 ? -1 : items.count)
        let n = min(max(i + d, 0), items.count - 1)
        selected = items[n].url
        if n < top { top = n }
    }

    // MARK: Input

    override func insert(_ s: String) {
        if prompt != nil { input += s }
        else if editURL != nil { text += s }
    }

    override func special(_ k: SpecialKey) {
        if prompt != nil {
            switch k {
            case .enter: commitPrompt()
            case .escape: prompt = nil
            case .backspace: input = String(input.dropLast())
            default: break
            }
            return
        }
        if confirmDelete {
            if k == .enter { doDelete() } else if k == .escape { confirmDelete = false }
            return
        }
        if editURL != nil {
            switch k {
            case .enter: text += "\n"
            case .backspace: if !text.isEmpty { text.removeLast() }
            case .tab: text += "    "
            case .escape: closeViewer(); reload()
            default: break
            }
            return
        }
        if image != nil {
            if k == .escape || k == .backspace { closeViewer() }
            return
        }
        switch k {
        case .up: move(-1)
        case .down: move(1)
        case .enter: if let it = selectedItem { open(it) }
        case .backspace: up()
        case .escape: selected = nil
        default: break
        }
    }

    override func scroll(_ dy: CGFloat) {
        guard !inViewer else { return }
        let n = accum.feed(dy, step: 24)
        if n != 0 { top = min(max(top + n, 0), max(0, items.count - 1)) }
    }

    override func copyText() -> String? { editURL != nil ? text : nil }
}

// MARK: - View

struct FilesView: View {
    @ObservedObject var model: FilesModel
    @ObservedObject private var roots = RootsStore.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 170)
            VStack(spacing: 0) {
                toolbar
                if let p = model.prompt { promptBar(p) }
                if model.confirmDelete, let s = model.selectedItem { confirmBar(s) }
                if let n = model.note {
                    Text(n).font(.system(size: 12)).foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 4)
                }
                content
            }
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.11))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            header("FAVORITES")
            side("house.fill", "Home", FileStore.root)
            side("doc.fill", "Documents", FileStore.root.appendingPathComponent("Documents"))
            side("photo.fill", "Pictures", FileStore.root.appendingPathComponent("Pictures"))
            side("film.fill", "Videos", FileStore.root.appendingPathComponent("Videos"))
            side("music.note", "Music", FileStore.root.appendingPathComponent("Music"))
            side("arrow.down.circle.fill", "Downloads", FileStore.root.appendingPathComponent("Downloads"))
            header("ON YOUR iPHONE").padding(.top, 10)
            ForEach(roots.external) { r in side("folder.fill", r.name, r.url) }
            if roots.external.isEmpty {
                Text("Add folders in Settings on the iPhone")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 4)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.15))
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).padding(.bottom, 2)
    }

    private func side(_ icon: String, _ title: String, _ url: URL) -> some View {
        let on = model.cwd.path == url.path
        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.cyan).frame(width: 20)
            Text(title).font(.system(size: 14)).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white.opacity(0.14) : Color.clear))
        .clickable { model.go(to: url) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            pill(model.inViewer ? "chevron.left" : "arrow.up", nil,
                 enabled: model.inViewer || !model.atRoot) {
                if model.inViewer { model.closeViewer(); model.reload() } else { model.up() }
            }
            Text(model.inViewer ? (model.editURL ?? model.imageURL)?.lastPathComponent ?? "" : model.crumbs)
                .font(.system(size: 14, weight: .medium)).lineLimit(1)
            Spacer()
            if model.image != nil {
                pill("photo.badge.plus", "Set as wallpaper") { model.setWallpaper() }
            } else if model.editURL == nil {
                pill("folder.badge.plus", nil) { model.begin(.folder) }
                pill("doc.badge.plus", nil) { model.begin(.file) }
                pill("pencil", nil, enabled: model.selected != nil) {
                    if let s = model.selected { model.begin(.rename(s)) }
                }
                pill("trash", nil, enabled: model.selected != nil) { model.confirmDelete = true; model.prompt = nil }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(white: 0.14))
    }

    private func pill(_ icon: String, _ title: String?, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            if let t = title { Text(t).font(.system(size: 13, weight: .medium)) }
        }
        .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.3))
        .padding(.horizontal, 10)
        .frame(minWidth: 32, minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
        .clickable { if enabled { action() } }
    }

    private func promptBar(_ p: FilesModel.Prompt) -> some View {
        HStack(spacing: 8) {
            Text("Name:").font(.system(size: 13)).opacity(0.6)
            Text(model.input + "▏").font(.system(size: 14))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.blue, lineWidth: 1.5))
            pill("checkmark", "OK") { model.commitPrompt() }
            pill("xmark", nil) { model.prompt = nil }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(white: 0.17))
    }

    private func confirmBar(_ it: FilesModel.Item) -> some View {
        HStack(spacing: 8) {
            Text("Delete “\(it.name)”?").font(.system(size: 13))
            Spacer()
            pill("trash", "Delete") { model.doDelete() }
            pill("xmark", "Cancel") { model.confirmDelete = false }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.red.opacity(0.25))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.editURL != nil {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.text + "▏")
                            .font(.system(size: 16, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                }
                .onChange(of: model.text) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .background(Color(white: 0.09))
        } else if let img = model.image {
            Image(uiImage: img).resizable().scaledToFit()
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 2) {
            if model.items.isEmpty {
                Text("This folder is empty").font(.system(size: 14)).opacity(0.4).padding(.top, 40)
            }
            ForEach(Array(model.items.dropFirst(model.top).prefix(60))) { it in row(it) }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private func icon(_ it: FilesModel.Item) -> (String, Color) {
        if it.isDir { return ("folder.fill", .yellow) }
        switch it.media {
        case .audio?: return ("music.note", .green)
        case .video?: return ("play.rectangle.fill", .purple)
        case .image?: return ("photo", .pink)
        case nil: return ("doc.text", .cyan)
        }
    }

    private func row(_ it: FilesModel.Item) -> some View {
        let on = model.selected == it.url
        let ic = icon(it)
        return HStack(spacing: 10) {
            Image(systemName: ic.0).foregroundStyle(ic.1).frame(width: 22)
            Text(it.name).font(.system(size: 14)).lineLimit(1)
            Spacer()
            Text(it.isDir ? "—" : ByteCountFormatter.string(fromByteCount: it.size, countStyle: .file))
                .font(.system(size: 12)).opacity(0.5).frame(width: 70, alignment: .trailing)
            Text(it.date.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 12)).opacity(0.5).frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.blue.opacity(0.4) : Color.clear))
        .clickable { model.click(it) }
    }
}

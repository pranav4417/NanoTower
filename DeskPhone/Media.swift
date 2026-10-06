import SwiftUI
import UIKit
import Combine
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Media types

enum MediaKind { case audio, video, image }

enum MediaTypes {
    static let audio: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac"]
    static let video: Set<String> = ["mp4", "m4v", "mov"]
    static let image: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]

    static func exts(_ k: MediaKind) -> Set<String> {
        switch k {
        case .audio: return audio
        case .video: return video
        case .image: return image
        }
    }
    static func kind(_ u: URL) -> MediaKind? {
        let e = u.pathExtension.lowercased()
        if audio.contains(e) { return .audio }
        if video.contains(e) { return .video }
        if image.contains(e) { return .image }
        return nil
    }
}

// MARK: - Folders the user granted from the iPhone (iOS only lets apps see what you pick)

struct Root: Identifiable, Equatable {
    let id: String
    let url: URL
    let name: String
    let external: Bool
}

final class RootsStore: ObservableObject {
    static let shared = RootsStore()
    @Published var external: [Root] = []

    private init() { reload() }

    var all: [Root] { [Root(id: "home", url: FileStore.root, name: "Home", external: false)] + external }

    /// The root that contains `url`
    func root(containing url: URL) -> Root {
        all.filter { url.path == $0.url.path || url.path.hasPrefix($0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count } ?? all[0]
    }

    func reload() {
        let dict = UserDefaults.standard.dictionary(forKey: "nt.folders") as? [String: Data] ?? [:]
        var res: [Root] = []
        for (key, data) in dict.sorted(by: { $0.key < $1.key }) {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = u.startAccessingSecurityScopedResource()
                res.append(Root(id: key, url: u, name: u.lastPathComponent, external: true))
            }
        }
        external = res
    }

    func add(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var dict = UserDefaults.standard.dictionary(forKey: "nt.folders") as? [String: Data] ?? [:]
        dict[url.path] = data
        UserDefaults.standard.set(dict, forKey: "nt.folders")
        if !external.contains(where: { $0.id == url.path }) {
            external.append(Root(id: url.path, url: url, name: url.lastPathComponent, external: true))
        }
    }

    func remove(_ r: Root) {
        r.url.stopAccessingSecurityScopedResource()
        var dict = UserDefaults.standard.dictionary(forKey: "nt.folders") as? [String: Data] ?? [:]
        dict.removeValue(forKey: r.id)
        UserDefaults.standard.set(dict, forKey: "nt.folders")
        external.removeAll { $0.id == r.id }
    }
}

// MARK: - Library scan (background)

enum MediaLibrary {
    static func scan(_ kind: MediaKind, completion: @escaping ([URL]) -> Void) {
        let roots = RootsStore.shared.all.map { $0.url }
        let exts = MediaTypes.exts(kind)
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [URL] = []
            let fm = FileManager.default
            for r in roots {
                guard let en = fm.enumerator(at: r, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let u as URL in en {
                    if en.level > 5 { en.skipDescendants(); continue }
                    if exts.contains(u.pathExtension.lowercased()) { found.append(u) }
                    if found.count >= 600 { break }
                }
            }
            found.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            DispatchQueue.main.async { completion(found) }
        }
    }
}

// MARK: - Importing from the iPhone (Files app / Photos)

enum ImportMode { case folder, files }

enum Importer {
    static func unique(_ dir: URL, _ name: String) -> URL {
        var u = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return u
    }

    static func folder(for url: URL) -> String {
        switch MediaTypes.kind(url) {
        case .audio?: return "Music"
        case .video?: return "Videos"
        case .image?: return "Pictures"
        case nil: return "Downloads"
        }
    }

    @discardableResult
    static func copy(_ urls: [URL]) -> Int {
        FileStore.seed()
        var n = 0
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dir = FileStore.root.appendingPathComponent(folder(for: u))
            if (try? FileManager.default.copyItem(at: u, to: unique(dir, u.lastPathComponent))) != nil { n += 1 }
        }
        return n
    }

    static func saveImage(_ data: Data) -> Bool {
        FileStore.seed()
        guard let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.92) else { return false }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = FileStore.root.appendingPathComponent("Pictures")
        return (try? jpg.write(to: unique(dir, "Photo-\(f.string(from: Date())).jpg"))) != nil
    }
}

/// Lets PhotosPicker hand us a video as a file instead of loading it into memory.
struct MovieFile: Transferable, Sendable {
    let url: URL
    nonisolated static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NanoFiles/Videos", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var dest = dir.appendingPathComponent(received.file.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent(UUID().uuidString + "-" + received.file.lastPathComponent)
            }
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

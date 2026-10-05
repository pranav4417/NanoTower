import SwiftUI
import UIKit
import Combine

final class TerminalModel: AppModel {
    @Published var lines: [String] = []
    @Published var input = ""
    @Published var cwd: URL = FileStore.root

    private var history: [String] = []
    private var hIndex = 0
    private var root: URL { FileStore.root }

    override init() {
        super.init()
        FileStore.seed()
        lines = ["NanoTower Terminal  —  type 'help' for commands", ""]
    }

    var prompt: String {
        let rel = cwd.path.replacingOccurrences(of: root.path, with: "")
        return "nano@tower " + (rel.isEmpty ? "~" : "~" + rel) + " % "
    }

    // MARK: Input

    override func insert(_ s: String) { input += s.replacingOccurrences(of: "\n", with: " ") }

    override func special(_ k: SpecialKey) {
        switch k {
        case .enter: run(input)
        case .backspace: input = String(input.dropLast())
        case .escape: input = ""
        case .tab: complete()
        case .up:
            if !history.isEmpty { hIndex = max(0, hIndex - 1); input = history[hIndex] }
        case .down:
            if hIndex < history.count - 1 { hIndex += 1; input = history[hIndex] } else { hIndex = history.count; input = "" }
        default: break
        }
    }

    override func copyText() -> String? { lines.joined(separator: "\n") }

    // MARK: Engine

    private func out(_ s: String) {
        lines.append(contentsOf: s.components(separatedBy: "\n"))
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
    }

    private func tokens(_ s: String) -> [String] {
        var res: [String] = [], cur = ""
        var q: Character? = nil
        for ch in s {
            if let qq = q { if ch == qq { q = nil } else { cur.append(ch) } }
            else if ch == "\"" || ch == "'" { q = ch }
            else if ch == " " { if !cur.isEmpty { res.append(cur); cur = "" } }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { res.append(cur) }
        return res
    }

    private func resolve(_ a: String) -> URL {
        var u: URL = (a.hasPrefix("/") || a.hasPrefix("~")) ? root : cwd
        var comps = a.split(separator: "/").map(String.init)
        if comps.first == "~" { comps.removeFirst() }
        for c in comps {
            switch c {
            case ".": continue
            case "..": if u.path != root.path { u = u.deletingLastPathComponent() }
            default: u.appendPathComponent(c)
            }
        }
        return u
    }

    private func isDir(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    private func complete() {
        guard let last = input.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) else { return }
        let dirPart = (last as NSString).deletingLastPathComponent
        let base = (last as NSString).lastPathComponent
        let dir = resolve(dirPart.isEmpty ? "." : dirPart)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(base) && !$0.hasPrefix(".") }.sorted()
        if names.count == 1, let n = names.first {
            let prefix = dirPart.isEmpty ? "" : dirPart + "/"
            input = String(input.dropLast(last.count)) + prefix + n + (isDir(dir.appendingPathComponent(n)) ? "/" : "")
        } else if names.count > 1 {
            out(prompt + input); out(names.joined(separator: "  "))
        }
    }

    private func run(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        out(prompt + line)
        input = ""
        guard !t.isEmpty else { return }
        history.append(t); hIndex = history.count
        let parts = tokens(t)
        guard let cmd = parts.first else { return }
        let a = Array(parts.dropFirst())
        let fm = FileManager.default

        switch cmd {
        case "help":
            out("""
            help             this list
            ls [-l] [dir]    list files        cd <dir>       change directory
            pwd              current folder    cat <file>     show a file
            mkdir <dir>      new folder        touch <file>   new empty file
            rm [-r] <path>   delete            mv/cp <a> <b>  move / copy
            echo <text> [> file]               write text
            open <app>       launch an app     wallpaper <img> set wallpaper
            neofetch  date  whoami  uname  history  clear
            """)
        case "clear": lines = []
        case "pwd": out("~" + cwd.path.replacingOccurrences(of: root.path, with: ""))
        case "whoami": out("nano")
        case "date": out(Date().formatted(date: .complete, time: .standard))
        case "uname": out("NanoTower \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        case "history": out(history.enumerated().map { "\($0.offset + 1)  \($0.element)" }.joined(separator: "\n"))
        case "neofetch":
            let d = Desktop.shared
            out("""
            nano@tower
            ----------
            OS:       \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
            Host:     \(UIDevice.current.model)
            Display:  \(Int(d.physicalScreen.width))×\(Int(d.physicalScreen.height)) @ \(Int((d.uiScale * 100).rounded()))%
            Windows:  \(d.windows.count)
            """)
        case "cd":
            let u = a.isEmpty ? root : resolve(a[0])
            if isDir(u) { cwd = u } else { out("cd: no such directory: \(a.first ?? "")") }
        case "ls":
            let long = a.contains("-l") || a.contains("-la") || a.contains("-al")
            let u = resolve(a.first { !$0.hasPrefix("-") } ?? ".")
            guard fm.fileExists(atPath: u.path) else { out("ls: no such file or directory"); return }
            if !isDir(u) { out(u.lastPathComponent); return }
            let names = ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            if names.isEmpty { return }
            if long {
                out(names.map { n -> String in
                    let p = u.appendingPathComponent(n)
                    let d = isDir(p)
                    let size = (try? fm.attributesOfItem(atPath: p.path)[.size] as? Int) ?? 0
                    let sz = String(d ? 0 : size).padding(toLength: 8, withPad: " ", startingAt: 0)
                    return "\(d ? "d" : "-") \(sz) \(d ? n + "/" : n)"
                }.joined(separator: "\n"))
            } else {
                out(names.map { isDir(u.appendingPathComponent($0)) ? $0 + "/" : $0 }.joined(separator: "  "))
            }
        case "cat":
            guard let f = a.first else { out("usage: cat <file>"); return }
            if let s = try? String(contentsOf: resolve(f), encoding: .utf8) { out(s.trimmingCharacters(in: .newlines)) }
            else { out("cat: can't read \(f)") }
        case "mkdir":
            for n in a { do { try fm.createDirectory(at: resolve(n), withIntermediateDirectories: true) } catch { out("mkdir: \(n): failed") } }
        case "touch":
            for n in a { let u = resolve(n); if !fm.fileExists(atPath: u.path) { try? "".write(to: u, atomically: true, encoding: .utf8) } }
        case "rm":
            let rec = a.contains("-r") || a.contains("-rf")
            for n in a where !n.hasPrefix("-") {
                let u = resolve(n)
                if u.path == root.path { out("rm: refusing to delete home"); continue }
                if isDir(u) && !rec { out("rm: \(n): is a directory (use -r)"); continue }
                do { try fm.removeItem(at: u) } catch { out("rm: \(n): no such file") }
            }
        case "mv", "cp":
            guard a.count == 2 else { out("usage: \(cmd) <from> <to>"); return }
            let src = resolve(a[0])
            var dst = resolve(a[1])
            if isDir(dst) { dst.appendPathComponent(src.lastPathComponent) }
            do {
                if cmd == "mv" { try fm.moveItem(at: src, to: dst) } else { try fm.copyItem(at: src, to: dst) }
            } catch { out("\(cmd): failed") }
        case "echo":
            if let i = a.firstIndex(where: { $0 == ">" || $0 == ">>" }), i + 1 < a.count {
                let u = resolve(a[i + 1])
                let text = a[..<i].joined(separator: " ") + "\n"
                if a[i] == ">>", let old = try? String(contentsOf: u, encoding: .utf8) {
                    try? (old + text).write(to: u, atomically: true, encoding: .utf8)
                } else {
                    try? text.write(to: u, atomically: true, encoding: .utf8)
                }
            } else {
                out(a.joined(separator: " "))
            }
        case "open":
            let name = (a.first ?? "").lowercased()
            if let k = AppKind.allCases.first(where: { $0.rawValue == name || $0.title.lowercased() == name }) {
                Desktop.shared.launch(k)
            } else { out("open: unknown app. Try: " + AppKind.allCases.map { $0.rawValue }.joined(separator: ", ")) }
        case "wallpaper":
            guard let f = a.first, let img = UIImage(contentsOfFile: resolve(f).path) else { out("usage: wallpaper <image file>"); return }
            Settings.shared.setCustomWallpaper(img)
            out("wallpaper set")
        default:
            out("\(cmd): command not found")
        }
    }
}

struct TerminalView: View {
    @ObservedObject var model: TerminalModel
    private let mono = Font.system(size: 15, design: .monospaced)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, l in
                        Text(l.isEmpty ? " " : l)
                            .font(mono)
                            .foregroundColor(Color(white: 0.88))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    (Text(model.prompt).foregroundColor(.green) + Text(model.input + "█").foregroundColor(.white))
                        .font(mono)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onChange(of: model.lines.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.input) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(Color(white: 0.06))
    }
}

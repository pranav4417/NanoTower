import SwiftUI
import AVFoundation
import Combine

/// Fast-changing values live here so only the meters / seek bar redraw ~30×/s.
final class AudioMeter: ObservableObject {
    @Published var l: Float = 0
    @Published var r: Float = 0
    @Published var time: Double = 0
}

// MARK: - Model

final class AudioModel: AppModel {
    let meter = AudioMeter()
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var accum = ScrollAccumulator()

    @Published var url: URL?
    @Published var title = "No track"
    @Published var artist = ""
    @Published var album = ""
    @Published var artwork: UIImage?
    @Published var format = ""
    @Published var tags: [String] = []
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var volume: Float = 0.8
    @Published var shuffle = false
    @Published var repeatMode = 1          // 0 off, 1 all, 2 one
    @Published var queue: [URL] = []
    @Published var top = 0

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        refresh()
    }

    var index: Int { url.flatMap { queue.firstIndex(of: $0) } ?? 0 }

    func refresh() {
        MediaLibrary.scan(.audio) { [weak self] urls in
            guard let self else { return }
            if self.queue.isEmpty || self.url == nil { self.queue = urls }
        }
    }

    // MARK: Playback

    func play(_ u: URL, queue q: [URL] = []) {
        if !q.isEmpty { queue = q } else if !queue.contains(u) { queue.append(u) }
        open(u)
    }

    private func open(_ u: URL) {
        do {
            let p = try AVAudioPlayer(contentsOf: u)
            p.isMeteringEnabled = true
            p.volume = volume
            p.prepareToPlay()
            player?.stop()
            player = p
            url = u
            duration = p.duration
            title = u.deletingPathExtension().lastPathComponent
            artist = ""; album = ""; artwork = nil
            describe(u, p)
            loadMetadata(u)
            p.play()
            isPlaying = true
            startTimer()
            if let i = queue.firstIndex(of: u), i < top || i > top + 4 { top = max(0, i - 1) }
        } catch {
            title = "Can't play “\(u.lastPathComponent)”"
            isPlaying = false
        }
    }

    private func describe(_ u: URL, _ p: AVAudioPlayer) {
        let ext = u.pathExtension.uppercased()
        let sr = p.format.sampleRate
        var bits = 0
        if let f = try? AVAudioFile(forReading: u), let b = f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int { bits = b }
        let srText = sr.truncatingRemainder(dividingBy: 1000) == 0 ? String(format: "%.0f", sr / 1000) : String(format: "%.1f", sr / 1000)
        format = ext + " · " + srText + " kHz" + (bits > 0 ? " · \(bits)-bit" : "")
        let lossless = ["FLAC", "WAV", "AIF", "AIFF", "ALAC", "CAF"].contains(ext)
        var t: [String] = []
        if lossless && (sr >= 88200 || bits >= 24) { t.append("HI-RES") }
        if lossless { t.append("LOSSLESS") }
        tags = t
    }

    private func loadMetadata(_ u: URL) {
        Task {
            let asset = AVURLAsset(url: u)
            guard let items = try? await asset.load(.commonMetadata) else { return }
            for it in items {
                guard let key = it.commonKey?.rawValue else { continue }
                switch key {
                case "title": if let v = try? await it.load(.stringValue), url == u { title = v }
                case "artist": if let v = try? await it.load(.stringValue), url == u { artist = v }
                case "albumName": if let v = try? await it.load(.stringValue), url == u { album = v }
                case "artwork":
                    if let d = try? await it.load(.dataValue), let img = UIImage(data: d), url == u { artwork = img }
                default: break
                }
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    private func level(_ db: Float) -> Float { max(0, min(1, (db + 48) / 48)) }

    private func tick() {
        guard let p = player else { return }
        if isPlaying && !p.isPlaying { trackEnded(); return }
        p.updateMeters()
        let l = level(p.averagePower(forChannel: 0))
        let r = p.numberOfChannels > 1 ? level(p.averagePower(forChannel: 1)) : l
        meter.l += (l - meter.l) * (l > meter.l ? 0.55 : 0.12)   // needle ballistics
        meter.r += (r - meter.r) * (r > meter.r ? 0.55 : 0.12)
        meter.time = p.currentTime
    }

    private func trackEnded() {
        if repeatMode == 2 { player?.currentTime = 0; player?.play(); return }
        next(auto: true)
    }

    func toggle() {
        guard let p = player else {
            if let f = queue.first { play(f) }
            return
        }
        if p.isPlaying {
            p.pause(); isPlaying = false
            timer?.invalidate(); timer = nil
            meter.l = 0; meter.r = 0
        } else {
            p.play(); isPlaying = true; startTimer()
        }
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        var n = index + 1
        if shuffle && queue.count > 1 { repeat { n = Int.random(in: 0..<queue.count) } while n == index }
        if n >= queue.count {
            if repeatMode == 1 || !auto { n = 0 } else { stop(); return }
        }
        open(queue[n])
    }

    func prev() {
        if (player?.currentTime ?? 0) > 3 { seek(to: 0); return }
        guard !queue.isEmpty else { return }
        open(queue[(index - 1 + queue.count) % queue.count])
    }

    func stop() {
        player?.stop(); player?.currentTime = 0
        isPlaying = false
        timer?.invalidate(); timer = nil
        meter.l = 0; meter.r = 0; meter.time = 0
    }

    func seek(to s: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(s, p.duration))
        meter.time = p.currentTime
    }
    func seek(fraction: Double) { seek(to: duration * fraction) }

    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        player?.volume = volume
    }

    func cycleRepeat() { repeatMode = (repeatMode + 1) % 3 }

    // MARK: Input

    override func insert(_ s: String) {
        switch s.lowercased() {
        case " ": toggle()
        case "n": next()
        case "p": prev()
        case "s": shuffle.toggle()
        case "r": cycleRepeat()
        default: break
        }
    }

    override func special(_ k: SpecialKey) {
        switch k {
        case .enter: toggle()
        case .left: seek(to: meter.time - 5)
        case .right: seek(to: meter.time + 5)
        case .up: setVolume(volume + 0.05)
        case .down: setVolume(volume - 0.05)
        default: break
        }
    }

    override func scroll(_ dy: CGFloat) {
        let n = accum.feed(dy, step: 28)
        if n != 0 { top = min(max(top + n, 0), max(0, queue.count - 1)) }
    }
}

// MARK: - Premium hi-fi look

private let gold = Color(red: 0.84, green: 0.68, blue: 0.40)
private let goldDim = Color(red: 0.55, green: 0.44, blue: 0.24)

struct AudioView: View {
    @ObservedObject var model: AudioModel

    var body: some View {
        VStack(spacing: 9) {
            header
            displayPanel
            SeekRow(model: model, meter: model.meter)
            transport
            volumeRow
            playlist
        }
        .padding(14)
        .background(
            ZStack {
                LinearGradient(colors: [Color(white: 0.17), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [Color.white.opacity(0.07), .clear, Color.white.opacity(0.03)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack {
            Text("NANOTOWER").font(.system(size: 10, weight: .bold)).tracking(3).foregroundStyle(gold)
            Spacer()
            Text("DIGITAL AUDIO PLAYER").font(.system(size: 8, weight: .medium)).tracking(2).foregroundStyle(goldDim)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Display

    private var displayPanel: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ForEach(model.tags, id: \.self) { t in
                            Text(t).font(.system(size: 9, weight: .heavy)).tracking(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .foregroundStyle(t == "HI-RES" ? Color.black : gold)
                                .background(RoundedRectangle(cornerRadius: 3).fill(t == "HI-RES" ? gold : Color.clear))
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(gold, lineWidth: t == "HI-RES" ? 0 : 1))
                        }
                    }
                    .frame(height: 16)
                    Text(model.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    if !model.artist.isEmpty { Text(model.artist).font(.system(size: 13)).foregroundStyle(gold).lineLimit(1) }
                    if !model.album.isEmpty { Text(model.album).font(.system(size: 11)).opacity(0.5).lineLimit(1) }
                    Spacer(minLength: 0)
                    Text(model.format.isEmpty ? "—" : model.format)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(goldDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 118)
            MetersView(meter: model.meter)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.03), .black], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(
            LinearGradient(colors: [gold.opacity(0.7), goldDim.opacity(0.2)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.09))
            if let img = model.artwork {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(white: 0.04)).padding(8)
                    ForEach(0..<5, id: \.self) { i in
                        Circle().stroke(Color.white.opacity(0.05), lineWidth: 1).padding(CGFloat(14 + i * 9))
                    }
                    Circle().fill(gold).frame(width: 30, height: 30)
                    Circle().fill(Color.black).frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: 118, height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 18) {
            small("shuffle", on: model.shuffle) { model.shuffle.toggle() }
            key("backward.end.fill", 46) { model.prev() }
            playKey
            key("forward.end.fill", 46) { model.next() }
            small(model.repeatMode == 2 ? "repeat.1" : "repeat", on: model.repeatMode > 0) { model.cycleRepeat() }
        }
        .frame(maxWidth: .infinity)
    }

    private var playKey: some View {
        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(Color(white: 0.1))
            .frame(width: 68, height: 68)
            .background(Circle().fill(LinearGradient(colors: [Color(red: 0.95, green: 0.82, blue: 0.55), goldDim],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
            .shadow(color: gold.opacity(0.45), radius: 10)
            .clickable { model.toggle() }
    }

    private func key(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.10)], startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .clickable(action)
    }

    private func small(_ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(on ? gold : Color.white.opacity(0.45))
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.white.opacity(on ? 0.1 : 0.04)))
            .clickable(action)
    }

    // MARK: Volume (LED ladder)

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(goldDim)
            HStack(spacing: 3) {
                ForEach(0..<28, id: \.self) { i in
                    let lit = Float(i + 1) / 28 <= model.volume + 0.0001
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(lit ? (i > 22 ? Color(red: 1, green: 0.45, blue: 0.3) : gold) : Color.white.opacity(0.1))
                        .frame(maxWidth: .infinity)
                        .frame(height: 8 + CGFloat(i) * 0.25)
                }
            }
            .frame(height: 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .clickableAt { model.setVolume(Float($0.x)) }
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(goldDim)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Playlist

    private var playlist: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LIBRARY").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(goldDim)
                Text("\(model.queue.count) tracks").font(.system(size: 9)).opacity(0.4)
                Spacer()
                Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundStyle(goldDim)
                    .frame(width: 24, height: 18)
                    .clickable { model.refresh() }
            }
            .padding(.horizontal, 6).padding(.bottom, 4)

            VStack(spacing: 1) {
                if model.queue.isEmpty {
                    Text("No music found.\nAdd folders in Settings on the iPhone,\nor open a track from Files.")
                        .font(.system(size: 12)).multilineTextAlignment(.center).opacity(0.45).padding(.top, 14)
                }
                ForEach(Array(model.queue.enumerated()).dropFirst(model.top).prefix(40), id: \.element) { pair in
                    let on = pair.element == model.url
                    HStack(spacing: 8) {
                        Text(on ? "▶" : String(format: "%02d", pair.offset + 1))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(on ? gold : .white.opacity(0.35))
                            .frame(width: 22)
                        Text(pair.element.deletingPathExtension().lastPathComponent)
                            .font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                            .foregroundStyle(on ? gold : .white.opacity(0.85))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 27)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? gold.opacity(0.12) : Color.clear))
                    .clickable { model.play(pair.element) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - Seek row (observes the fast meter object)

struct SeekRow: View {
    @ObservedObject var model: AudioModel
    @ObservedObject var meter: AudioMeter

    private func fmt(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    var body: some View {
        let f = model.duration > 0 ? min(meter.time / model.duration, 1) : 0
        return HStack(spacing: 10) {
            Text(fmt(meter.time)).font(.system(size: 11, design: .monospaced)).foregroundStyle(gold).frame(width: 40, alignment: .trailing)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                    Capsule().fill(LinearGradient(colors: [goldDim, gold], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * f, height: 4)
                    Circle().fill(gold).frame(width: 11, height: 11)
                        .shadow(color: gold.opacity(0.7), radius: 4)
                        .offset(x: g.size.width * f - 5.5)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .clickableAt { model.seek(fraction: Double($0.x)) }
            Text(fmt(model.duration)).font(.system(size: 11, design: .monospaced)).opacity(0.5).frame(width: 40, alignment: .leading)
        }
    }
}

// MARK: - Analog VU meters (real levels from the player)

struct MetersView: View {
    @ObservedObject var meter: AudioMeter
    var body: some View {
        HStack(spacing: 10) {
            VUMeter(level: meter.l, label: "L")
            VUMeter(level: meter.r, label: "R")
        }
        .frame(height: 66)
    }
}

struct VUMeter: View {
    let level: Float
    let label: String

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 8),
                     with: .linearGradient(Gradient(colors: [Color(red: 1.0, green: 0.88, blue: 0.58),
                                                             Color(red: 0.88, green: 0.62, blue: 0.26)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let pivot = CGPoint(x: size.width / 2, y: size.height * 1.38)
            let rad = size.height * 1.22

            for i in 0...20 {
                let t = Double(i) / 20
                let a = (-50 + 100 * t) * .pi / 180
                let long = i % 5 == 0
                let r0 = rad - (long ? 12 : 7), r1 = rad
                var p = Path()
                p.move(to: CGPoint(x: pivot.x + sin(a) * r0, y: pivot.y - cos(a) * r0))
                p.addLine(to: CGPoint(x: pivot.x + sin(a) * r1, y: pivot.y - cos(a) * r1))
                ctx.stroke(p, with: .color(t > 0.78 ? Color(red: 0.75, green: 0.1, blue: 0.1) : Color(white: 0.12)),
                           lineWidth: long ? 1.6 : 1)
            }
            let a = (-50 + 100 * Double(level)) * .pi / 180
            let len = rad + 2
            var needle = Path()
            needle.move(to: pivot)
            needle.addLine(to: CGPoint(x: pivot.x + sin(a) * len, y: pivot.y - cos(a) * len))
            ctx.stroke(needle, with: .color(Color(white: 0.05)), lineWidth: 1.6)

            ctx.draw(Text(label).font(.system(size: 9, weight: .heavy)).foregroundColor(Color(white: 0.15)),
                     at: CGPoint(x: 12, y: size.height - 11))
            ctx.draw(Text("VU").font(.system(size: 9, weight: .heavy)).foregroundColor(Color(white: 0.15)),
                     at: CGPoint(x: size.width / 2, y: size.height - 12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.7), lineWidth: 1.5))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center))
                .allowsHitTesting(false)
        )
    }
}

import SwiftUI
import AVFoundation
import Combine

// MARK: - Model

final class VideoModel: AppModel {
    let player = AVPlayer()
    @Published var url: URL?
    @Published var title = "Videos"
    @Published var isPlaying = false
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 0.8
    @Published var muted = false
    @Published var rate: Float = 1
    @Published var showList = true
    @Published var fullscreen = false
    @Published var queue: [URL] = []
    @Published var library: [URL] = []
    @Published var top = 0

    private var timeObs: Any?
    private var statusObs: NSKeyValueObservation?
    private var endSub: AnyCancellable?
    private var accum = ScrollAccumulator()

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.volume = volume
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.current = t.seconds.isFinite ? t.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
        }
        statusObs = player.observe(\.timeControlStatus) { [weak self] p, _ in
            DispatchQueue.main.async { self?.isPlaying = p.timeControlStatus != .paused }
        }
        endSub = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.next() }
        refresh()
    }

    var list: [URL] { queue.isEmpty ? library : queue }

    func refresh() {
        MediaLibrary.scan(.video) { [weak self] urls in self?.library = urls }
    }

    func play(_ u: URL, queue q: [URL] = []) {
        if !q.isEmpty { queue = q }
        url = u
        title = u.deletingPathExtension().lastPathComponent
        current = 0; duration = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: u))
        player.rate = rate
    }

    func toggle() {
        guard url != nil else { return }
        if player.timeControlStatus == .paused {
            if duration > 0, current >= duration - 0.5 { seek(to: 0) }
            player.rate = rate
        } else {
            player.pause()
        }
    }

    func seek(to seconds: Double) {
        let t = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        current = t
    }
    func seek(fraction: Double) { if duration > 0 { seek(to: duration * fraction) } }
    func skip(_ s: Double) { seek(to: current + s) }

    func setVolume(_ v: Float) {
        volume = max(0, min(1, v)); muted = false
        player.volume = volume; player.isMuted = false
    }
    func toggleMute() { muted.toggle(); player.isMuted = muted }

    func cycleSpeed() {
        let all: [Float] = [1, 1.25, 1.5, 2, 0.75]
        let i = all.firstIndex(of: rate) ?? 0
        rate = all[(i + 1) % all.count]
        if isPlaying { player.rate = rate }
    }

    func step(_ d: Int) {
        let l = list
        guard let u = url, let i = l.firstIndex(of: u) else { return }
        let n = i + d
        if n >= 0 && n < l.count { play(l[n], queue: queue.isEmpty ? [] : queue) }
    }
    func next() { step(1) }
    func prev() { if current > 3 { seek(to: 0) } else { step(-1) } }

    func toggleFullscreen() {
        guard let w = win else { return }
        fullscreen.toggle()
        Desktop.shared.setFullscreen(w, fullscreen)
    }

    // MARK: Input

    override func insert(_ s: String) {
        switch s.lowercased() {
        case " ": toggle()
        case "f": toggleFullscreen()
        case "m": toggleMute()
        case "l": showList.toggle()
        case "n": next()
        case "p": prev()
        default: break
        }
    }

    override func special(_ k: SpecialKey) {
        switch k {
        case .enter: toggle()
        case .left: skip(-5)
        case .right: skip(5)
        case .up: setVolume(volume + 0.1)
        case .down: setVolume(volume - 0.1)
        case .escape: if fullscreen { toggleFullscreen() }
        default: break
        }
    }

    override func scroll(_ dy: CGFloat) {
        let n = accum.feed(dy, step: 26)
        if n != 0 { top = min(max(top + n, 0), max(0, list.count - 1)) }
    }
}

// MARK: - Layer view

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ v: PlayerUIView, context: Context) {}
}

// MARK: - View

struct VideoView: View {
    @ObservedObject var model: VideoModel

    private func fmt(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerView(player: model.player)
                Color.clear.contentShape(Rectangle()).clickable { model.toggle() }

                if model.url == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle").font(.system(size: 44))
                        Text("Pick a video from the library").font(.system(size: 15))
                        Text("or double-click one in Files").font(.system(size: 12)).opacity(0.6)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                } else if !model.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 30)).foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                        .clickable { model.toggle() }
                }

                VStack {
                    if model.url != nil {
                        Text(model.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                    }
                    Spacer()
                    controls
                }
            }
            if model.showList && !model.fullscreen { library }
        }
        .background(Color.black)
        .foregroundStyle(.white)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(fmt(model.current)).font(.system(size: 11, design: .monospaced)).frame(width: 48, alignment: .trailing)
                seekBar
                Text(fmt(model.duration)).font(.system(size: 11, design: .monospaced)).frame(width: 48, alignment: .leading)
            }
            HStack(spacing: 8) {
                btn("backward.end.fill") { model.prev() }
                btn("gobackward.10") { model.skip(-10) }
                btn(model.isPlaying ? "pause.fill" : "play.fill", big: true) { model.toggle() }
                btn("goforward.10") { model.skip(10) }
                btn("forward.end.fill") { model.next() }
                Spacer().frame(width: 10)
                btn(model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") { model.toggleMute() }
                volumeBar
                Spacer()
                Text(model.rate == 1 ? "1×" : String(format: "%g×", model.rate))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 44, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.14)))
                    .clickable { model.cycleSpeed() }
                btn("list.bullet") { model.showList.toggle() }
                btn(model.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { model.toggleFullscreen() }
            }
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
    }

    private var seekBar: some View {
        let f = model.duration > 0 ? min(model.current / model.duration, 1) : 0
        return ZStack(alignment: .leading) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25)).frame(height: 5)
                    Capsule().fill(Color.purple).frame(width: g.size.width * f, height: 5)
                    Circle().fill(Color.white).frame(width: 13, height: 13).offset(x: g.size.width * f - 6.5)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .clickableAt { model.seek(fraction: Double($0.x)) }
    }

    private var volumeBar: some View {
        let f = CGFloat(model.muted ? 0 : model.volume)
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(Color.white).frame(width: g.size.width * f, height: 4)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 80, height: 24)
        .contentShape(Rectangle())
        .clickableAt { model.setVolume(Float($0.x)) }
    }

    private func btn(_ icon: String, big: Bool = false, _ action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: big ? 18 : 14, weight: .semibold))
            .frame(width: big ? 44 : 32, height: big ? 36 : 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(big ? 0.22 : 0.12)))
            .clickable(action)
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("LIBRARY").font(.system(size: 11, weight: .semibold)).opacity(0.5)
                Spacer()
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
                    .frame(width: 26, height: 22)
                    .clickable { model.refresh() }
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            if model.list.isEmpty {
                Text("No videos found.\nAdd folders in Settings on the iPhone, or import from Photos.")
                    .font(.system(size: 12)).opacity(0.5).padding(8)
            }
            ForEach(Array(model.list.dropFirst(model.top).prefix(30)), id: \.self) { u in
                let on = u == model.url
                HStack(spacing: 8) {
                    Image(systemName: on ? "play.circle.fill" : "film").foregroundStyle(on ? Color.purple : .white.opacity(0.6))
                        .frame(width: 18)
                    Text(u.deletingPathExtension().lastPathComponent).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.purple.opacity(0.3) : Color.clear))
                .clickable { model.play(u, queue: model.list) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.1))
        .clipped()
    }
}

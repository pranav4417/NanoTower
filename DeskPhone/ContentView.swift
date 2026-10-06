import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var display = DisplayManager.shared
    @ObservedObject private var desktop = Desktop.shared
    @ObservedObject private var input = InputManager.shared
    @ObservedObject private var settings = Settings.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                header

                TrackpadView()
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.12)))
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "hand.point.up.left").font(.system(size: 34))
                            Text("Trackpad").font(.headline)
                            Text("Tap: click   •   Hold & drag: drag\nTwo-finger tap: right click   •   Two-finger drag: scroll")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .frame(maxHeight: .infinity)

                controls
            }
            .padding()

            // Invisible UIKit view that owns the iPhone keyboard
            KeyboardCatcher(active: desktop.showOnScreenKeyboard)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)

            if settings.blackout { blackoutView }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            if desktop.showOnScreenKeyboard { desktop.showOnScreenKeyboard = false }
        }
        .onChange(of: scenePhase) { phase in
            settings.sceneChanged(active: phase == .active)
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: display.isConnected ? "display" : "display.trianglebadge.exclamationmark")
                    .font(.system(size: 26))
                    .foregroundStyle(display.isConnected ? .green : .secondary)
                Text(display.isConnected
                     ? "Connected (\(Int(display.size.width))×\(Int(display.size.height)))"
                     : "No external display")
                    .font(.headline)
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 18))
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                chip("computermouse", "Mouse", input.mouseConnected)
                chip("keyboard", "Keyboard", input.keyboardConnected)
                Spacer()
            }
        }
    }

    private func chip(_ icon: String, _ title: String, _ on: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(on ? Color.green.opacity(0.25) : Color.white.opacity(0.08)))
            .foregroundStyle(on ? .green : .secondary)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Button { desktop.stepScale(-0.1) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Text("\(Int((desktop.uiScale * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 42)
                    Button { desktop.stepScale(0.1) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)

                Button { desktop.toggleKeyboard() } label: {
                    Label("Keyboard", systemImage: "keyboard")
                        .foregroundStyle(desktop.showOnScreenKeyboard ? .blue : .primary)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    AirPlayButton().frame(width: 36, height: 36)
                    Text("AirPlay").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                // A real toggle now: tap again (or three-finger tap) to turn the screen back on
                Toggle(isOn: $settings.blackout) {
                    Label("Black screen", systemImage: "moon.fill").frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)

                Menu {
                    ForEach(AppKind.allCases) { k in
                        Button(k.title, systemImage: k.icon) { desktop.launch(k) }
                    }
                } label: {
                    Label("Open", systemImage: "plus.app").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var blackoutView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TrackpadView(onThreeFingerTap: { settings.blackout = false }).ignoresSafeArea()
            VStack {
                Spacer()
                Toggle(isOn: $settings.blackout) {
                    Label("Black screen", systemImage: "moon.fill")
                }
                .toggleStyle(.button)
                .tint(.gray)
                .opacity(0.35)
                .padding(.bottom, 28)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

// MARK: - iPhone keyboard → desktop

final class KeyView: UIView, UIKeyInput {
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }                       // always true so Backspace always fires

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    func insertText(_ text: String) {
        if text == "\n" { Desktop.shared.special(.enter) }
        else { Desktop.shared.insert(text) }
    }
    func deleteBackward() { Desktop.shared.special(.backspace) }
}

struct KeyboardCatcher: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> KeyView { KeyView() }

    func updateUIView(_ v: KeyView, context: Context) {
        DispatchQueue.main.async {
            if active && !v.isFirstResponder { v.becomeFirstResponder() }
            else if !active && v.isFirstResponder { v.resignFirstResponder() }
        }
    }
}

// MARK: - Trackpad (UIKit gestures give us two-finger taps and scrolling)

struct TrackpadView: UIViewRepresentable {
    var onThreeFingerTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onThreeFingerTap) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        let c = context.coordinator

        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 8

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: hold)

        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap))

        let rightTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.rightTap))
        rightTap.numberOfTouchesRequired = 2

        let threeTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.threeTap))
        threeTap.numberOfTouchesRequired = 3

        c.holdG = hold
        [hold, pan, scroll, tap, rightTap, threeTap].forEach { v.addGestureRecognizer($0) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onThree = onThreeFingerTap
    }

    final class Coordinator: NSObject {
        var onThree: (() -> Void)?
        var last: CGPoint = .zero
        var scrolling = false
        weak var holdG: UILongPressGestureRecognizer?
        init(_ onThree: (() -> Void)?) { self.onThree = onThree }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            guard !scrolling, g.numberOfTouches <= 1 else { return }
            let k = 1.6 + min(hypot(t.x, t.y) / 8, 2.4)     // simple acceleration
            Desktop.shared.mouseMoved(dx: t.x * k, dy: t.y * k)
        }

        @objc func scroll(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                // Two fingers = scroll. Make sure a half-started hold-and-drag can't move windows.
                scrolling = true
                if let h = holdG { h.isEnabled = false; h.isEnabled = true }
                Desktop.shared.leftUp()
            case .ended, .cancelled, .failed:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.scrolling = false }
            default: break
            }
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            if g.state == .changed { Desktop.shared.scroll(t.y * 1.5) }   // finger motion; direction handled in one place
        }

        @objc func hold(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: g.view)
            switch g.state {
            case .began:
                guard !scrolling, g.numberOfTouches == 1 else { return }
                last = p
                Desktop.shared.leftDown()
            case .changed:
                guard !scrolling, g.numberOfTouches == 1 else { return }
                Desktop.shared.mouseMoved(dx: (p.x - last.x) * 2, dy: (p.y - last.y) * 2)
                last = p
            case .ended, .cancelled, .failed:
                Desktop.shared.leftUp()
            default:
                break
            }
        }

        @objc func tap() { Desktop.shared.click() }
        @objc func rightTap() { Desktop.shared.rightClick() }
        @objc func threeTap() { onThree?() }
    }
}

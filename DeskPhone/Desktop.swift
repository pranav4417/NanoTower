import SwiftUI
import UIKit
import AVKit
import Combine
// MARK: - Shared state (survives disconnect/reconnect)

final class DesktopState: ObservableObject {
    static let shared = DesktopState()
    @Published var windows: [String] = []
    private init() {}
}

final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()
    @Published var isConnected = false
    @Published var size: CGSize = .zero
    private init() {}
}

// MARK: - App delegate + external scene

class AppDelegate: NSObject, UIApplicationDelegate {
    var fallbackWindow: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let scene = note.object as? UIWindowScene else { return }
            print("SCENE willConnect, role:", scene.session.role.rawValue)
            guard scene.session.role == .windowExternalDisplayNonInteractive else { return }

            // Give the normal delegate a moment; only build a window if it didn't
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !DisplayManager.shared.isConnected else { return }
                print("FALLBACK: building external window manually")
                let window = UIWindow(windowScene: scene)
                window.rootViewController = UIHostingController(
                    rootView: DesktopView()
                        .environmentObject(DesktopState.shared)
                        .environmentObject(DisplayManager.shared)
                )
                window.makeKeyAndVisible()
                self?.fallbackWindow = window
                DisplayManager.shared.isConnected = true
                DisplayManager.shared.size = scene.screen.bounds.size
            }
        }
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        print("CONFIG requested, role:", session.role.rawValue)
        if session.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "External", sessionRole: session.role)
            config.delegateClass = ExternalSceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: "Default Configuration", sessionRole: session.role)
    }
}

class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(
            rootView: DesktopView()
                .environmentObject(DesktopState.shared)
                .environmentObject(DisplayManager.shared)
        )
        window.makeKeyAndVisible()
        self.window = window

        DisplayManager.shared.isConnected = true
        DisplayManager.shared.size = windowScene.screen.bounds.size
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        DisplayManager.shared.isConnected = false
        // DesktopState.shared is untouched, so windows come back on reconnect
    }
}

// MARK: - AirPlay picker

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        v.tintColor = .label
        v.activeTintColor = .systemBlue
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - External display UI

struct DesktopView: View {
    @EnvironmentObject var state: DesktopState

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Text("DeskPhone").font(.system(size: 64, weight: .bold))
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(ctx.date, style: .time).font(.system(size: 32))
                }
                Text("Windows: \(state.windows.count)")
                    .font(.title2).opacity(0.7)
                ForEach(state.windows, id: \.self) { Text("• \($0)") }
            }
            .foregroundStyle(.white)
        }
    }
}

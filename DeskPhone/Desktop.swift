import SwiftUI
import UIKit
import AVKit
import Combine

// MARK: - Display state

final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()
    @Published var isConnected = false
    @Published var size: CGSize = .zero
    private init() {}
}

// MARK: - External window creation

enum ExternalWindowFactory {
    static func make(for scene: UIWindowScene) -> UIWindow {
        let size = scene.screen.bounds.size
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: DesktopView())
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()

        DisplayManager.shared.isConnected = true
        DisplayManager.shared.size = size
        Desktop.shared.setScreen(size)
        return window
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, UIApplicationDelegate {
    var fallbackWindow: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        InputManager.shared.start()

        NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let scene = note.object as? UIWindowScene,
                  scene.session.role == .windowExternalDisplayNonInteractive else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !DisplayManager.shared.isConnected else { return }
                self?.fallbackWindow = ExternalWindowFactory.make(for: scene)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let scene = note.object as? UIWindowScene,
                  scene.session.role == .windowExternalDisplayNonInteractive else { return }
            DisplayManager.shared.isConnected = false
            self?.fallbackWindow = nil
        }
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
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
        window = ExternalWindowFactory.make(for: windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        DisplayManager.shared.isConnected = false
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

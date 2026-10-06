import SwiftUI
import GameController
import Combine

/// Reads a connected Bluetooth/USB mouse and keyboard and feeds the desktop.
final class InputManager: ObservableObject {
    static let shared = InputManager()

    @Published var mouseConnected = false
    @Published var keyboardConnected = false

    static let sensitivity: CGFloat = 1.5
    static let verticalSign: CGFloat = -1
    static let scrollSpeed: CGFloat = 14

    private var started = false
    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default

        nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
            if let m = n.object as? GCMouse { self?.attach(m) }
        }
        nc.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.mouseConnected = !GCMouse.mice().isEmpty
        }
        nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
            if let k = n.object as? GCKeyboard { self?.attach(k) }
        }
        nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.keyboardConnected = GCKeyboard.coalesced != nil
        }

        for m in GCMouse.mice() { attach(m) }
        if let k = GCKeyboard.coalesced { attach(k) }
    }

    // MARK: Mouse

    private func attach(_ mouse: GCMouse) {
        mouseConnected = true
        guard let input = mouse.mouseInput else { return }
        let d = Desktop.shared

        input.mouseMovedHandler = { _, dx, dy in
            d.mouseMoved(dx: CGFloat(dx) * InputManager.sensitivity,
                         dy: CGFloat(dy) * InputManager.sensitivity * InputManager.verticalSign)
        }
        input.leftButton.pressedChangedHandler = { _, _, pressed in
            if pressed { d.leftDown() } else { d.leftUp() }
        }
        input.rightButton?.pressedChangedHandler = { _, _, pressed in
            if pressed { d.rightClick() }
        }
        input.scroll.valueChangedHandler = { _, _, y in
            d.scroll(-CGFloat(y) * InputManager.scrollSpeed)
        }
    }

    // MARK: Keyboard

    private func attach(_ keyboard: GCKeyboard) {
        keyboardConnected = true
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] input, _, code, pressed in
            guard pressed else { return }
            self?.handle(input, code)
        }
    }

    private func handle(_ input: GCKeyboardInput, _ code: GCKeyCode) {
        func down(_ a: GCKeyCode, _ b: GCKeyCode) -> Bool {
            input.button(forKeyCode: a)?.isPressed == true || input.button(forKeyCode: b)?.isPressed == true
        }
        let cmd = down(.leftGUI, .rightGUI)
        let alt = down(.leftAlt, .rightAlt)
        let ctrl = down(.leftControl, .rightControl)
        let shift = down(.leftShift, .rightShift)
        let d = Desktop.shared

        if code == .spacebar && (cmd || alt || ctrl) { d.toggleLauncher(); return }
        if code == .tab && (cmd || alt) { d.cycleWindows(); return }

        if cmd {
            switch code {
            case .keyW: d.closeFocused()
            case .keyM: d.minimizeFocused()
            case .keyQ: d.quitFocusedApp()
            case .keyC: d.copy()
            case .keyV: d.paste()
            case .keyT: d.command("t")
            case .keyL: d.command("l")
            case .keyR: d.command("r")
            case .keyD: d.command("d")
            default: break
            }
            return
        }

        switch code {
        case .returnOrEnter: d.special(.enter)
        case .deleteOrBackspace: d.special(.backspace)
        case .tab: d.special(.tab)
        case .escape: d.special(.escape)
        case .leftArrow: d.special(.left)
        case .rightArrow: d.special(.right)
        case .upArrow: d.special(.up)
        case .downArrow: d.special(.down)
        default:
            if let c = Self.table[code.rawValue] { d.insert(shift ? c.1 : c.0) }
        }
    }

    private static let table: [Int: (String, String)] = {
        var t: [Int: (String, String)] = [:]
        let letters: [(GCKeyCode, String)] = [
            (.keyA, "a"), (.keyB, "b"), (.keyC, "c"), (.keyD, "d"), (.keyE, "e"), (.keyF, "f"),
            (.keyG, "g"), (.keyH, "h"), (.keyI, "i"), (.keyJ, "j"), (.keyK, "k"), (.keyL, "l"),
            (.keyM, "m"), (.keyN, "n"), (.keyO, "o"), (.keyP, "p"), (.keyQ, "q"), (.keyR, "r"),
            (.keyS, "s"), (.keyT, "t"), (.keyU, "u"), (.keyV, "v"), (.keyW, "w"), (.keyX, "x"),
            (.keyY, "y"), (.keyZ, "z")
        ]
        for (code, c) in letters { t[code.rawValue] = (c, c.uppercased()) }

        let symbols: [(GCKeyCode, String, String)] = [
            (.one, "1", "!"), (.two, "2", "@"), (.three, "3", "#"), (.four, "4", "$"),
            (.five, "5", "%"), (.six, "6", "^"), (.seven, "7", "&"), (.eight, "8", "*"),
            (.nine, "9", "("), (.zero, "0", ")"),
            (.spacebar, " ", " "), (.hyphen, "-", "_"), (.equalSign, "=", "+"),
            (.openBracket, "[", "{"), (.closeBracket, "]", "}"), (.backslash, "\\", "|"),
            (.semicolon, ";", ":"), (.quote, "'", "\""), (.graveAccentAndTilde, "`", "~"),
            (.comma, ",", "<"), (.period, ".", ">"), (.slash, "/", "?")
        ]
        for (code, a, b) in symbols { t[code.rawValue] = (a, b) }
        return t
    }()
}

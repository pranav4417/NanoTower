import SwiftUI
import Combine

// MARK: - Notes

final class NotesModel: AppModel {
    @Published var text: String {
        didSet { UserDefaults.standard.set(text, forKey: "nanotower.notes") }
    }

    override init() {
        text = UserDefaults.standard.string(forKey: "nanotower.notes")
            ?? "Welcome to NanoTower.\n\n- Move a mouse, or use the iPhone as a trackpad\n- Click the dock to open apps\n- Type here with a keyboard\n- Option+Space opens the launcher\n\n"
        super.init()
    }

    override func insert(_ s: String) { text += s }

    override func special(_ k: SpecialKey) {
        switch k {
        case .enter: text += "\n"
        case .backspace: if !text.isEmpty { text.removeLast() }
        case .tab: text += "    "
        default: break
        }
    }

    override func copyText() -> String? { text }
}

struct NotesView: View {
    @ObservedObject var model: NotesModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.text + "▏")
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .onChange(of: model.text) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(Color(white: 0.1))
    }
}

// MARK: - Calculator

final class CalcModel: AppModel {
    @Published var display = "0"
    private var acc: Double?
    private var op: String?
    private var fresh = true

    func press(_ k: String) {
        if k == "." || (k.count == 1 && k.first!.isNumber) { digit(k); return }
        switch k {
        case "C":
            display = "0"; acc = nil; op = nil; fresh = true
        case "±":
            if display != "0" && display != "Error" {
                display = display.hasPrefix("-") ? String(display.dropFirst()) : "-" + display
            }
        case "%":
            if let v = Double(display) { display = fmt(v / 100) }
        case "⌫":
            if fresh { return }
            display.removeLast()
            if display.isEmpty || display == "-" { display = "0"; fresh = true }
        case "=":
            apply(); op = nil; acc = nil; fresh = true
        default: // + - × ÷
            apply(); op = k; fresh = true
        }
    }

    private func digit(_ k: String) {
        if fresh {
            display = (k == ".") ? "0." : k
            fresh = false
        } else if k == "." {
            if !display.contains(".") { display += "." }
        } else if display == "0" {
            display = k
        } else if display.count < 14 {
            display += k
        }
    }

    private func apply() {
        guard let v = Double(display) else { return }
        if let o = op, let a = acc {
            var r = a
            switch o {
            case "+": r = a + v
            case "-": r = a - v
            case "×": r = a * v
            default:
                if v == 0 { display = "Error"; acc = nil; op = nil; fresh = true; return }
                r = a / v
            }
            acc = r
            display = fmt(r)
        } else {
            acc = v
        }
    }

    private func fmt(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e12 { return String(Int(d)) }
        return String(format: "%.8g", d)
    }

    override func insert(_ s: String) {
        for ch in s {
            switch ch {
            case "+": press("+")
            case "-": press("-")
            case "*": press("×")
            case "/": press("÷")
            case "=": press("=")
            case "%": press("%")
            case "c", "C": press("C")
            default: if ch == "." || ch.isNumber { press(String(ch)) }
            }
        }
    }

    override func special(_ k: SpecialKey) {
        switch k {
        case .enter: press("=")
        case .backspace: press("⌫")
        case .escape: press("C")
        default: break
        }
    }
}

struct CalculatorView: View {
    @ObservedObject var model: CalcModel

    private let rows: [[String]] = [
        ["C", "±", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "-"],
        ["1", "2", "3", "+"],
        ["0", ".", "⌫", "="]
    ]

    var body: some View {
        VStack(spacing: 8) {
            Text(model.display)
                .font(.system(size: 44, weight: .light, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 8)

            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key in
                        Text(key)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10).fill(color(for: key)))
                            .clickable { model.press(key) }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.1))
    }

    private func color(for k: String) -> Color {
        if "÷×-+=".contains(k) { return .orange }
        if "C±%⌫".contains(k) { return Color(white: 0.35) }
        return Color(white: 0.22)
    }
}
